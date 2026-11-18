#!/usr/bin/env bash
# farm-scout.sh — one bounded scout sweep, fired by claude-scout.timer.
# Zero-token guards run BEFORE any model call:
#   1. backpressure: skip if the scout already has >= SCOUT_MAX_OPEN open tasks
#   2. quiet gate:   skip if the last sweep was clean AND main hasn't moved

source "$(dirname "${BASH_SOURCE[0]}")/farm-lib.sh"

# On macOS launchd has no RuntimeMaxSec; self-bound the run to SCOUT_MAX_SECONDS.
# Re-exec once under farm_timeout (the _SCOUT_TIMED sentinel prevents a loop).
if [[ "$(farm_os)" == "macos" && -z "${_SCOUT_TIMED:-}" ]]; then
  export _SCOUT_TIMED=1
  farm_timeout "${SCOUT_MAX_SECONDS:-3600}" "$0" "$@"; exit $?
fi

AGENT_NAME="farm-scout"; export AGENT_NAME
log_billing_guard

SCOUT_MAX_OPEN="${SCOUT_MAX_OPEN:-10}"
SCOUT_MAX_NEW="${SCOUT_MAX_NEW:-5}"
REPORT="$STATE_DIR/scout-report.json"

if gated_now; then log "scout skipped: limit gate / pause active"; exit 0; fi

# Guard 1: backpressure — don't produce faster than implementers consume.
OPEN="$(kb list --tag scout --status backlog,ready,doing,review --json 2>/dev/null | jq 'length' || echo 0)"
if (( OPEN >= SCOUT_MAX_OPEN )); then
  log "scout skipped: $OPEN open scout tasks (cap $SCOUT_MAX_OPEN)"; exit 0
fi

# Guard 2: self-quieting — clean report + unchanged main = nothing to do.
git -C "$REPO_DIR" fetch origin "$MAIN_BRANCH" --quiet || true
MAIN_SHA="$(git -C "$REPO_DIR" rev-parse "origin/$MAIN_BRANCH")"
if [[ -f "$REPORT" ]]; then
  LAST_SHA="$(jq -r '.main_sha // empty' "$REPORT")"
  LAST_CLEAN="$(jq -r '.clean // false' "$REPORT")"
  if [[ "$LAST_SHA" == "$MAIN_SHA" && "$LAST_CLEAN" == "true" ]]; then
    log "scout skipped: last sweep clean at $MAIN_SHA"; exit 0
  fi
fi

WT="$(make_worktree "scout-sweep")"
PROMPT="$(cat "$(farm_resolve prompts/scout.md)")

<farm_context>
AGENT_NAME: $AGENT_NAME
BOARD_DIR: $BOARD_DIR        # every kanban-md call MUST use: kanban-md --dir \"$BOARD_DIR\" ...
MAIN_SHA: $MAIN_SHA
MAX_NEW_TASKS: $SCOUT_MAX_NEW
OPEN_SCOUT_TASKS: $OPEN
REPORT_FILE: $REPORT         # you MUST write this file before finishing
TEMPLATES_DIR: $TEMPLATES_DIR
</farm_context>"

# stream-json + --verbose gives live visibility (farmctl tail scout) by writing
# one JSON event per line as the sweep runs, instead of buffering to session end.
# The scout consumes its result via the separate $REPORT file the model writes —
# NOT by parsing claude's stdout — so the format change does not affect report
# handling. The only stdout-derived logic is the limit check below, whose phrases
# survive as substrings inside JSON-encoded result events (same invariant the
# runner relies on; regression test in agent-farm/tests/run.sh).
# -- resolve the farm constitution (project override wins via farm_resolve) --
FARM_MD="$(farm_resolve FARM.md)"
SYSTEM_ARGS=()
[[ -f "$FARM_MD" ]] && SYSTEM_ARGS=(--append-system-prompt-file "$FARM_MD")

RUN_LOG="$LOG_DIR/scout-$(date +%Y%m%d-%H%M%S).log"
# Confine tool writes to the scout worktree (guard-bash.sh reads these). The
# scout's REPORT lives under STATE_DIR (outside the worktree), so allow that too.
export FARM_WORKTREE="$WT" FARM_STATE_DIR="$STATE_DIR"
set +e
( cd "$WT" && "$CLAUDE_BIN" -p --output-format stream-json --verbose \
    --dangerously-skip-permissions ${SYSTEM_ARGS[@]+"${SYSTEM_ARGS[@]}"} --model "$SCOUT_MODEL" --effort "$SCOUT_EFFORT" "$PROMPT" ) >"$RUN_LOG" 2>&1
RC=$?
set -e
OUT="$(run_log_tail "$RUN_LOG" 100000)"

if output_hit_limit "$OUT"; then
  set_limit_gate_from_run "$OUT" "$RUN_LOG"
elif (( RC != 0 )); then
  log "scout sweep failed rc=$RC — see $RUN_LOG"
elif [[ ! -f "$REPORT" ]] || [[ "$(jq -r '.main_sha // empty' "$REPORT")" != "$MAIN_SHA" ]]; then
  # Model forgot the report — write a conservative one so the gate never wedges open.
  jq -n --arg sha "$MAIN_SHA" '{main_sha:$sha, clean:false, note:"report missing; rewritten by runner"}' >"$REPORT"
fi

drop_worktree "$WT"
log "scout sweep finished rc=$RC (log: $RUN_LOG)"
