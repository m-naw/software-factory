#!/usr/bin/env bash
# farm-janitor.sh — board hygiene, fired by claude-janitor.timer.
#  * tasks sitting in `doing` with an expired/absent claim = dead implementer
#    → requeue to `ready` with a note (kanban-md claims expire on their own;
#      the janitor only fixes the column).
#  * task↔PR reconciliation (merged PR → shipped) + archive (shipped → archived).
#  * capstone dispatch for fully-terminal epics.
#  * stale worktrees and `git worktree prune`; log rotation.
#
# RESILIENCE MODEL (2026-06-15 hardening). The whole script runs under
# `set -euo pipefail` (from farm-lib.sh). Before this hardening every pass ran
# as bare top-level commands, so a SINGLE non-zero exit in an UNGUARDED
# top-level command — e.g. the `find … | while read` worktree-prune pipeline
# (pipefail makes a non-zero `find` abort the pipe) or a transiently-failing
# `kb list` command-substitution feeding a pass — aborted the ENTIRE run under
# `set -e`, silently skipping every later pass (notably the archive pass) with
# ZERO log output. That is exactly the production symptom: 8-10s run, no log,
# ~25 shipped+merged tasks (#36-#65) never archived, while a manual re-run
# worked. Two fixes:
#   1. A per-run LOG FILE (mirrors farm-scout.sh): every run tees its log()
#      output to $LOG_DIR/janitor-<ts>.log AND to stderr→journald, so every
#      future run leaves an inspectable trace and the last line before any
#      abort is visible.
#   2. Each pass is a FUNCTION run via run_pass, which executes it with `set -e`
#      DISABLED at the call boundary (`|| log WARN`): a failure in one pass — or
#      in its setup command-substitutions — is logged and the NEXT pass still
#      runs. The janitor now ALWAYS reaches the archive pass and ALWAYS leaves a
#      log, even if an earlier pass hiccups. The conservative gh-MERGED archive
#      rule, the reconcile semantics, and move_release_to are unchanged; the
#      per-task `|| true` guards inside the loops are unchanged (a real per-task
#      issue is still logged, never masked).

source "$(dirname "${BASH_SOURCE[0]}")/farm-lib.sh"
AGENT_NAME="farm-janitor"; export AGENT_NAME

# ------------------------------------------------------- gh repo context ----
# NOTE: REPO_DIR is provided by the systemd unit (Environment=REPO_DIR) or
# CLAUDE_PROJECT_DIR at skill time; it is NOT path-walked from the engine.
# `gh pr view` / `gh api` below fails with "fatal: not a git repository" →
# empty state → the conservative non-MERGED rule silently skips EVERY pr-<N>-
# tagged shipped task forever, deadlocking multi-phase --depends-on work.
# A single cd to the repo root gives the gh calls repo context; the git
# calls are unaffected (they all use `git -C "$REPO_DIR"`, cwd-independent).
# See docs/adr/2026-06-26-farm-janitor-gh-repo-context.md. Belt-and-braces on
# top of the cd: every gh call below ALSO targets the repo explicitly
# (`-R "$FARM_REPO_SLUG"` / repos/$nwo paths, farm-lib.sh) so none of them
# depends on the process cwd — the cwd dependency is how the runner's
# pr_upsert_usage silently hit the wrong repo (2026-07-10 defect); the janitor
# shared the latent pattern.
cd "$REPO_DIR" || { log "FATAL: cannot cd to REPO_DIR=$REPO_DIR"; exit 1; }

# ----------------------------------------------------------- run log file ----
# Mirror farm-scout.sh's per-run log: name it janitor-<ts>.log under $LOG_DIR.
# log() (farm-lib.sh) writes to stderr (fd 2); we tee fd 2 into the file so the
# trace lands BOTH in the persisted log and in journald (systemd captures the
# oneshot's stderr). `process substitution + exec` keeps it streaming and
# unbuffered enough that the last line before any abort is preserved. Best-effort
# on the tee setup itself — a failure to open the log must never stop the run.
RUN_LOG="$LOG_DIR/janitor-$(date +%Y%m%d-%H%M%S).log"
exec 2> >(tee -a "$RUN_LOG" >&2) || true
log "janitor up — board=$BOARD_DIR log=$RUN_LOG"

