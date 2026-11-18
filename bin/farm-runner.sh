#!/usr/bin/env bash
# farm-runner.sh <instance>
# Instance encodes the role: implementer-1, implementer-2, qa-1, ...
# Dumb scheduler, smart worker: bash claims tasks and supervises; one fresh
# `claude -p` session executes exactly one task, then exits.

source "$(dirname "${BASH_SOURCE[0]}")/farm-lib.sh"

INSTANCE="${1:?usage: farm-runner.sh <role>-<n>}"
ROLE="${INSTANCE%-*}"
AGENT_NAME="farm-${INSTANCE}"
export AGENT_NAME
log_billing_guard

# IMPLEMENTER_BACKLOG_FALLBACK=0 (the DEFAULT) keeps implementers on the
# human-curated `ready` queue only.  Scout output requires explicit human or
# QA promotion backlog → ready before it gets built.  This also guards the P2
# decompose path: phase children sit in `backlog` until QA's
# decompose-in-review validates the child-set and promotes them — auto-drain
# (FALLBACK=1) would let implementers claim phase children before validation,
# bypassing that review gate.  Set IMPLEMENTER_BACKLOG_FALLBACK=1 explicitly
# only if you want implementers to auto-drain backlog when ready is empty.
IMPLEMENTER_BACKLOG_FALLBACK="${IMPLEMENTER_BACKLOG_FALLBACK:-0}"

case "$ROLE" in
  implementer) PICK_ARGS_PRIMARY=(--status ready --move doing)
               PICK_ARGS_FALLBACK=()
               [[ "$IMPLEMENTER_BACKLOG_FALLBACK" == "1" ]] && PICK_ARGS_FALLBACK=(--status backlog --move doing)
               SOURCE_STATUS="ready"  INPROGRESS_STATUS="doing"  EXPECT_STATUS="review|escalated|archived"
               POLL="$POLL_SECONDS"   MODEL_ARGS=(--model "$IMPL_MODEL" --effort "$IMPL_EFFORT")
               MAX_SECONDS="${MAX_TASK_SECONDS:-7200}" ;;
  qa)          PICK_ARGS_PRIMARY=(--status review)
               PICK_ARGS_FALLBACK=()
               SOURCE_STATUS="review" INPROGRESS_STATUS="review" EXPECT_STATUS="shipped|escalated"
               POLL="$QA_POLL_SECONDS"
               MODEL_ARGS=(--model "$QA_MODEL" --effort "$QA_EFFORT")
               MAX_SECONDS="${QA_MAX_TASK_SECONDS:-10800}" ;;
  *) echo "unknown role: $ROLE" >&2; exit 2 ;;
esac

log "runner up — role=$ROLE repo=$REPO_DIR board=$BOARD_DIR"

CLAUDE_PID=""; GUARD_PID=""; RENDER_PID=""; WT=""; BRANCH=""; ACTIVE_TASK=""
cleanup() {
  [[ -n "$GUARD_PID"  ]] && kill "$GUARD_PID"  2>/dev/null || true
  # Best-effort: the readable-log renderer's own reaper (start_readable_renderer,
  # farm-lib.sh) self-exits it once claude is gone, but reap it here too — via
  # _reap_render, which also `pkill -P`s its `tail -F`/`jq` pipeline children, not
  # just the wrapper — so nothing lingers if we exit before claude (e.g. a TERM
  # during startup).
  [[ -n "${RENDER_PID:-}" ]] && _reap_render "$RENDER_PID"
  if [[ -n "$CLAUDE_PID" ]] && kill -0 "$CLAUDE_PID" 2>/dev/null; then
    kill -TERM "$CLAUDE_PID" 2>/dev/null || true
    for _ in 1 2 3 4 5; do kill -0 "$CLAUDE_PID" 2>/dev/null || break; sleep 1; done
    kill -KILL "$CLAUDE_PID" 2>/dev/null || true
  fi
  # Work-recovery on a graceful death (runner SIGTERM/restart mid-task): with
  # claude now killed the worktree is quiescent, so best-effort preserve any
  # unpushed WIP to origin/$BRANCH for the next implementer. The helper has its
  # own `timeout 60` on the push and can never crash this trap; it no-ops for QA
  # ($BRANCH empty), an unset WT (TERM during startup), or a clean/pushed tree.
  # Success (work already pushed → review) and fenced (another agent owns it →
  # avoid conflicting pushes) paths are handled inline in the loop, not here.
  [[ -n "$WT" ]] && preserve_worktree_work "$WT" "$BRANCH" || true
  # Release + requeue the in-flight ticket so a graceful runner death (systemd
  # restart / farmctl stop / Ctrl-C) does NOT wedge it in `doing`/`review`,
  # claimed by this now-dead agent, until kanban-md's 2h claim-timeout PLUS the
  # janitor's 3h orphan grace. A no-op unless the task is still ours and still in
  # its in-progress column (see requeue_interrupted_task). Runs AFTER preserve so
  # the next implementer resumes from origin/$BRANCH.
  requeue_interrupted_task "$ACTIVE_TASK" "$AGENT_NAME" "${INPROGRESS_STATUS:-}" "${SOURCE_STATUS:-}" || true
}
trap cleanup EXIT
trap 'exit 143' TERM INT   # routes through the EXIT trap