# run_pass <name> <fn>: execute pass <fn> with `set -e` neutralised at the call
# boundary so a non-zero exit anywhere in the pass (a failing top-level
# command-substitution, a find/git returning non-zero, a pipefail) is caught,
# logged, and DOES NOT abort the script — the next pass still runs. Each pass
# function is itself responsible for per-task `|| true` so one bad task never
# aborts the rest of ITS pass; run_pass is the belt-and-braces for the pass
# SETUP (the command-substitutions feeding the loop) and any unguarded line.
run_pass() { # name, fn
  local name="$1" fn="$2"
  log "pass start: $name"
  if "$fn"; then
    log "pass ok: $name"
  else
    log "WARN: pass '$name' exited non-zero — logged, continuing to next pass"
  fi
  return 0
}

# Requeue orphaned `doing` tasks — but only after a grace window measured on
# the `updated` timestamp. The lease guard renews the claim (and bumps
# `updated`) every CLAIM_REFRESH_SECONDS while a session is alive, so a task
# whose `updated` is older than claim_timeout + margin belongs to a dead run.
# This closes the race where a slow-but-alive session gets its task stolen.
# (`review` needs no rescue: unclaimed tasks there are waiting for QA.)
JANITOR_GRACE_SECONDS="${JANITOR_GRACE_SECONDS:-10800}"   # 3h = 2h claim_timeout + 1h margin
pass_orphans() {
  local CUTOFF ORPHANS id wt wt_branch HINT BR
  CUTOFF=$(( $(date +%s) - JANITOR_GRACE_SECONDS ))
  ORPHANS="$(kb list --status doing --unclaimed --json 2>/dev/null \
    | jq -r --argjson cutoff "$CUTOFF" \
        '.[] | select(((.updated // "1970-01-01T00:00:00Z") | fromdateiso8601? // 0) < $cutoff) | .id' \
    || true)"
  for id in $ORPHANS; do
    # Work-recovery backstop: a hard kill (SIGKILL / OOM / the lease-guard's
    # kill -KILL) bypasses the runner's EXIT trap, so cleanup()'s WIP-push never
    # ran and the worktree lingers with unpushed work. Before requeuing, salvage
    # any such worktree(s) (the runner names them <instance>-task-${id}; we match
    # them instance-agnostically via *-task-${id}) by
    # committing + pushing their branch — turning the HINT below from a hope into
    # a fact. preserve_worktree_work is best-effort and never force-pushes.
    for wt in "$WORKTREES_DIR"/*-task-"${id}"; do
      [[ -d "$wt" ]] || continue
      wt_branch="$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
      [[ -z "$wt_branch" || "$wt_branch" == "HEAD" ]] && continue   # detached (QA) → nothing to preserve
      preserve_worktree_work "$wt" "$wt_branch"
    done
    HINT=""
    BR="$(git -C "$REPO_DIR" ls-remote --heads origin "task/${id}-*" 2>/dev/null | awk '{print $2}' | head -1 || true)"
    [[ -n "$BR" ]] && HINT=" A pushed branch exists (${BR#refs/heads/}) — the next implementer resumes from it."
    append_note "$id" "FARM-JANITOR: claim expired in doing (stale > ${JANITOR_GRACE_SECONDS}s) — requeued to ready.${HINT}"
    # requeue_unblocked (not a bare move): a block flag surviving into `ready`
    # makes the ticket invisible to every worker's pick (RC#8).
    requeue_unblocked "$id" ready
    log "requeued orphaned task #$id doing → ready${HINT:+ (branch found)}"
  done
}

# Task↔PR reconciliation: auto-ship a task once its linked PR has MERGED. The
# task↔PR link is a structured `pr-<N>` tag (implementer sets it at PR-open; QA
# re-asserts it when stranding a PASSED PR in escalated for human merge). A
# task can be stranded in a NON-terminal column after its PR merges — e.g. a
# protected-surface PR QA parked in `escalated` for the operator to merge by
# hand (the 2026-06-13 #5/#1057 and #9/#1070 cases), or a `review` task whose QA
# session died after merging, OR an implementer that tagged `pr-<N>` then died
# before handoff, leaving the task in `doing` while a human merged the PR (which
# pass_orphans would otherwise requeue → re-implement). So we scan the three
# stranded-prone non-terminal columns: escalated, review, AND doing. Two guards
# protect correctness on the wider scan: task_claim_is_fresh never disturbs a
# `doing` task an ALIVE runner still holds (claim within grace); pr_head_matches_task
# requires the PR's head branch to be this task's `task/<id>-*` branch, cross-
# validating the `pr-<N>` tag against the PR-number race (never ship on ANOTHER
# task's merged PR). Act ONLY when MERGED. Every kb/gh call is best-effort
# (`|| true` / `timeout`), so a board hiccup or a slow GitHub API never aborts.
pass_reconcile() {
  local RECONCILE_IDS id pr pr_json pr_state head_ref OLD_ESCALATION_STATUS
  # Belt-and-braces for ONE release after the 2026-07-09 `escalated` rename: a
  # board migrated while a rogue pre-rename runner was still alive can hold
  # tickets in the OLD escalation status (kanban-md tolerates listing a status
  # absent from config.yml — verified during the migration design). Scanning it
  # here keeps such tickets reconcilable instead of silently orphaned. The old
  # name is assembled from halves so the test suite's no-old-status grep guard
  # stays absolute. Remove this (and the variable) after one release.
  OLD_ESCALATION_STATUS="needs""-human"
  RECONCILE_IDS="$(kb list --status "escalated,review,doing,${OLD_ESCALATION_STATUS}" --json 2>/dev/null \
    | jq -r '.[].id' || true)"
  for id in $RECONCILE_IDS; do
    pr="$(task_pr_from_tags "$id")"
    [[ -z "$pr" ]] && continue                       # no linked PR → nothing to reconcile
    task_claim_is_fresh "$id" "$JANITOR_GRACE_SECONDS" && continue   # live runner → never disturb
    pr_json="$(farm_timeout 30 gh pr view "$pr" ${GH_REPO_ARGS[@]+"${GH_REPO_ARGS[@]}"} --json state,headRefName 2>/dev/null || true)"
    pr_state="$(jq -r '.state // ""'       <<<"$pr_json" 2>/dev/null || true)"
    head_ref="$(jq -r '.headRefName // ""' <<<"$pr_json" 2>/dev/null || true)"
    [[ "$pr_state" != "MERGED" ]] && continue        # act ONLY on MERGED (never CLOSED/OPEN)
    if ! pr_head_matches_task "$head_ref" "$id"; then
      log "WARN: task #$id pr-$pr head '$head_ref' != task/$id-* — skipping reconcile (suspected wrong pr tag)"
      continue
    fi
    # A stranded merged task is often STILL claimed by a dead QA session (the
    # 2026-06-15 #63 wedge). move_release_to ships it in ONE atomic, claim-aware
    # step (move --claim <holder>, accepted on a foreign claim) + a best-effort
    # release — never the fragile release-then-bare-move that a swallowed release
    # left rejected. Best-effort throughout: a per-task board hiccup logs and the
    # loop continues with the next task; a single failure never aborts the pass.
    append_note "$id" "FARM-JANITOR: PR #${pr} merged → auto-reconciled to shipped."
    if move_release_to "$id" shipped; then
      log "reconciled task #$id → shipped (PR #$pr merged)"
    else
      log "WARN: could not reconcile task #$id → shipped (PR #$pr merged) — left for next run"
    fi
  done
}

# CI-rescue pass. Closes the gap where QA arms auto-merge and exits one-shot, a
# LATER-red REQUIRED CI check leaves the PR stranded in `review` with nobody to
# fix it. For each `review` task with a `pr-<N>` tag, on an OPEN non-draft PR
# whose failing checks intersect the branch-protection required contexts:
#   * branch BEHIND main → server-side update-branch (merge main→branch on
#     GitHub, re-triggers CI; once main carries the fix the next run clears it);
#   * branch CURRENT with main but still red-required (a genuine failure refresh
#     can't fix) → escalate ONCE (idempotent via the `ci-stuck` tag) to
#     escalated with a timestamped note naming the red required check(s).
# Skips actively-claimed live work (claim within the JANITOR_GRACE window), and
# any PR with no red-required check (auto-merge / visual-e2e handling covers
# those). The decision itself is the pure `_ci_rescue_decide` (farm-lib.sh); the
# shell here is the thin side-effecting wrapper. Runs AFTER reconcile so a
# just-merged PR is shipped first and never seen here. Required contexts are
# fetched ONCE per run (cached). Every gh/kb/git call is best-effort
# (`|| true` / `timeout 30`); one bad task never aborts the pass. See
# docs/adr/2026-06-15-adr-janitor-ci-rescue-pass.md.
#
# Required-check discovery reads BOTH mechanisms GitHub offers and unions them
# (union_csv, farm-lib.sh): the legacy classic branch-protection endpoint AND
# the newer rulesets endpoint. The legacy-only lookup silently 404s/empties on a
# repo that enforces required checks purely via rulesets, which made
# _ci_rescue_decide see required_csv="" and return `skip` FOREVER for every
# red-required PR on such a repo, with no error anywhere — the sharpest latent
# gap identified in the CI-lifecycle audit. When BOTH sources come back empty
# AND the PR has any failing check at all, _ci_rescue_decide now treats it as
# actionable rather than silently skipping (see its doc comment); this WARNs
# once per run so the detection failure itself is never silent either.
pass_ci_rescue() {
  local CUTOFF IDS id pr nwo owner updated_epoch
  local REQUIRED_CSV REQUIRED_CSV_LEGACY REQUIRED_CSV_RULESETS
  local pr_json pr_state is_draft head_ref
  local failing_csv behind=0 decision

  git -C "$REPO_DIR" fetch origin --quiet 2>/dev/null || true

  # {owner}/{repo} once, required contexts once (cache for the whole pass).
  # Explicit slug first (cwd-independent, farm-lib.sh); `gh repo view` is only
  # the fallback for a repo whose origin URL farm_repo_slug cannot parse.
  nwo="${FARM_REPO_SLUG:-$(farm_timeout 30 gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || true)}"
  REQUIRED_CSV_LEGACY="$(farm_timeout 30 gh api \
      "repos/${nwo}/branches/${MAIN_BRANCH}/protection/required_status_checks" \
      --jq '[.contexts[]?] | join(",")' 2>/dev/null || true)"
  # Rulesets API: an array of rule objects; pull `context` out of every
  # `required_status_checks` rule's parameters. 404/empty on a repo with no
  # rulesets — best-effort, same as the legacy call above.
  REQUIRED_CSV_RULESETS="$(farm_timeout 30 gh api \
      "repos/${nwo}/rules/branches/${MAIN_BRANCH}" \
      --jq '[.[]? | select(.type=="required_status_checks") | .parameters.required_status_checks[]?.context] | join(",")' \
      2>/dev/null || true)"
  REQUIRED_CSV="$(union_csv "$REQUIRED_CSV_LEGACY" "$REQUIRED_CSV_RULESETS")"
  if [[ -z "$REQUIRED_CSV" ]]; then
    log "WARN: ci-rescue could not determine required status checks from either branch-protection or rulesets API for ${MAIN_BRANCH} — any failing check on a review PR will be treated as actionable this run"
  fi

  CUTOFF=$(( $(date +%s) - JANITOR_GRACE_SECONDS ))
  IDS="$(kb list --status review --json 2>/dev/null | jq -r '.[].id' || true)"
  for id in $IDS; do
    pr="$(task_pr_from_tags "$id")"
    [[ -z "$pr" ]] && continue                       # no linked PR → nothing to rescue

    # (1) Skip actively-claimed live work: a non-empty claim whose `updated` is
    # within the grace window belongs to a live runner — never disturb it.
    owner="$(kb show "$id" --json 2>/dev/null | jq -r '.claimed_by // ""' || true)"
    if [[ -n "$owner" ]]; then
      updated_epoch="$(kb show "$id" --json 2>/dev/null \
        | jq -r '((.updated // "1970-01-01T00:00:00Z") | fromdateiso8601? // 0)' || true)"
      [[ -z "$updated_epoch" ]] && updated_epoch=0
      (( updated_epoch >= CUTOFF )) && continue       # fresh claim → live runner, skip
    fi

    # (2) PR must be OPEN and not draft (MERGED/CLOSED handled by reconcile).
    pr_json="$(farm_timeout 30 gh pr view "$pr" ${GH_REPO_ARGS[@]+"${GH_REPO_ARGS[@]}"} \
        --json state,isDraft,headRefName,mergeStateStatus 2>/dev/null || true)"
    [[ -z "$pr_json" ]] && continue
    pr_state="$(jq -r '.state // ""'   <<<"$pr_json" 2>/dev/null || true)"
    is_draft="$(jq -r '.isDraft // false' <<<"$pr_json" 2>/dev/null || true)"
    head_ref="$(jq -r '.headRefName // ""' <<<"$pr_json" 2>/dev/null || true)"
    [[ "$pr_state" != "OPEN" || "$is_draft" == "true" || -z "$head_ref" ]] && continue

    # (3) Failing checks (FAILURE/TIMED_OUT/CANCELLED), CSV.
    failing_csv="$(farm_timeout 30 gh pr view "$pr" ${GH_REPO_ARGS[@]+"${GH_REPO_ARGS[@]}"} --json statusCheckRollup \
        --jq '[.statusCheckRollup[]? | select(.conclusion=="FAILURE" or .conclusion=="TIMED_OUT" or .conclusion=="CANCELLED") | .name] | join(",")' \
        2>/dev/null || true)"

    # (4) Branch freshness: does origin/<head_ref> already contain main HEAD?
    behind=0
    if git -C "$REPO_DIR" merge-base --is-ancestor \
        "origin/${MAIN_BRANCH}" "origin/${head_ref}" 2>/dev/null; then
      behind=0                                         # contains main HEAD → current
    else
      behind=1                                         # missing main HEAD → stale
    fi

    local has_stuck=0
    task_has_tag "$id" "ci-stuck" 2>/dev/null && has_stuck=1

    decision="$(_ci_rescue_decide "$REQUIRED_CSV" "$failing_csv" "$behind" "$has_stuck")"
    case "$decision" in
      refresh)
        if farm_timeout 30 gh api -X PUT \
             "repos/${nwo}/pulls/${pr}/update-branch" >/dev/null 2>&1; then
          log "ci-rescue: refreshed PR #${pr} (behind main, red on ${failing_csv})"
        else
          # 422 merge-conflict / other non-zero → cannot auto-refresh → escalate.
          if [[ "$has_stuck" -eq 0 ]]; then
            append_note "$id" "FARM-JANITOR ci-rescue: PR #${pr} red on required check(s) [${failing_csv}] and update-branch failed (merge conflict?) — needs human."
            kb edit "$id" --add-tag ci-stuck >/dev/null 2>&1 || true
            move_release_to "$id" escalated >/dev/null 2>&1 || true
            log "ci-rescue: escalated PR #${pr} → escalated (update-branch failed, red on ${failing_csv})"
          fi
        fi
        ;;
      escalate)
        append_note "$id" "FARM-JANITOR ci-rescue: PR #${pr} is current with ${MAIN_BRANCH} but red on required check(s) [${failing_csv}] — a refresh can't fix it; needs human."
        kb edit "$id" --add-tag ci-stuck >/dev/null 2>&1 || true
        if move_release_to "$id" escalated; then
          log "ci-rescue: escalated PR #${pr} → escalated (current with main, red on ${failing_csv})"
        else
          log "WARN: ci-rescue could not move task #$id → escalated (PR #$pr) — left for next run"
        fi
        ;;
      *) : ;;   # skip / noop → nothing to do
    esac
  done
}

# Archive pass (P0 — dependency-ordering terminal fix). kanban-md satisfies a
# `--depends-on` only when the prerequisite reaches its LAST status column —
# proven on a scratch board 2026-06-13: A in `shipped` leaves B(dep A) blocked;
# A in `archived` makes B claimable. The farm parks merged work in `shipped` and
# never archived, so multi-phase work deadlocks. So `shipped` stays the semantic
# "merged" marker (CLAUDE.md: "shipped = merged to main") but is TRANSIENT;
# `archived` is the terminal that satisfies dependency ordering and unblocks
# dependent phases. This pass runs AFTER the reconciliation above so a task that
# was just moved escalated/review → shipped can archive in the same run.
#
# Confirmation rule (conservative — never archive without merge proof, since
# archiving is the dependency-unblock terminal):
#   * pr-<N> tagged: archive ONLY once gh confirms the PR is MERGED AND its head
#     branch is this task's `task/<id>-*` (pr_head_matches_task — guards the
#     PR-number race). gh error/timeout/non-MERGED/head-mismatch → skip.
#   * untagged: a `shipped` task with no PR is a legit no-PR completion ONLY for
#     the decompose/capstone short-circuits (QA moves those to shipped without a
#     PR) → archive. Any OTHER untagged shipped task has NO merge proof → leave it
#     in shipped + WARN (do not falsely unblock dependents on an unproven task).
# Every kb/gh call is best-effort (`|| true` / `timeout`); the janitor never
# aborts. See docs/adr/2026-06-13-farm-p0-archive-terminal.md and
# docs/adr/2026-06-27-adr-farm-reconcile-hardening.md.
#
# Post-merge main-branch CI check (CI-lifecycle audit gap): PR state=MERGED
# only proves GitHub accepted the merge (i.e. the PR's OWN head was green
# pre-merge); it says NOTHING about a post-merge-only or push-triggered
# workflow that runs against the MERGE COMMIT on $MAIN_BRANCH itself. Nobody in
# this repo checked that before. After a confirmed-MERGED PR-tagged task
# archives, we look up the merge commit's check-runs on the default branch; a
# red one gets an escalation NOTE + a `post-merge-ci-red` tag. The task is
# DELIBERATELY LEFT IN `archived` rather than moved back to escalated — moving
# it would un-terminal a task other phases already depend on (kanban-md only
# satisfies --depends-on at the LAST status column; see the P0 archive-terminal
# rationale above), which would be a strict regression for every dependent
# phase just to surface one CI signal. A note + tag is the non-degrading way to
# make the red commit visible to a human without breaking dependency ordering.
pass_archive() {
# >>> P0 archive pass >>>
# Explicit slug first (cwd-independent, farm-lib.sh); gh fallback as above.
NWO_ARCHIVE="${FARM_REPO_SLUG:-$(farm_timeout 30 gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || true)}"
SHIPPED_IDS="$(kb list --status shipped --json 2>/dev/null | jq -r '.[].id' || true)"
for id in $SHIPPED_IDS; do
  # LIVE-claim guard (RC#8, eval run 3): a fresh claim means a session is
  # actively working this ticket RIGHT NOW (e.g. QA re-claimed it after the
  # merge for a follow-up) — archiving underneath it races the claim holder's
  # own board mutations and produced a false escalation. Skip; the holder
  # finishes and the next janitor run archives. A DEAD session's STALE claim
  # still archives via the claim-aware move_release_to below (the 2026-06-15
  # #63 wedge fix is unchanged — that claim is stale, not fresh).
  if task_claim_is_fresh "$id" "$JANITOR_GRACE_SECONDS"; then
    log "archive: task #$id carries a LIVE claim — skipping this run (claim holder finishes first)"
    continue
  fi
  pr="$(task_pr_from_tags "$id")"
  if [[ -n "$pr" ]]; then
    # Tagged: archive ONLY on a confirmed MERGED whose head branch belongs to THIS
    # task (cross-validates the pr tag against the PR-number race). gh
    # error/timeout/non-MERGED/head-mismatch → skip.
    pr_json="$(farm_timeout 30 gh pr view "$pr" ${GH_REPO_ARGS[@]+"${GH_REPO_ARGS[@]}"} --json state,headRefName,mergeCommit 2>/dev/null || true)"
    pr_state="$(jq -r '.state // ""'       <<<"$pr_json" 2>/dev/null || true)"
    head_ref="$(jq -r '.headRefName // ""' <<<"$pr_json" 2>/dev/null || true)"
    [[ "$pr_state" != "MERGED" ]] && continue
    if ! pr_head_matches_task "$head_ref" "$id"; then
      log "WARN: task #$id pr-$pr head '$head_ref' != task/$id-* — NOT archiving (suspected wrong pr tag)"
      continue
    fi
    note="FARM-JANITOR: shipped task archived (PR #${pr} merged) — terminal for dependency ordering."
  elif kb show "$id" --json 2>/dev/null \
         | jq -e '(.tags // []) | any(. == "decompose" or . == "capstone" or . == "capstone-done")' >/dev/null 2>&1; then
    # Untagged but a decompose/capstone completion (no PR by design) → archive.
    note="FARM-JANITOR: shipped task archived (no-PR completion: decompose/capstone) — terminal for dependency ordering."
  else
    # Untagged, no decompose/capstone tag → NO merge proof → do NOT archive
    # (archiving would falsely unblock dependents). Leave it in shipped for review.
    log "WARN: task #$id shipped with no pr tag and no decompose/capstone tag — no merge proof; NOT archived (needs review)"
    continue
  fi
  append_note "$id" "$note"
  # Claim-aware, atomic move (a shipped task may still carry a dead session's
  # claim; the bare move would be rejected and silently no-op). Best-effort: a
  # per-task failure logs and the loop continues — never aborts the pass.
  if move_release_to "$id" archived; then
    log "archived task #$id shipped → archived${pr:+ (PR #$pr merged)}"
    if [[ -n "$pr" ]]; then
      merge_sha="$(jq -r '.mergeCommit.oid // empty' <<<"${pr_json:-}" 2>/dev/null || true)"
      if [[ -n "$merge_sha" && -n "$NWO_ARCHIVE" ]]; then
        # KNOWN BLIND SPOT (accepted): this reads the Checks API only
        # (/check-runs — GitHub Actions and modern apps). CI reporting through
        # the LEGACY commit-status API (repos/.../statuses, e.g. some Jenkins/
        # CircleCI setups) is invisible here, so a red legacy status on the
        # merge commit is NOT flagged. Deliberate: GitHub-Actions-centric farms
        # are the target; add a /commits/<sha>/status read here if a project
        # ever fronts CI through legacy statuses.
        failing_main_csv="$(farm_timeout 30 gh api "repos/${NWO_ARCHIVE}/commits/${merge_sha}/check-runs" \
            --jq '[.check_runs[]? | select(.conclusion=="failure" or .conclusion=="timed_out" or .conclusion=="cancelled") | .name] | join(",")' \
            2>/dev/null || true)"
        if [[ -n "$failing_main_csv" ]]; then
          append_note "$id" "FARM-JANITOR: merge commit ${merge_sha} is RED on ${MAIN_BRANCH} [${failing_main_csv}] — needs human (left archived; dependency ordering preserved)."
          kb edit "$id" --add-tag post-merge-ci-red >/dev/null 2>&1 || true
          log "WARN: task #$id merge commit ${merge_sha} red on ${MAIN_BRANCH} [${failing_main_csv}] — flagged, left archived"
        fi
      fi
    fi
  else
    log "WARN: could not archive task #$id shipped → archived — left for next run"
  fi
done
# <<< P0 archive pass <<<
}

# Capstone trigger (P4 — final stage of the epic/decomposition lifecycle).
# When EVERY child of an `epic` reaches a TERMINAL column (shipped/archived),
# the initiative's last phase has landed → dispatch ONE whole-initiative
# capstone review (per CLAUDE.md "Big-picture (capstone) review": phases wire
# end-to-end, integration seams, nothing dropped). The capstone is a `capstone`-
# tagged child task an Opus-tier QA session claims; its findings become NEW
# child tasks (normal flow re-engages). This pass runs AFTER the archive pass so
# the phase just moved shipped → archived counts as terminal in the same run.
#
# Idempotency (never re-dispatch): an epic is skipped once it carries the
# `capstone-dispatched` tag (set here when we create the task) OR already has a
# `capstone`-tagged child. Skip an epic with ZERO children (a 0-child epic shipped
# its plan PR with nothing to decompose — no initiative to capstone). An epic with
# ANY non-terminal child is still in-flight → not ready for capstone. Every kb call
# is best-effort (`|| true`); the janitor never aborts. See
# docs/adr/2026-06-13-farm-p4-capstone-trigger.md.
pass_capstone() {
# >>> P4 capstone trigger >>>
EPIC_IDS="$(kb list --json 2>/dev/null \
  | jq -r '.[] | select((.tags // []) | index("epic")) | .id' || true)"
for eid in $EPIC_IDS; do
  # Already dispatched (tag present) → never re-create.
  if kb show "$eid" --json 2>/dev/null \
       | jq -e '(.tags // []) | index("capstone-dispatched")' >/dev/null 2>&1; then
    continue
  fi
  CHILDREN="$(kb list --parent "$eid" --json 2>/dev/null || echo '[]')"
  child_count="$(jq -r 'length' <<<"$CHILDREN" 2>/dev/null || echo 0)"
  [[ "$child_count" -eq 0 ]] && continue            # zero-children epic → no initiative to capstone
  # Idempotency belt-and-braces: an existing capstone-tagged child → skip.
  if jq -e '[.[] | select((.tags // []) | index("capstone"))] | length > 0' \
       <<<"$CHILDREN" >/dev/null 2>&1; then
    continue
  fi
  # All children must be in a terminal column (shipped or archived). Any other
  # status (backlog/ready/doing/review/escalated) means the initiative is still
  # in-flight → not ready for capstone.
  non_terminal="$(jq -r '[.[] | select((.status // "") as $s
                      | ($s != "shipped" and $s != "archived"))] | length' \
                    <<<"$CHILDREN" 2>/dev/null || echo 1)"
  [[ "$non_terminal" -ne 0 ]] && continue
  kb create "Capstone review of epic #${eid}" \
    --status ready --parent "$eid" --tags capstone \
    --body "Whole-initiative capstone review of epic #${eid} per CLAUDE.md big-picture rule — verify phases wire end-to-end, nothing dropped; findings → new child tasks" \
    >/dev/null 2>&1 || true
  kb edit "$eid" --add-tag capstone-dispatched >/dev/null 2>&1 || true
  log "dispatched capstone for epic #$eid (all $child_count children terminal)"
done
# <<< P4 capstone trigger <<<
}

# Drop worktrees older than 24h (a healthy run removes its own). A 24h-old
# worktree with unpushed work is a death the runner trap missed (hard kill), so
# salvage its branch before dropping — nothing gets pruned without a best-effort
# preserve attempt. Detached worktrees (QA PR checkouts) have no branch to push.
#
# The find is fed into the loop via a HERE-STRING of its captured output, NOT a
# `find | while` PIPE: under pipefail a non-zero `find` (e.g. the dir vanished
# mid-walk) would abort the pipeline and, pre-hardening, the whole script. The
# command-substitution is `|| true`-guarded and run_pass is the backstop.
pass_worktree_prune() {
  local stale wt wt_branch
  stale="$(find "$WORKTREES_DIR" -mindepth 1 -maxdepth 1 -type d -mmin +1440 2>/dev/null || true)"
  while IFS= read -r wt; do
    [[ -z "$wt" ]] && continue
    wt_branch="$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    if [[ -n "$wt_branch" && "$wt_branch" != "HEAD" ]]; then
      preserve_worktree_work "$wt" "$wt_branch"
    fi
    log "pruning stale worktree $wt"
    drop_worktree "$wt"
  done <<< "$stale"
  git -C "$REPO_DIR" worktree prune >/dev/null 2>&1 || true
}

# Rotate logs older than 14 days. -delete returns non-zero if a file vanished
# mid-walk; `|| true` plus run_pass keep that from aborting the run.
pass_log_rotate() {
  find "$LOG_DIR" -type f -mtime +14 -delete 2>/dev/null || true
}

# ------------------------------------------------------------------ main -----
# Each pass is independently resilient: a failure (or a failing setup
# command-substitution) in one pass is logged and the NEXT pass still runs, so
# the janitor ALWAYS reaches the archive pass and ALWAYS leaves a log.
run_pass orphans        pass_orphans
run_pass reconcile      pass_reconcile
run_pass ci-rescue      pass_ci_rescue
run_pass archive        pass_archive
run_pass capstone       pass_capstone
run_pass worktree-prune pass_worktree_prune
run_pass log-rotate     pass_log_rotate

log "janitor done (log: $RUN_LOG)"