slugify() { tr '[:upper:]' '[:lower:]' <<<"$1" | sed -E 's/[^a-z0-9]+/-/g; s/^-|-$//g' | cut -c1-40; }

while true; do
  wait_if_gated

  # -- claim atomically (zero tokens); no task => idle cheaply ---------------
  PICKED="$(kb pick --claim "$AGENT_NAME" "${PICK_ARGS_PRIMARY[@]}" --json 2>/dev/null)" \
    || PICKED=""
  if [[ -z "$PICKED" && ${#PICK_ARGS_FALLBACK[@]} -gt 0 ]]; then
    PICKED="$(kb pick --claim "$AGENT_NAME" "${PICK_ARGS_FALLBACK[@]}" --json 2>/dev/null)" \
      || PICKED=""
  fi
  if [[ -z "$PICKED" ]]; then sleep "$POLL"; continue; fi

  TASK_ID="$(jq -r '.id' <<<"$PICKED")"
  TASK_TITLE="$(jq -r '.title' <<<"$PICKED")"
  log "claimed task #$TASK_ID: $TASK_TITLE"
  # Mark this task in-flight: if the RUNNER is killed (systemd restart / farmctl
  # stop / Ctrl-C) before the loop handles the outcome below, the cleanup() EXIT
  # trap uses this to release + requeue it. Cleared the instant `wait` returns.
  ACTIVE_TASK="$TASK_ID"

  # -- deterministic pre-QA gate (zero tokens) --------------------------------
  # Before paying for a QA session on a `review` task with a linked PR, ask
  # GitHub about the PR's REQUIRED checks and act WITHOUT a session: red →
  # requeue to the implementer (first gate strike) or escalate (second — the
  # `qa-gate-strike` marker survives the implementer's success path, which
  # clears only `farm-retry`, so consecutive red-CI cycles are BOUNDED); pending
  # → release + defer to the next poll; green/no-data → spawn QA. All logic
  # lives in qa_gate (farm-lib.sh) so the strike/loop semantics are directly
  # unit-testable; this is only the scheduling shim around its verdict.
  if [[ "$ROLE" == "qa" ]] && GATE_PR="$(task_pr_from_tags "$TASK_ID")" && [[ -n "$GATE_PR" ]]; then
    case "$(qa_gate "$TASK_ID" "$GATE_PR")" in
      requeued | escalated)
        ACTIVE_TASK=""
        continue
        ;;
      deferred)
        ACTIVE_TASK=""
        sleep "$POLL"
        continue
        ;;
      *) : ;;   # spawn → proceed
    esac
  fi

  # -- per-task rigor routing (complexity tiering) ---------------------------
  # Deterministic: safety floor > human tier:/model: override > default Heavy.
  # The implementer model tiers per task (Sonnet for Light, via
  # resolve_impl_model); QA tiers its MODEL per task too (resolve_qa_model:
  # light → QA_MODEL_LIGHT, heavy/default → QA_MODEL, HARD path floor → opus
  # ABSOLUTE) but its EFFORT never tiers down (stays $QA_EFFORT). TASK_TIER is
  # injected into the prompt so a Light implementer skips its own pre-commit
  # reviewer.
  TASK_TIER="$(resolve_task_tier "$TASK_ID")"
  if [[ "$ROLE" == "implementer" ]]; then
    MODEL_ARGS=(--model "$(resolve_impl_model "$TASK_ID")" --effort "$(resolve_impl_effort "$TASK_ID")")
  elif [[ "$ROLE" == "qa" ]]; then
    MODEL_ARGS=(--model "$(resolve_qa_model "$TASK_ID")" --effort "$QA_EFFORT")
  fi
  log "task #$TASK_ID routed tier=$TASK_TIER model=${MODEL_ARGS[1]:-?} effort=${MODEL_ARGS[3]:-?}"

  # -- workspace -------------------------------------------------------------
  # make_worktree can fail on a sustained git-fetch/network outage (bounded
  # backoff, then non-zero). That is an INFRA event, not a task failure: requeue
  # NO-STRIKE + backoff gate + deduped note, then poll again — NEVER crash the
  # runner (the old unguarded fetch turned an outage into a systemd crash-loop
  # that spammed the board and fired no breaker). `if ! WT=$(...)` keeps `set -e`
  # from aborting on the non-zero substitution.
  if [[ "$ROLE" == "implementer" ]]; then
    BRANCH="task/${TASK_ID}-$(slugify "$TASK_TITLE")"
    if ! WT="$(make_worktree "${INSTANCE}-task-${TASK_ID}" "$BRANCH")"; then
      requeue_on_infra_outage "$TASK_ID" "$SOURCE_STATUS" "git fetch failed preparing the worktree"
      log "task #$TASK_ID: worktree fetch outage — requeued no-strike, backoff gate set"
      ACTIVE_TASK=""
      continue
    fi
  else
    BRANCH=""
    if ! WT="$(make_worktree "${INSTANCE}-task-${TASK_ID}")"; then   # QA checks out the PR itself
      requeue_on_infra_outage "$TASK_ID" "$SOURCE_STATUS" "git fetch failed preparing the worktree"
      log "task #$TASK_ID: worktree fetch outage — requeued no-strike, backoff gate set"
      ACTIVE_TASK=""
      continue
    fi
  fi

  # -- build the one-shot prompt ----------------------------------------------
  # Ticket bodies are attacker-influenceable (scout transcribes upstream repo
  # content); defuse any framing tags before interpolating into the prompt.
  TASK_FULL="$(kb show "$TASK_ID" | defuse_framing_tags)"
  PROMPT="$(cat "$(farm_resolve "prompts/$ROLE.md")")

<farm_context>
AGENT_NAME: $AGENT_NAME
TASK_ID: $TASK_ID
TASK_TIER: $TASK_TIER
BOARD_DIR: $BOARD_DIR        # every kanban-md call MUST use: kanban-md --dir \"$BOARD_DIR\" ...
REPO_MAIN_BRANCH: $MAIN_BRANCH
WORKTREE: $WT
BRANCH: ${BRANCH:-"(checkout the PR branch via gh pr checkout)"}
</farm_context>

<task>
$TASK_FULL
</task>"

  # -- resolve the farm constitution (project override wins via farm_resolve) --
  FARM_MD="$(farm_resolve FARM.md)"
  SYSTEM_ARGS=()
  [[ -f "$FARM_MD" ]] && SYSTEM_ARGS=(--append-system-prompt-file "$FARM_MD")

  # -- confine tool writes to this worktree (guard-bash.sh reads these) --------
  # Exported so the PreToolUse guard denies Write/Edit targets resolving outside
  # the session's worktree (the observed live-eval failure). FARM_STATE_DIR keeps
  # the farm's own state writes (metrics, reports) allowed even though they live
  # outside the worktree. Cleared implicitly next iteration (WT is reassigned).
  export FARM_WORKTREE="$WT" FARM_STATE_DIR="$STATE_DIR"

  # -- run one fresh session under the lease guard ----------------------------
  # stream-json + --verbose makes claude emit one JSON event per line as it
  # works, so the RUN_LOG fills live (operator can `farmctl tail`) instead of
  # buffering until session end. The raw JSONL goes STRAIGHT to the log via the
  # plain redirect below — NO pipeline. Two invariants this preserves:
  #   1. `exec` + plain `>"$RUN_LOG"` keeps $! pointing at the claude PID itself,
  #      so the lease guard / watchdog KILL the real process (a pipeline would
  #      orphan it → fencing failure, two agents on one task).
  #   2. The limit phrases ("hit your X limit" / "resets …") survive as
  #      substrings inside JSON-encoded result events, so output_hit_limit /
  #      set_limit_gate_from_output below keep matching (regression test:
  #      agent-farm/tests/run.sh "limit phrase survives stream-json").
  RUN_LOG="$LOG_DIR/${INSTANCE}-task${TASK_ID}-$(date +%Y%m%d-%H%M%S).log"
  SESSION_START="$(date +%s)"
  ( cd "$WT" && exec "$CLAUDE_BIN" -p --output-format stream-json --verbose \
      --dangerously-skip-permissions \
      ${SYSTEM_ARGS[@]+"${SYSTEM_ARGS[@]}"} "${MODEL_ARGS[@]}" "$PROMPT" ) >"$RUN_LOG" 2>&1 &
  CLAUDE_PID=$!
  # Live human-readable companion: a SEPARATE background renderer tails the raw
  # RUN_LOG and distils it into RUN_LOG's `.txt` sibling via the shared
  # FARM_LOG_FMT. It is deliberately NOT a pipeline around the claude exec — that
  # would make $CLAUDE_PID the jq/tail PID and orphan the real claude process,
  # breaking the lease-guard/watchdog kill (the #1058 fencing invariant). The
  # raw `.log` is untouched (limit-grep + fidelity); the `.txt` is what an
  # operator reads with cat/less/`farmctl tail`. `start_readable_renderer`
  # (farm-lib.sh Portability section) self-terminates the renderer AND its
  # `tail -F`/`jq` pipeline children once claude exits — no `tail --pid` (absent
  # on BSD); cleanup() also reaps RENDER_PID as a backstop.
  READABLE_LOG="${RUN_LOG%.log}.txt"
  start_readable_renderer "$CLAUDE_PID" "$RUN_LOG" "$READABLE_LOG"   # sets $RENDER_PID
  GUARD_PID="$(start_lease_guard "$TASK_ID" "$CLAUDE_PID" "$(( $(date +%s) + MAX_SECONDS ))")"
  set +e
  wait "$CLAUDE_PID"
  RC=$?
  set -e
  # Session ended on its own → the loop owns the outcome from here (the success /
  # requeue / fenced / failure paths below each release+requeue as needed). Clear
  # the in-flight marker so a SIGTERM during outcome handling cannot make
  # cleanup() double-act on a task the loop is already resolving.
  ACTIVE_TASK=""
  kill "$GUARD_PID" 2>/dev/null || true
  # Renderer's own reaper self-exits it (+ its tail/jq children) once claude is
  # gone; reap here too and clear the handle so the next loop iteration's
  # cleanup() never targets a stale/reused PID.
  [[ -n "$RENDER_PID" ]] && _reap_render "$RENDER_PID"; RENDER_PID=""
  OUT="$(run_log_tail "$RUN_LOG" 200000)"
  # Per-session token usage from the stream-json result event (free; for metrics).
  USAGE_JSON="$(session_usage_json "$OUT")"

  # -- verify outcome in bash; never trust the model's word ------------------
  if output_hit_limit "$OUT"; then
    set_limit_gate_from_run "$OUT" "$RUN_LOG"
    # Work-recovery: preserve any unpushed WIP before requeue so the next
    # implementer resumes from origin/$BRANCH (no-op for QA / clean trees).
    preserve_worktree_work "$WT" "$BRANCH"
    # Per-task cap (mirrors the infra poison-task cap): a task that keeps ending
    # on a phrase-detected limit after a real session must not requeue no-strike
    # forever — escalate it instead (see _limit_retry_decide for what counts).
    if [[ "$(note_task_limit_retry "$TASK_ID" "$(limit_detect_source "$OUT")" "$(( $(date +%s) - SESSION_START ))")" == escalate ]]; then
      kb edit "$TASK_ID" --release >/dev/null || true
      LIMIT_MOVED=1
      if kb move "$TASK_ID" escalated >/dev/null; then :; else LIMIT_MOVED=0; fi
      kb edit "$TASK_ID" --block "repeated usage-limit requeues on this task — see notes" >/dev/null 2>&1 || true
      append_note "$TASK_ID" "FARM: ${LIMIT_MAX_TASK_RETRIES} consecutive usage-limit requeues on THIS task — escalated."
      clear_task_limit_retry "$TASK_ID"
      if (( LIMIT_MOVED )); then
        log "task #$TASK_ID escalated after repeated usage-limit requeues (limit cap)"
      else
        log "task #$TASK_ID hit the usage-limit cap but the move to escalated FAILED — left blocked in its current column"
      fi
    else
      kb edit "$TASK_ID" --release >/dev/null || true
      requeue_unblocked "$TASK_ID" "$SOURCE_STATUS"
      append_note "$TASK_ID" "FARM: ${AGENT_NAME} hit the usage limit mid-run; requeued (no strike)."
    fi
  elif output_transient_infra_error "$OUT" "$RC"; then
    # Transient model/API/infra error (404 / 5xx / overload / timeout /
    # transport-died). Mirror the usage-limit branch EXACTLY: requeue NO-STRIKE
    # — no farm-retry tag, no handle_failure, no note_failure_streak — so a
    # provider outage never escalates good tasks to escalated (the
    # 2026-06-13 incident). Salvage any mid-task WIP first (recovery synergy),
    # then set a farm-wide backoff gate so all workers pause briefly instead of
    # hammering a down API, and bump the sustained-outage counter (pauses the
    # farm at INFRA_MAX_STREAK).
    clear_task_limit_retry "$TASK_ID"   # a non-limit outcome breaks the consecutive-limit streak
    preserve_worktree_work "$WT" "$BRANCH"
    # Poison-task cap: K consecutive transient failures on the SAME task is a
    # deterministic crash misclassified transient (not a provider outage) — stop
    # the infinite no-strike loop and escalate it to escalated.
    if [[ "$(note_task_infra_retry "$TASK_ID")" == escalate ]]; then
      kb edit "$TASK_ID" --release >/dev/null || true
      kb move "$TASK_ID" escalated >/dev/null || true
      kb edit "$TASK_ID" --block "repeated transient/crash failures (suspected poison task) — see notes" >/dev/null 2>&1 || true
      append_note "$TASK_ID" "FARM: ${INFRA_MAX_TASK_RETRIES} consecutive transient/crash failures on THIS task — escalated (suspected poison task, not a provider outage)."
      clear_task_infra_retry "$TASK_ID"
      log "task #$TASK_ID escalated after repeated transient failures (poison-task cap)"
    else
      kb edit "$TASK_ID" --release >/dev/null || true
      requeue_unblocked "$TASK_ID" "$SOURCE_STATUS"
      append_note "$TASK_ID" "FARM: transient model/API error (rc=$RC) — requeued no-strike."
      note_infra_failure_streak
      set_infra_backoff_gate
      log "task #$TASK_ID transient infra error — requeued no-strike, backoff gate set"
    fi
  else
    OWNER="$(kb show "$TASK_ID" --json | jq -r '.claimed_by // ""')"
    if [[ -n "$OWNER" && "$OWNER" != "$AGENT_NAME" ]]; then
      # Fenced: another agent owns it now. Touch nothing — kanban-md would
      # reject our edits anyway (TaskClaimed); the new owner drives the task.
      log "task #$TASK_ID lease lost to $OWNER — session was fenced, no board mutation"
    else
      FINAL="$(task_status "$TASK_ID")"
      # Success = the task reached an expected terminal state, OR QA performed an
      # auto-merge handoff (left a pr-tagged task in `review` for the janitor —
      # is_armed_handoff; see farm-lib.sh). Without the handoff clause the runner
      # strikes every auto-merge PR and the failstreak breaker trips on a drain
      # (the 2026-06-14 false pause).
      if { [[ "$FINAL" =~ ^(${EXPECT_STATUS})$ && $RC -eq 0 ]]; } || is_armed_handoff "$FINAL" "$RC" "$TASK_ID"; then
        log "task #$TASK_ID done → $FINAL (log: $RUN_LOG)"
        note_success
        clear_task_infra_retry "$TASK_ID"
        clear_task_limit_retry "$TASK_ID"
        kb edit "$TASK_ID" --remove-tag farm-retry >/dev/null 2>&1 || true
        # QA PASS also clears the gate's strike marker — but ONLY on the qa
        # role: the IMPLEMENTER success path must never touch qa-gate-strike
        # (it means "reached review + clean exit", NOT "checks green" — clearing
        # it here for implementers would reopen the unbounded red-CI requeue
        # loop the marker exists to break; see qa_gate in farm-lib.sh).
        if [[ "$ROLE" == "qa" ]]; then
          kb edit "$TASK_ID" --remove-tag qa-gate-strike >/dev/null 2>&1 || true
        fi
        # QA just armed auto-merge and handed off (is_armed_handoff): spawn a
        # detached CI watcher instead of waiting up to JANITOR cadence (30min)
        # for pass_ci_rescue to notice a later-red required check. No-op for the
        # implementer role and for a normal (non-handoff) QA terminal state.
        if [[ "$ROLE" == "qa" && "$FINAL" == "review" ]]; then
          PR_FOR_WATCH="$(task_pr_from_tags "$TASK_ID" 2>/dev/null || true)"
          [[ -n "$PR_FOR_WATCH" ]] && spawn_ci_watch "$TASK_ID" "$PR_FOR_WATCH"
        fi
      else
        log "task #$TASK_ID NOT in expected state (rc=$RC, status=$FINAL) — see $RUN_LOG"
        clear_task_limit_retry "$TASK_ID"   # a real (non-limit) failure breaks the consecutive-limit streak
        # Work-recovery: preserve unpushed WIP before requeue (no-op for QA /
        # clean trees / already-pushed work).
        preserve_worktree_work "$WT" "$BRANCH"
        clear_task_infra_retry "$TASK_ID"   # a real (non-transient) failure breaks the transient streak
        handle_failure "$TASK_ID" "$SOURCE_STATUS" "rc=$RC final_status=$FINAL log=$RUN_LOG"
      fi
    fi
  fi

  # -- per-session token metrics (free; from the result event already captured).
  # Records EVERY session (incl. retries) to a queryable JSONL, and surfaces the
  # implementer/QA usage in the PR body for at-a-glance cost review. Best-effort —
  # a metrics/gh hiccup never affects task handling.
  record_task_metrics "$TASK_ID" "$ROLE" "${MODEL_ARGS[1]:-?}" "${MODEL_ARGS[3]:-?}" \
    "$TASK_TIER" "$(task_status "$TASK_ID" 2>/dev/null || echo '?')" "$USAGE_JSON"
  if PR_N="$(task_pr_from_tags "$TASK_ID" 2>/dev/null)" && [[ -n "$PR_N" ]]; then
    pr_upsert_usage "$PR_N" \
      "$(format_usage_line "$ROLE" "${MODEL_ARGS[1]:-?}" "${MODEL_ARGS[3]:-?}" "$TASK_TIER" "$USAGE_JSON")"
  fi

  drop_worktree "$WT"
done
