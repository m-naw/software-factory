# shellcheck shell=bash
# farm-lib.sh — shared helpers for the Claude agent farm. Sourced, not executed.

set -euo pipefail

# ---------------------------------------------------------------- layout ----
# This file lives at <repo>/agent-farm/bin/farm-lib.sh — derive paths from it.
FARM_BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FARM_DIR="$(dirname "$FARM_BIN")"
# REPO_DIR is the TARGET repo, from an explicit signal — NOT a path-walk from the
# engine (which now lives in the plugin cache). Order: explicit env → Claude
# project dir → git root of CWD → CWD.
REPO_DIR="${FARM_REPO_DIR:-${REPO_DIR:-${CLAUDE_PROJECT_DIR:-$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || pwd)}}}"
BOARD_DIR="$REPO_DIR/kanban"
STATE_DIR="$REPO_DIR/.agent-farm/state"      # was $FARM_DIR/state (ephemeral under plugin)
LOG_DIR="$STATE_DIR/logs"
WORKTREES_DIR="$REPO_DIR/.farm-worktrees"
# shellcheck disable=SC2034  # consumed by sourcing scripts (farm-runner.sh, farm-scout.sh)
PROMPTS_DIR="$FARM_DIR/prompts"
# shellcheck disable=SC2034  # consumed by sourcing scripts (farm-scout.sh)
TEMPLATES_DIR="$FARM_DIR/templates"

mkdir -p "$STATE_DIR" "$LOG_DIR" "$WORKTREES_DIR"

# ===== Portability (Linux / macOS) =========================================
# Every GNU-only tool call in the engine routes through a helper below so the
# same behavior holds on stock macOS (bash 3.2, BSD userland) with no new deps.
_FARM_OS=""
farm_os() {
  if [[ -z "$_FARM_OS" ]]; then
    if [[ -n "${FARM_OS_OVERRIDE:-}" ]]; then
      _FARM_OS="$FARM_OS_OVERRIDE"
    elif [[ "$(uname -s)" == "Darwin" ]]; then
      _FARM_OS="macos"
    else
      _FARM_OS="linux"
    fi
  fi
  printf '%s\n' "$_FARM_OS"
}

# GNU `date -Is` -> local ISO with ±HH:MM. BSD emits ±HHMM; insert the colon.
_iso_fix_offset() { # stdin: an ISO ts; insert ':' into a trailing ±HHMM offset
  sed -E 's/([+-][0-9]{2})([0-9]{2})$/\1:\2/'
}
farm_now_iso() {
  if command -v gdate >/dev/null 2>&1; then gdate -Is; return; fi
  if [[ "$(farm_os)" == "macos" ]]; then
    date +%Y-%m-%dT%H:%M:%S%z | _iso_fix_offset
  else
    date -Is
  fi
}
farm_epoch_to_iso() { # <epoch>
  local e="$1"
  if command -v gdate >/dev/null 2>&1; then gdate -d "@$e" -Is; return; fi
  if [[ "$(farm_os)" == "macos" ]]; then
    date -r "$e" +%Y-%m-%dT%H:%M:%S%z | _iso_fix_offset
  else
    date -d "@$e" -Is
  fi
}
farm_iso_to_epoch() { # <iso>  (accepts ...Z, ±HHMM, ±HH:MM)
  local iso="$1"
  if command -v gdate >/dev/null 2>&1; then gdate -d "$iso" +%s; return; fi
  if [[ "$(farm_os)" == "macos" ]]; then
    # Normalize for BSD `date -j -f`: Z -> +0000; strip ':' from ±HH:MM.
    local norm="${iso/%Z/+0000}"
    norm="$(printf '%s' "$norm" | sed -E 's/([+-][0-9]{2}):([0-9]{2})$/\1\2/')"
    if printf '%s' "$norm" | grep -qE '[+-][0-9]{4}$'; then
      date -j -f "%Y-%m-%dT%H:%M:%S%z" "$norm" +%s
    else
      date -j -u -f "%Y-%m-%dT%H:%M:%S" "$norm" +%s
    fi
  else
    date -d "$iso" +%s
  fi
}
# Pure decider: map (spec, today's weekday, platform) -> a `date` argv, ONE
# token per line. The GNU `-d` date PHRASE is a single token so it survives as
# one argument (unquoted word-splitting a flat string broke `date -d`). specs:
# "today HH:MM" | "tomorrow HH:MM" | "next <weekday> 00:00"
_when_epoch_decide() { # <spec> <today_weekday_lower> [platform=auto]  -> argv, one per line
  local spec="$1" today="$2" plat="${3:-$(farm_os)}" macos=0
  [[ "$plat" == "macos" ]] && macos=1
  case "$spec" in
    "today "*)
      local hhmm="${spec#today }"
      if (( macos )); then printf '%s\n' "-v${hhmm%%:*}H" "-v${hhmm##*:}M" "-v0S" "+%s"
      else printf '%s\n' "-d" "today ${hhmm}" "+%s"; fi ;;
    "tomorrow "*)
      local hhmm="${spec#tomorrow }"
      if (( macos )); then printf '%s\n' "-v+1d" "-v${hhmm%%:*}H" "-v${hhmm##*:}M" "-v0S" "+%s"
      else printf '%s\n' "-d" "tomorrow ${hhmm}" "+%s"; fi ;;
    "next "*)
      local day="${spec#next }"; day="${day%% *}"
      # Case-insensitive: the real caller (set_limit_gate_from_output) builds
      # this spec from a `^(Mon|Tue|Wed|Thu|Fri|Sat|Sun)` regex match, i.e.
      # CAPITALIZED "Mon" — while `today` (below) is always lowercased. BSD
      # `date -v` and GNU `date -d` both accept lowercase weekday
      # abbreviations, so lowercasing here is safe on both platforms.
      day="$(printf '%s' "$day" | tr '[:upper:]' '[:lower:]')"
      if (( macos )); then
        # Deterministic DAY ARITHMETIC, not `-v<weekday>`: BSD `date -v<wd>`
        # semantics are ambiguous — it can resolve to THIS week's occurrence
        # (i.e. the past) instead of the next one, which is what produced the
        # negative-delta bug. Map weekday name -> ISO number (mon=1..sun=7),
        # compute the forward-only delta, and use the unambiguous BSD
        # `-v+Nd` relative form instead. "next <today>" always means +7, not
        # +0 — never emit a same-day (zero-advance) result.
        local target=0 tnum=0 days
        case "${day:0:3}" in
          mon) target=1 ;; tue) target=2 ;; wed) target=3 ;; thu) target=4 ;;
          fri) target=5 ;; sat) target=6 ;; sun) target=7 ;;
        esac
        case "$today" in
          mon) tnum=1 ;; tue) tnum=2 ;; wed) tnum=3 ;; thu) tnum=4 ;;
          fri) tnum=5 ;; sat) tnum=6 ;; sun) tnum=7 ;;
        esac
        days=$(( (target - tnum + 7) % 7 ))
        (( days == 0 )) && days=7
        printf '%s\n' "-v+${days}d" "-v0H" "-v0M" "-v0S" "+%s"
      else printf '%s\n' "-d" "next ${day} 00:00" "+%s"; fi ;;
    *) printf '%s\n' "-d" "${spec}" "+%s" ;;
  esac
}
farm_when_epoch() { # <spec>
  local spec="$1" today out line
  today="$(date +%a | tr '[:upper:]' '[:lower:]')"
  local -a argv=()
  if command -v gdate >/dev/null 2>&1 && [[ "$(farm_os)" == "macos" ]]; then
    out="$(_when_epoch_decide "$spec" "$today" linux)"
    while IFS= read -r line; do argv+=("$line"); done <<<"$out"
    gdate "${argv[@]}"; return
  fi
  out="$(_when_epoch_decide "$spec" "$today")"
  while IFS= read -r line; do argv+=("$line"); done <<<"$out"
  date "${argv[@]}"
}

# Normalize a 12-hour am/pm time ("9am", "10:30pm", "12am", "12pm") into 24h
# "HH:MM". An already-24h "HH:MM" (no am/pm suffix) passes through unchanged.
# _when_epoch_decide's "today HH:MM"/"tomorrow HH:MM" contract is documented
# as 24h — its macOS branch splits the spec on ':' to build BSD `date -v`
# tokens, so an unnormalized "9am" mangles into "-v9amH" (`date -v` rejects
# it), silently falling through to the caller's fallback. GNU `date -d "today
# 9am"` parses fine, which is why this only bites on macOS — normalize
# unconditionally (no OS branch) so callers never pass am/pm through, on
# either platform. bash 3.2-safe (no ${x^^}, no associative arrays).
_normalize_ampm_time() { # <time> -> HH:MM
  local t="$1" h m mer
  if [[ "$t" =~ ^([0-9]{1,2})(:([0-9]{2}))?(am|pm)$ ]]; then
    h="${BASH_REMATCH[1]}"; m="${BASH_REMATCH[3]:-00}"; mer="${BASH_REMATCH[4]}"
    h=$((10#$h))  # force decimal (a leading zero would otherwise read as octal)
    if [[ "$mer" == "am" ]]; then
      (( h == 12 )) && h=0
    else
      (( h != 12 )) && h=$((h + 12))
    fi
    printf '%02d:%s\n' "$h" "$m"
  else
    printf '%s\n' "$t"
  fi
}

farm_timeout() { # <seconds> <cmd...>
  local secs="$1"; shift
  # _FARM_FORCE_BASH_TIMEOUT lets the test suite exercise the fallback even on a
  # host that has GNU `timeout` (which would otherwise not process-group-kill).
  if [[ -z "${_FARM_FORCE_BASH_TIMEOUT:-}" ]]; then
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"; return; fi
    if command -v gtimeout >/dev/null 2>&1; then gtimeout "$secs" "$@"; return; fi
  fi
  _bash_timeout "$secs" "$@"
}
_bash_timeout() { # <seconds> <cmd...>  — pure-bash fallback, process-group kill
  local secs="$1"; shift
  local cmd_pid killer_pid rc had_m=0
  # Run the command as its own process-group leader so we can kill its whole
  # tree (gh spawns git/credential helpers). `setsid` if present, else enable
  # job control briefly so the backgrounded job becomes a group leader — and
  # SAVE/RESTORE the caller's monitor-mode flag (farm-lib is SOURCED; leaking
  # `set -m` into the caller is a real bug).
  if command -v setsid >/dev/null 2>&1; then
    setsid "$@" &
    cmd_pid=$!
  else
    case $- in *m*) had_m=1;; esac
    set -m; "$@" &
    cmd_pid=$!
    [[ "$had_m" -eq 0 ]] && set +m
  fi
  ( sleep "$secs"; kill -TERM "-$cmd_pid" 2>/dev/null
    sleep 2; kill -KILL "-$cmd_pid" 2>/dev/null ) &
  killer_pid=$!
  wait "$cmd_pid" 2>/dev/null; rc=$?
  kill "$killer_pid" 2>/dev/null; wait "$killer_pid" 2>/dev/null
  return "$rc"
}

farm_stat_size() { # <file>  -> bytes or "?"
  if [[ "$(farm_os)" == "macos" ]]; then
    stat -f %z "$1" 2>/dev/null || echo "?"
  else
    stat -c %s "$1" 2>/dev/null || echo "?"
  fi
}
farm_sed_inplace() { # <sed-script> <file>
  if [[ "$(farm_os)" == "macos" ]]; then
    sed -i '' "$1" "$2"
  else
    sed -i "$1" "$2"
  fi
}

# Best-effort PATH for launchd's EnvironmentVariables dict: launchd-spawned
# processes get a minimal PATH (/usr/bin:/bin:/usr/sbin:/sbin — no login-shell
# PATH), so bake in claude's and kanban-md's dirs when found, ahead of the
# Homebrew/OS-default base. Mirrors engine/install.sh's _macos_path_env
# EXACTLY (same base, same two `command -v` lookups, same prepend order) —
# install.sh isn't sourced here (too heavy for a one-shot installer), so this
# is a deliberate parallel helper, not a shared one. Keep them in lockstep.
farm_macos_path_env() {
  local p="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" d
  d="$(command -v kanban-md 2>/dev/null || true)"; [[ -n "$d" ]] && p="$(dirname "$d"):$p"
  d="$(command -v claude 2>/dev/null || true)";    [[ -n "$d" ]] && p="$(dirname "$d"):$p"
  printf '%s' "$p"
}

# ----- supervision (systemd --user | launchd) -------------------------------
# Maps supervision verbs (enable a worker, kick off a scout run, tear
# everything down, ...) to the platform's service manager so callers
# (farmctl, install.sh) go through ONE API. Every `_sup_*_argv` decider is
# PURE: it only echoes the argv string it would run, so it's unit-testable by
# forcing FARM_OS_OVERRIDE without ever invoking systemctl/launchctl. The thin
# `sup_*` wrappers eval that argv. launchd has no unit globbing, so any verb
# that needs to hit "all workers" must enumerate concrete plist files/labels.
LAUNCHD_DIR="${LAUNCHD_DIR:-$HOME/Library/LaunchAgents}"
LAUNCHD_PREFIX="com.agent-farm"
_sup_domain() { printf 'gui/%s' "$(id -u)"; }

_sup_enable_worker_argv() { # <role> <n>
  local role="$1" n="$2"
  if [[ "$(farm_os)" == "macos" ]]; then
    printf 'launchctl bootstrap %s %s/%s.worker.%s-%s.plist' \
      "$(_sup_domain)" "$LAUNCHD_DIR" "$LAUNCHD_PREFIX" "$role" "$n"
  else
    printf 'systemctl --user enable --now claude-farm@%s-%s.service' "$role" "$n"
  fi
}
# Symmetric with _sup_enable_worker_argv: tear down ONE concrete instance.
# launchd has no per-instance template glob (unlike systemd's `@N` unit
# instances), so scale-DOWN needs a targeted single-instance verb, not just
# the "all workers" enumeration sup_disable_all_workers already does.
_sup_disable_worker_argv() { # <role> <n>
  local role="$1" n="$2"
  if [[ "$(farm_os)" == "macos" ]]; then
    printf 'launchctl bootout %s/%s.worker.%s-%s' \
      "$(_sup_domain)" "$LAUNCHD_PREFIX" "$role" "$n"
  else
    printf 'systemctl --user disable --now claude-farm@%s-%s.service' "$role" "$n"
  fi
}
_sup_scout_now_argv() {
  if [[ "$(farm_os)" == "macos" ]]; then
    printf 'launchctl kickstart %s/%s.scout' "$(_sup_domain)" "$LAUNCHD_PREFIX"
  else
    printf 'systemctl --user start claude-scout.service'
  fi
}
_sup_start_timers_argv() {
  if [[ "$(farm_os)" == "macos" ]]; then
    printf 'launchctl bootstrap %s %s/%s.scout.plist %s/%s.janitor.plist' \
      "$(_sup_domain)" "$LAUNCHD_DIR" "$LAUNCHD_PREFIX" "$LAUNCHD_DIR" "$LAUNCHD_PREFIX"
  else
    printf 'systemctl --user enable --now claude-scout.timer claude-janitor.timer'
  fi
}
# Not eval'd directly (sup_disable_all_workers/sup_stop_all enumerate labels
# themselves, since launchd needs one bootout per concrete label) — these
# deciders exist so the shape of "what would we run" stays testable/documented
# the same way as the eval'd deciders above.
_sup_disable_all_argv() {
  if [[ "$(farm_os)" == "macos" ]]; then
    printf 'launchctl bootout %s/%s.worker.<label>' "$(_sup_domain)" "$LAUNCHD_PREFIX"
  else
    printf "systemctl --user disable --now 'claude-farm@*'"
  fi
}
_sup_stop_all_argv() {
  if [[ "$(farm_os)" == "macos" ]]; then
    printf 'launchctl bootout %s/%s.worker.<label> ; launchctl bootout %s/%s.scout ; launchctl bootout %s/%s.janitor' \
      "$(_sup_domain)" "$LAUNCHD_PREFIX" "$(_sup_domain)" "$LAUNCHD_PREFIX" "$(_sup_domain)" "$LAUNCHD_PREFIX"
  else
    printf 'systemctl --user stop claude-scout.timer claude-janitor.timer'
  fi
}
_sup_list_workers_argv() {
  if [[ "$(farm_os)" == "macos" ]]; then
    printf 'launchctl list | grep %s.worker' "$LAUNCHD_PREFIX"
  else
    printf "systemctl --user list-units --all 'claude-farm@*'"
  fi
}
_sup_status_argv() {
  if [[ "$(farm_os)" == "macos" ]]; then
    printf 'launchctl list | grep %s ; ls -1 %s/%s.*.plist' "$LAUNCHD_PREFIX" "$LAUNCHD_DIR" "$LAUNCHD_PREFIX"
  else
    printf "systemctl --user list-units --all 'claude-*'"
  fi
}

# Validate the only externally-influenced inputs BEFORE they reach an argv/eval.
_sup_valid_role() { case "$1" in implementer|qa|scout|janitor) return 0;; *) return 1;; esac; }
_sup_valid_n()    { [[ "$1" =~ ^[0-9]+$ ]]; }

# Thin wrappers run the argv. argv is built from internal constants + validated
# role/n only, so `eval` is safe here (no untrusted data reaches it).
sup_scout_now() {
  local a; a="$(_sup_scout_now_argv)"
  # shellcheck disable=SC2086  # argv is internal, not from user/untrusted input
  eval "$a"
}
sup_start_timers() {
  local a; a="$(_sup_start_timers_argv)"
  # shellcheck disable=SC2086  # argv is internal, not from user/untrusted input
  eval "$a"
}
sup_enable_worker() { # <role> <n>
  local role="${1:-}" n="${2:-}"
  _sup_valid_role "$role" || { log "sup: refusing invalid role '$role'"; return 2; }
  _sup_valid_n "$n"       || { log "sup: refusing invalid instance '$n'"; return 2; }
  if [[ "$(farm_os)" == "macos" ]]; then
    # launchd has no unit-template globbing (unlike systemd's `@instance`), so
    # the per-instance plist must exist as a concrete file before `launchctl
    # bootstrap` can load it. install.sh's render_units() deliberately skips
    # @INSTANCE@ substitution for the worker template — see its comment — and
    # defers it here, to the moment a concrete instance is actually scaled up.
    # Same substitution idiom as install.sh's render_units() (portable sed,
    # template -> new file), just with @INSTANCE@ added — including the SAME
    # NO_COLOR-anchored PATH injection render_units uses for scout/janitor, so
    # workers get a real PATH too (launchd's default PATH is minimal and can't
    # find kanban-md/claude/gh, which crash-loops the worker under set -e).
    local tmpl="$FARM_DIR/engine/launchd/com.agent-farm.worker.plist.template" path_env
    path_env="$(farm_macos_path_env)"
    mkdir -p "$LAUNCHD_DIR"
    sed -e "s|@INSTANCE@|$role-$n|g" \
        -e "s|@REPO_DIR@|$REPO_DIR|g" \
        -e "s|@FARM_BIN@|$FARM_BIN|g" \
        -e "s|@LOG_DIR@|$LOG_DIR|g" \
        -e "s|<key>NO_COLOR</key>|<key>PATH</key><string>${path_env}</string><key>NO_COLOR</key>|" \
        "$tmpl" > "$LAUNCHD_DIR/$LAUNCHD_PREFIX.worker.$role-$n.plist"
  fi
  local a; a="$(_sup_enable_worker_argv "$role" "$n")"
  # shellcheck disable=SC2086  # argv is internal + validated role/n, not untrusted input
  eval "$a"
}
# Symmetric with sup_enable_worker: tear down ONE instance (used by
# farmctl's scale_role to remove above-target instances — the only sup_*
# verb that needs a single, targeted teardown rather than "all workers").
sup_disable_worker() { # <role> <n>
  local role="${1:-}" n="${2:-}"
  _sup_valid_role "$role" || { log "sup: refusing invalid role '$role'"; return 2; }
  _sup_valid_n "$n"       || { log "sup: refusing invalid instance '$n'"; return 2; }
  local a; a="$(_sup_disable_worker_argv "$role" "$n")"
  if [[ "$(farm_os)" == "macos" ]]; then
    # bootout can fail if the label was never loaded (e.g. plist rendered but
    # never bootstrapped) — best-effort, same tolerance as sup_disable_all_workers.
    # shellcheck disable=SC2086  # argv is internal + validated role/n, not untrusted input
    eval "$a" 2>/dev/null || true
    rm -f "$LAUNCHD_DIR/$LAUNCHD_PREFIX.worker.$role-$n.plist"
  else
    # shellcheck disable=SC2086  # argv is internal + validated role/n, not untrusted input
    eval "$a"
  fi
}
# Enumerate concrete labels (launchd has no glob) and bootout each.
sup_disable_all_workers() {
  if [[ "$(farm_os)" == "macos" ]]; then
    local f label
    for f in "$LAUNCHD_DIR/$LAUNCHD_PREFIX".worker.*.plist; do
      [[ -e "$f" ]] || continue
      label="$(basename "$f" .plist)"
      launchctl bootout "$(_sup_domain)/$label" 2>/dev/null || true
      rm -f "$f"
    done
  else
    systemctl --user stop 'claude-farm@*' 2>/dev/null || true
    systemctl --user disable 'claude-farm@*' 2>/dev/null || true
  fi
}
sup_stop_all() { # workers + timers
  sup_disable_all_workers
  if [[ "$(farm_os)" == "macos" ]]; then
    local t label
    for t in scout janitor; do
      label="$LAUNCHD_PREFIX.$t"
      launchctl bootout "$(_sup_domain)/$label" 2>/dev/null || true
    done
  else
    systemctl --user disable --now claude-scout.timer claude-janitor.timer 2>/dev/null || true
  fi
}
sup_list_workers() {
  if [[ "$(farm_os)" == "macos" ]]; then
    launchctl list 2>/dev/null | grep "$LAUNCHD_PREFIX.worker" || true
  else
    systemctl --user list-units --all 'claude-farm@*' 2>/dev/null || true
  fi
}
sup_status() {
  if [[ "$(farm_os)" == "macos" ]]; then
    launchctl list 2>/dev/null | grep "$LAUNCHD_PREFIX" || true
    ls -1 "$LAUNCHD_DIR/$LAUNCHD_PREFIX".*.plist 2>/dev/null || true
  else
    systemctl --user list-units --all 'claude-*' 2>/dev/null || true
  fi
}
sup_logs() { # [unit]
  if [[ "$(farm_os)" == "macos" ]]; then
    tail -F "$LOG_DIR"/*.log 2>/dev/null
  else
    journalctl --user -f -u "${1:-claude-farm@*}"
  fi
}

# Live human-readable renderer: follow RUN_LOG -> READABLE_LOG via FARM_LOG_FMT,
# self-terminating when CLAUDE_PID exits — WITHOUT `tail --pid` (absent on BSD).
# A reaper polls the claude pid and, when it is gone, kills the renderer wrapper
# AND its pipeline children (`tail -F`, `jq`) via `pkill -P` — portable on both
# Linux and macOS, and required because `tail -F` never EOFs on its own so killing
# the wrapper alone would leak it. The pid is published via the GLOBAL `RENDER_PID`,
# NOT via stdout/command-substitution: the backgrounded jobs would inherit the
# `$(...)` pipe as fd1 and never close it, so `$(...)` would block forever. Every
# backgrounded job is fd-detached (`>/dev/null 2>&1`), mirroring start_lease_guard
# (farm-runner.sh:221).
RENDER_PID=""
_reap_render() { # <wrapper_pid>  — kill the pipeline children then the wrapper
  pkill -P "$1" 2>/dev/null || true
  kill -TERM "$1" 2>/dev/null || true
}
start_readable_renderer() { # <claude_pid> <run_log> <readable_log>  -> sets $RENDER_PID
  local cpid="$1" run_log="$2" readable_log="$3"
  ( tail -n +1 -F "$run_log" 2>/dev/null \
      | jq -R --unbuffered -r "$FARM_LOG_FMT" 2>/dev/null > "$readable_log" ) >/dev/null 2>&1 &
  RENDER_PID=$!
  ( while kill -0 "$cpid" 2>/dev/null; do sleep 1; done
    _reap_render "$RENDER_PID" ) >/dev/null 2>&1 &
}

# Config precedence: target-repo override wins, else plugin/farm default.
farm_resolve() {
  local rel="$1"
  if [[ -n "${REPO_DIR:-}" && -f "$REPO_DIR/.agent-farm/$rel" ]]; then
    printf '%s\n' "$REPO_DIR/.agent-farm/$rel"
  else
    printf '%s\n' "${CLAUDE_PLUGIN_ROOT:-$FARM_DIR}/defaults/$rel"
  fi
}

# Detect the exact silent-stall bug: a systemd unit's Environment=REPO_DIR=<X>
# baked at install time by install.sh's sed substitution, where <X> has since
# been deleted (a /tmp worktree GC'd) or renamed. A stale REPO_DIR means the
# runner's WorkingDirectory doesn't exist, so the unit fails on every restart
# with NO ready-task pickup and no obvious operator-facing error. Used by
# `farmctl doctor` (kept here, not inlined, so it's unit-testable without a
# real systemd). Returns 0 (true/"stale") when the path is missing or empty,
# 1 (false/"fine") when it exists as a directory.
farm_unit_repo_dir_stale() { # repo_dir -> 0=stale 1=fine
  local d="$1"
  [[ -z "$d" ]] && return 0
  [[ -d "$d" ]] && return 1
  return 0
}

# API-billing opt-in is read from the PROCESS environment only, BEFORE farm.env
# is sourced: a repo's .agent-farm/farm.env (mergeable by a PR) must not enable it.
# readonly: farm.env is sourced as bash, so a plain capture could just be
# reassigned there. Assigning a readonly variable aborts the source under set -e
# ("…: readonly variable") — fail closed. Guarded so a second source in the same
# shell keeps the first capture instead of erroring.
if [[ "$(declare -p _FARM_ALLOW_API_BILLING_ENV 2>/dev/null)" != "declare -r"* ]]; then
  readonly _FARM_ALLOW_API_BILLING_ENV="${FARM_ALLOW_API_BILLING:-0}"
fi
# Same capture/readonly/guard for the notify command (see farm_notify below).
if [[ "$(declare -p _FARM_NOTIFY_CMD_ENV 2>/dev/null)" != "declare -r"* ]]; then
  readonly _FARM_NOTIFY_CMD_ENV="${FARM_NOTIFY_CMD:-}"
fi
# ...and for its timeout: a repo's farm.env must not stretch the bound.
if [[ "$(declare -p _FARM_NOTIFY_TIMEOUT_ENV 2>/dev/null)" != "declare -r"* ]]; then
  readonly _FARM_NOTIFY_TIMEOUT_ENV="${FARM_NOTIFY_TIMEOUT_SECONDS:-}"
fi

# Optional overrides (POLL_SECONDS, QA_MODEL, SCOUT_MAX_OPEN, ...)
_farm_env="$(farm_resolve farm.env)"
# shellcheck disable=SC1090  # dynamic path from farm_resolve; sourced only if present
[[ -f "$_farm_env" ]] && source "$_farm_env"

POLL_SECONDS="${POLL_SECONDS:-60}"
QA_POLL_SECONDS="${QA_POLL_SECONDS:-30}"
# Per-role model selection. Committed defaults live HERE (never solely in
# farm.env) so the choice survives a git stash/pull dance — the 2026-06-13
# outage was an uncommitted ANTHROPIC_MODEL=opus line in farm.env vanishing,
# dropping the implementer onto settings.json's default (claude-fable-5), which
# subscription auth can't reach → every session exited 404 in ~2s. The runner
# and scout pass each as an explicit `claude --model "$X_MODEL"` flag (the QA
# precedent proven robust through that outage), so model selection never
# depends on env alone. ANTHROPIC_MODEL still works as an optional override.
QA_MODEL="${QA_MODEL:-opus}"
IMPL_MODEL="${IMPL_MODEL:-opus}"
# Implementer model for tier:light tasks (the conservative Light pipeline).
# See docs/superpowers/specs/2026-06-22-farm-complexity-tiering-design.md.
IMPL_MODEL_LIGHT="${IMPL_MODEL_LIGHT:-sonnet}"
# QA model for tier:light tasks. QA now tiers per task like the implementer
# (resolve_qa_model), with the SAME hard safety floor: a protected-path citation
# forces opus ABSOLUTE, above any tier/override. Heavy/default stays $QA_MODEL
# (opus); QA EFFORT is never tiered down (stays $QA_EFFORT).
QA_MODEL_LIGHT="${QA_MODEL_LIGHT:-sonnet}"
SCOUT_MODEL="${SCOUT_MODEL:-opus}"
# Per-role reasoning EFFORT, pinned with explicit `claude --effort` flags so the
# farm never inherits the CLI's version-dependent DEFAULT effort (it differs by
# model and can shift on a CLI upgrade). Implementer effort is resolved per task
# (resolve_impl_effort): heavy at IMPL_EFFORT, light at IMPL_EFFORT_LIGHT. Both
# DEFAULT to `medium` — the operator chose NOT to lower light on quality grounds
# (2026-06-30); the separate IMPL_EFFORT_LIGHT knob lets light be tuned DOWN (e.g.
# `low`) independently of heavy later, via farm.env, with no code change. QA and
# scout stay at `high`. See docs/adr/2026-06-28-adr-farm-per-role-effort.md +
# docs/adr/2026-06-30-adr-farm-effort-by-complexity.md.
IMPL_EFFORT="${IMPL_EFFORT:-medium}"
IMPL_EFFORT_LIGHT="${IMPL_EFFORT_LIGHT:-medium}"
QA_EFFORT="${QA_EFFORT:-high}"
SCOUT_EFFORT="${SCOUT_EFFORT:-high}"
# Stage-2 decomposition breadth cap (epic/decomposition lifecycle). At most this
# many phase children per epic; overflow escalates the epic to escalated
# (never silent truncation). One source for both prompts (qa.md / implementer.md)
# and any future code. See docs/adr/2026-06-13-farm-p2-decomposition.md.
EPIC_MAX_CHILDREN="${EPIC_MAX_CHILDREN:-12}"
CLAIM_REFRESH_SECONDS="${CLAIM_REFRESH_SECONDS:-900}"   # < claim_timeout (2h)
LIMIT_FALLBACK_SECONDS="${LIMIT_FALLBACK_SECONDS:-1800}"
MAIN_BRANCH="${MAIN_BRANCH:-main}"
CLAUDE_BIN="${CLAUDE_BIN:-claude}"

# Fail fast in scripts instead of retrying 10x inside claude.
export CLAUDE_CODE_MAX_RETRIES="${CLAUDE_CODE_MAX_RETRIES:-3}"

# Marks every process descended from a farm runner/scout/janitor; consumed by
# guard-bash.sh to scope the PreToolUse safety net to farm agents only.
export FARM_AGENT=1

kb() { kanban-md --dir "$BOARD_DIR" "$@"; }

log() { printf '%s [%s] %s\n' "$(farm_now_iso)" "${AGENT_NAME:-farm}" "$*" >&2; }

# Subscription billing guard. In -p mode ANTHROPIC_API_KEY / ANTHROPIC_AUTH_TOKEN
# override the subscription login, so a stray key silently switches the farm to
# API billing. `export -n` drops them from every child process (every `claude`
# launch) while keeping the shell variable, so `farmctl audit` still sees and
# warns about it. Opt out with FARM_ALLOW_API_BILLING=1 in the process env (not
# farm.env). Silent here (every farmctl call sources this); runner and scout
# call log_billing_guard once at startup. Never logs the value.
FARM_DROPPED_API_VARS=""
if [[ "$_FARM_ALLOW_API_BILLING_ENV" != 1 ]]; then
  for _farm_k in ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN; do
    if [[ -n "${!_farm_k+x}" ]]; then builtin export -n "${_farm_k?}"; FARM_DROPPED_API_VARS+=" $_farm_k"; fi
  done
  unset _farm_k
fi
log_billing_guard() {
  [[ -z "$FARM_DROPPED_API_VARS" ]] && return 0
  log "billing guard: dropped${FARM_DROPPED_API_VARS} from claude's environment (subscription auth only; set FARM_ALLOW_API_BILLING=1 in the service environment to keep)"
}

# farm_notify <event> <plan> <unit> [reason] — dispatch FARM_NOTIFY_CMD <event> <plan> <unit>
# with <reason> on stdin. Best effort: ALWAYS rc 0 (a notifier must never stop the
# conductor). Spec 4.3: the command comes from the process environment only, never a
# repo file (the conductor executes it), so _FARM_NOTIFY_CMD_ENV is captured readonly
# above, before farm.env is sourced.
_notify_args_ok() { # <event> <plan> <unit>
  local re='^[A-Za-z0-9 ._/-]+$'
  case "$1" in unit-shipped|limit|awaiting-operator-merge|pause|stop) ;; *) return 1 ;; esac
  [[ "$2" =~ $re && "$3" =~ $re && "$2" != -* && "$3" != -* ]]  # leading - could read as an option
}
farm_notify() {
  local event="${1:-}" plan="${2:-}" unit="${3:-}" reason="${4:-}" cmd t file rc=0
  if ! _notify_args_ok "$event" "$plan" "$unit"; then
    log "notify: rejected invalid event/plan/unit (event='$(printf '%s' "$event" | tr -cd 'A-Za-z0-9._-' | cut -c1-40)'); not sent"; return 0
  fi
  cmd="${_FARM_NOTIFY_CMD_ENV:-}"
  if [[ -z "$cmd" ]]; then log "notify: FARM_NOTIFY_CMD unset; $event not sent"; return 0; fi
  t="${_FARM_NOTIFY_TIMEOUT_ENV:-20}"; [[ "$t" =~ ^[1-9][0-9]*$ ]] || t=20  # 0 would disable GNU timeout's bound
  file="$(mktemp "${TMPDIR:-/tmp}/farm-notify.XXXXXX")" || { log "notify: mktemp failed; $event not sent"; return 0; }
  printf '%s\n' "$reason" > "$file"
  # stdin via a file redirect inside bash -c: _bash_timeout backgrounds its command,
  # which would detach a piped stdin. All values stay positional (no eval, no splitting).
  farm_timeout "$t" bash -c '"$1" "$2" "$3" "$4" < "$5"' _ "$cmd" "$event" "$plan" "$unit" "$file" || rc=$?
  rm -f "$file"
  (( rc == 0 )) || log "notify: command failed (rc=$rc) for $event"
  return 0
}

# Defuse the farm's own prompt-framing tags when they appear inside an untrusted
# ticket body (stdin -> stdout). A scout transcribes attacker-influenceable repo
# content (PR bodies, code comments, fixtures) into a ticket, which then drives
# an implementer under --dangerously-skip-permissions; a raw `</task>` would
# close the framing early, and a forged `<farm_context>` could spoof the trusted
# half of the prompt. Inserting a space breaks the exact-string tag while
# keeping the text legible to the model. Prompt-level defense ONLY — the guard
# hook + branch protection + protected paths remain the deterministic backstop
# (see SECURITY.md "Prompt injection via ticket content").
defuse_framing_tags() { sed -E 's#<(/?)(task|farm_context)>#<\1 \2>#g'; }

# ------------------------------------------------- explicit gh repo target --
# Every `gh pr ...`/`gh api repos/...` call in the farm MUST name its repo
# explicitly. A bare gh call resolves the repo from the process CWD's git
# remote — which only matched REPO_DIR by accident of the systemd unit's
# WorkingDirectory=@REPO_DIR@. Any other invocation (an eval harness spawning
# the runner from elsewhere with FARM_REPO_DIR set, an operator running a
# script from another checkout) silently targeted the WRONG repo: gh pr view
# returned empty and best-effort paths skipped without a trace (the 2026-07-10
# missing-PR-usage-section defect). farm_repo_slug derives owner/repo from
# REPO_DIR's origin remote (SSH, HTTPS and scp-like forms); GH_REPO_ARGS is
# the ready-made `-R owner/repo` argument vector — EMPTY when the repo has no
# parsable origin, so those calls degrade to the old cwd behavior instead of
# crashing (callers that cannot tolerate a wrong-repo write, like
# pr_upsert_usage, check FARM_REPO_SLUG themselves and skip LOUDLY).
farm_repo_slug() { # → echoes owner/repo, or nothing (no/unparsable origin)
  local url path
  url="$(git -C "$REPO_DIR" config --get remote.origin.url 2>/dev/null || true)"
  [[ -z "$url" ]] && return 0
  url="${url%/}"; url="${url%.git}"
  case "$url" in
    *://*) path="${url#*://}"; path="${path#*@}"; path="${path#*/}" ;;   # scheme://[user@]host/owner/repo
    *@*:*) path="${url#*:}" ;;                                           # git@host:owner/repo
    *)     path="$url" ;;
  esac
  [[ "$path" == */* ]] || return 0
  printf '%s/%s\n' "$(basename "$(dirname "$path")")" "$(basename "$path")"
}
FARM_REPO_SLUG="$(farm_repo_slug)"
GH_REPO_ARGS=()
[[ -n "$FARM_REPO_SLUG" ]] && GH_REPO_ARGS=(-R "$FARM_REPO_SLUG")

# ----------------------------------------------------- readable log format --
# THE one formatter shared by both consumers of claude's stream-json logs:
#   * the live `farmctl tail` viewer, and
#   * the persisted human-readable companion log (`<run>.txt`) the runner
#     renders alongside the raw `<run>.log` (see farm-runner.sh).
# It distils the raw one-JSON-event-per-line stream into a clean activity
# timeline — "thought → did X → did Y → result" — and DROPS the noise:
#   * keeps assistant TEXT (the agent's narration), trimmed to a sane width,
#     skipping empty/whitespace-only blocks;
#   * each tool_use as a one-liner `→ Tool: <short arg>` (command / file_path /
#     pattern / url / description, first ~140 chars, newlines flattened) — never
#     full file bodies or full command text;
#   * the final `result` event as a marked one-liner with subtype/turns/seconds;
#   * DROPS tool_result bodies, system/init, hook_*, rate_limit_event, usage/cost
#     blocks, and thinking deltas entirely (only `assistant`/`result` survive);
#   * passes plain non-JSON lines (claude startup warnings, old text-mode logs)
#     through unchanged via the `try fromjson` guard.
# Keep FARM_LOG_FMT a single-quoted literal on its own assignment so the test
# suite can sed-extract and exercise it verbatim (anchor: /^FARM_LOG_FMT='/).
# Fed via `jq -R` so each raw line arrives as a string for the fromjson guard.
# shellcheck disable=SC2016,SC2034  # jq program ($e etc. are jq vars); used by sourcing scripts
FARM_LOG_FMT='
(try fromjson catch null) as $e
| if $e == null then .
  elif ($e | type) != "object" then .
  elif $e.type == "assistant" then
      ( $e.message.content // [] )
      | map(
          if .type == "text" then
            ( .text | gsub("[ \t]+$"; "") )
            | select(test("\\S"))
            | if (length > 2000) then .[0:2000] + " …" else . end
          elif .type == "tool_use" then
            "→ " + (.name // "tool") + ": " + (
              ( .input.command // .input.file_path // .input.path
                // .input.pattern // .input.url // .input.description
                // (.input | tojson) )
              | gsub("\n"; " ") | .[0:140]
            )
          else empty end
        )
      | .[]
  elif $e.type == "result" then
      "════════ RESULT (" + ($e.subtype // "?")
      + ", " + (($e.num_turns // 0) | tostring) + " turns, "
      + (((($e.duration_ms // 0) / 100 | floor) / 10) | tostring) + "s) ════════"
      + "\n" + ($e.result // "")
  else empty end
'

# ------------------------------------------------------------ limit gate ----
# One shared gate file: when any worker hits the subscription limit, all
# workers sleep until the reset. Content = unix epoch to wake at.
GATE_FILE="$STATE_DIR/limit-until"
PAUSE_FILE="$STATE_DIR/paused"
# One-note-per-outage-window marker: an infra outage (transient API OR a git
# fetch failure) is farm-wide, so every worker hitting it must not each spam the
# same ticket. Set when we note an outage; cleared when the gate window expires
# (below) and on any success (note_success) — so exactly one note per window.
INFRA_NOTE_MARKER="$STATE_DIR/infra-outage-noted"

wait_if_gated() {
  while true; do
    if [[ -f "$PAUSE_FILE" ]]; then
      log "farm paused ($PAUSE_FILE present) — sleeping 60s"; sleep 60; continue
    fi
    if [[ -f "$GATE_FILE" ]]; then
      local until now
      until="$(_gate_until)"
      now="$(date +%s)"
      if [[ -n "$until" ]] && (( now < until )); then
        log "usage limit gate active — sleeping until $(farm_epoch_to_iso "$until")"
        sleep $(( until - now > 300 ? 300 : until - now ))
        continue
      fi
      rm -f "$GATE_FILE" "$INFRA_NOTE_MARKER"
    fi
    return 0
  done
}

# Non-blocking variant for oneshot services (scout): 0 = gated/paused.
gated_now() {
  [[ -f "$PAUSE_FILE" ]] && return 0
  local until
  until="$(_gate_until)"
  [[ -n "$until" ]] && (( $(date +%s) < until )) && return 0
  return 1
}

# Gate-file epoch, validated. State files are writable by agent sessions, and
# bash arithmetic on raw content like `HOME[$(cmd)]` runs cmd in this process,
# outside the guard hook. Only ^[0-9]+$ passes; anything else means "not gated":
# the file is removed and one line logged. Echoes nothing when there is no gate.
_gate_until() {
  local v
  [[ -f "$GATE_FILE" ]] || return 0
  v="$(cat "$GATE_FILE" 2>/dev/null || true)"
  if [[ "$v" =~ ^[0-9]+$ ]]; then echo "$v"; return 0; fi
  rm -f "$GATE_FILE"
  log "invalid limit-gate content in $GATE_FILE — removed (not gated)"
}

# Best-effort parse of "You've hit your session|weekly|Opus limit · resets X".
# Falls back to now + LIMIT_FALLBACK_SECONDS. Adds 120s of safety margin.
set_limit_gate_from_output() {
  local out="$1" reset epoch="" t day
  reset="$(grep -oE "resets [A-Za-z0-9: ]+" <<<"$out" | head -1 | sed 's/^resets //; s/[[:space:]]*$//')" || true
  if [[ "$reset" =~ ^([0-9]{1,2}(:[0-9]{2})?)(am|pm)$ ]]; then
    t="${BASH_REMATCH[1]}${BASH_REMATCH[3]}"
    t="$(_normalize_ampm_time "$t")"  # "9am"/"10:30pm" -> 24h "HH:MM" (see _normalize_ampm_time)
    epoch="$(farm_when_epoch "today $t" 2>/dev/null || true)"
    [[ -n "$epoch" && "$epoch" -le "$(date +%s)" ]] && epoch="$(farm_when_epoch "tomorrow $t")"
  elif [[ "$reset" =~ ^(Mon|Tue|Wed|Thu|Fri|Sat|Sun) ]]; then
    day="${BASH_REMATCH[1]}"
    epoch="$(farm_when_epoch "next $day 00:00" 2>/dev/null || true)"
  fi
  [[ -z "$epoch" ]] && epoch=$(( $(date +%s) + LIMIT_FALLBACK_SECONDS ))
  echo $(( epoch + 120 )) > "$GATE_FILE"
  log "usage limit detected — gate set until $(farm_epoch_to_iso "$(cat "$GATE_FILE")")"
}

# Last <bytes> of a run log, COMPLETE lines only. When the log is longer than
# the tail, the cut usually lands inside one long JSON line (a whole-file
# tool_result) that no longer starts with {"type":"user", so it would be
# classified as plain text. Read one extra byte and drop through the first
# newline: if that byte is the newline, only it is dropped. Portable (wc/tail/sed).
run_log_tail() { # file bytes
  local size
  size="$(wc -c 2>/dev/null < "$1" || echo 0)"; size="${size//[[:space:]]/}"
  if [[ "$size" =~ ^[0-9]+$ ]] && (( size > $2 )); then
    local cut
    cut="$(tail -c "$(( $2 + 1 ))" "$1" | sed 1d)"
    # One line longer than the tail: trimming leaves nothing — keep the raw tail.
    if [[ -n "$cut" ]]; then printf '%s\n' "$cut"; else tail -c "$2" "$1"; fi
  else
    cat "$1" 2>/dev/null || true
  fi
}

# The session's own reported outcome: the FINAL stream-json result event line
# (empty if the stream died before emitting one).
final_result_event() { grep '"type":"result"' <<<"$1" | tail -1 || true; }

LIMIT_PHRASE_RE="hit your (session|weekly|Opus|[A-Za-z]+) limit"

# jq missing/failing degrades limit detection to the phrase fallback; say so
# once per process instead of failing silently.
_farm_jq_warn() {
  [[ -n "${_FARM_JQ_WARNED:-}" ]] && return 0
  _FARM_JQ_WARNED=1
  log "limit detection: jq unavailable or failed — using the phrase fallback only"
}

# Reset value of a TERMINAL top-level `rate_limit_event` with status "rejected"
# (the documented "limit was hit" signal; resetsAt, or SDK-style resets_at).
# Terminal = after the last such line no top-level `assistant` or `user` event
# follows (system/result lines may): if work continued, the limit did not end
# the run (e.g. overage carried on) and it is not evidence. Each log line is
# parsed as JSON, so the same text nested inside another event's string never
# matches. Echoes "rejected[ <value>]", or nothing; rc 2 = jq failed.
rate_limit_rejected() {
  local r
  r="$(jq -Rnr '[inputs | (fromjson? // null) | select(type=="object")] as $e
    | ([$e | to_entries[] | select(.value.type=="rate_limit_event"
          and ((.value.rate_limit_info? // {}) | type)=="object"
          and .value.rate_limit_info.status=="rejected") | .key] | last) as $i
    | if $i == null then empty
      elif ($e[$i+1:] | any(.type=="assistant" or .type=="user")) then empty
      else "rejected \($e[$i].rate_limit_info.resetsAt // $e[$i].rate_limit_info.resets_at // "")" end' \
    <<<"$1" 2>/dev/null)" || return 2
  [[ -n "$r" ]] && sed 's/ $//' <<<"$r"
  return 0
}

# Log tail minus "type":"user" stream events (tool results = text the session
# merely read). Non-JSON lines and every other event type pass through. rc 2 =
# jq failed (caller falls back to the unfiltered tail).
_limit_tail_unread() {
  jq -Rr '. as $l | (try (fromjson | if type=="object" and .type=="user" then empty else $l end) catch $l)' \
    <<<"$1" 2>/dev/null || return 2
}

# 0 iff the run ended on a usage limit; sets LIMIT_SOURCE to the evidence used
# (a global, not an echo, so the once-per-process jq warning survives). The real
# stream-json shape of a limit hit is undocumented. Precedence:
#  1. the final result event's own `result` text has the phrase → hit
#     ("phrase-result"). Known rare false positive: a clean run whose final
#     summary quotes the phrase.
#  2. a clean (is_error:false) final result → NOT a hit, even after a rejected
#     rate_limit_event (the CLI may report one window rejected and carry on).
#  3. a TERMINAL top-level rejected rate_limit_event (rate_limit_rejected) → hit
#     ("event").
#  4. the old tail phrase match, ignoring "type":"user" events → hit ("phrase").
output_hit_limit() {
  local out="$1" ev txt rl
  LIMIT_SOURCE=""
  ev="$(final_result_event "$out")"
  if [[ -n "$ev" ]]; then
    txt="$(jq -r '.result? // empty | tostring' <<<"$ev" 2>/dev/null)" || { _farm_jq_warn; txt="$ev"; }
    if grep -qE "$LIMIT_PHRASE_RE" <<<"$txt"; then LIMIT_SOURCE=phrase-result; return 0; fi
    grep -q '"is_error":false' <<<"$ev" && return 1
  fi
  if rl="$(rate_limit_rejected "$out")"; then
    if [[ -n "$rl" ]]; then LIMIT_SOURCE=event; return 0; fi
  else
    _farm_jq_warn
  fi
  if txt="$(_limit_tail_unread "$out")"; then :; else _farm_jq_warn; txt="$out"; fi
  grep -qE "$LIMIT_PHRASE_RE" <<<"$txt" || return 1
  LIMIT_SOURCE=phrase
}

# Evidence source for the per-task cap: "event" | "phrase-result" | "phrase"
# (the cap counts only the phrase sources). A terminal rejected rate_limit_event
# makes it "event" whatever detection rule matched first: a genuine limit must
# never count toward escalation.
limit_detect_source() {
  output_hit_limit "$1" >/dev/null 2>&1 || true
  if [[ -n "$(rate_limit_rejected "$1" 2>/dev/null || true)" ]]; then echo event; return 0; fi
  echo "${LIMIT_SOURCE:-phrase}"
}

# Pure: normalise a rejected-event reset value against now. Values >= 10^12 are
# milliseconds. Echoes the epoch (seconds) iff now < e <= now + 8 days; rc 1 else.
_limit_event_epoch() { # value now
  local e="$1" now="$2"
  [[ "$e" =~ ^[0-9]+$ ]] || return 1
  (( 10#$e >= 1000000000000 )) && e=$(( 10#$e / 1000 ))
  (( 10#$e > now && 10#$e <= now + 8 * 86400 )) || return 1
  echo $(( 10#$e ))
}

# Set the limit gate for a run whose tail ($1) output_hit_limit flagged. Reset
# time preference: a usable rejected rate_limit_event epoch, else the final
# result line's "resets …" phrase, else the old tail parse
# (set_limit_gate_from_output keeps the fallback + 120s margin). Logs the run
# log ($2) so a real limit-hit sample can be collected as a test fixture.
set_limit_gate_from_run() {
  local out="$1" rl ev e=""
  rl="$(rate_limit_rejected "$out" || true)"
  ev="$(final_result_event "$out")"
  if [[ -n "$rl" ]]; then
    e="$(_limit_event_epoch "${rl#rejected }" "$(date +%s)" 2>/dev/null)" || e=""
    [[ -z "$e" ]] && log "rejected rate_limit_event has an unusable reset value (${rl#rejected }) — using the phrase/fallback reset"
  fi
  if [[ -n "$e" ]]; then
    echo $(( e + 120 )) > "$GATE_FILE"
    log "usage limit detected (rate_limit_event) — gate set until $(farm_epoch_to_iso "$(( e + 120 ))")"
  elif grep -q 'resets ' <<<"$ev"; then
    set_limit_gate_from_output "$ev"
  else
    set_limit_gate_from_output "$out"
  fi
  log "usage limit gate triggered by run log: $2"
}

# ------------------------------------------------ transient infra gate ------
# Generalises the usage-limit gate above to the whole TRANSIENT model/API/infra
# failure class (the 2026-06-13 model-404 outage: `claude-fable-5` vanished,
# every session died at turn 1 with api_error_status:404, and handle_failure
# burned farm-retry strikes → escalated GOOD tasks #3/#7/#9 to escalated).
# The provider can ALSO be non-responsive or return 5xx, not just 404 — this
# helper treats the whole class identically so none of it poisons the board.
INFRA_BACKOFF_SECONDS="${INFRA_BACKOFF_SECONDS:-180}"

# $1=out (tail of the run log incl. the stream-json result event) $2=rc
# (claude's exit code) → 0 iff the failure is a transient model/API/infra error
# (NOT a real task failure). Classify CONSERVATIVELY: only clear infra signals,
# never mask a genuine task failure or the intentional watchdog kill.
#
# PRECISION INVARIANT — classification is anchored to the stream-json RESULT
# EVENT, never the whole 200KB `$OUT`. The old version greped the infra text
# patterns as substrings over the ENTIRE log and ran them BEFORE the rc check,
# which (a) misclassified a CLEANLY-completed agent (is_error:false) that merely
# DISCUSSED an HTTP 500 / "Service Unavailable" / timeout / ECONNREFUSED in code
# or test output it authored — masking a real incomplete task as transient — and
# (b) left a watchdog-killed session (rc=143) whose partial log happened to
# contain infra prose misclassified transient. Scoping every text/status match
# to the result-event LINE, and excluding is_error:false and rc=143 UP FRONT,
# closes both. When in doubt this falls through to `return 1` (handle_failure):
# a real failure is never silently masked.
output_transient_infra_error() {
  local out="$1" rc="${2:-0}" result_event

  # (1) Watchdog/lease TERM kill (rc 143) is INTENTIONAL — never infra. Excluded
  # on ALL paths, up front, before any text match (closes the rc=143 gap: a
  # killed session's partial log can carry infra prose).
  if [[ "$rc" -eq 143 ]]; then return 1; fi

  # (2) Anchor to the FINAL result event only — not the agent's prose. A normal
  # session always emits exactly one `"type":"result"` event; classification
  # signals are only trustworthy when they live ON that line.
  result_event="$(grep '"type":"result"' <<<"$out" | tail -1)"

  if [[ -n "$result_event" ]]; then
    # (2a) Clean completion is NEVER infra. An is_error:false result means the
    # session finished; if it didn't reach the expected board state that is a
    # REAL task failure for handle_failure, not a transient error. This kills
    # the dominant false positive (clean agent discussing infra strings).
    if grep -q '"is_error":false' <<<"$result_event"; then return 1; fi

    # (2b) Anchored API status — matched on the result-event line ONLY: the
    # literal 2026-06-13 404, the 5xx family, and Anthropic's 529 overload.
    if grep -qE '"api_error_status":(404|500|502|503|504|529)' <<<"$result_event"; then return 0; fi

    # (2c) Transient TEXT signals — matched on the result-event line ONLY (NOT
    # all of $OUT), so an agent that merely authored these strings in code/test
    # output cannot trip the classifier. Covers missing-model phrasings, 5xx
    # prose, and transport/network failures.
    if grep -qiE 'overloaded|issue with the selected model|model_not_found|do(es)? not have access|internal server error|service unavailable|bad gateway|gateway time-?out|request timed out|ETIMEDOUT|ECONNRESET|ECONNREFUSED|ENOTFOUND|socket hang up|connection error' <<<"$result_event"; then
      return 0
    fi

    # A result event exists with no infra signal on it → a genuine non-infra
    # error (real task failure) → handle_failure.
    return 1
  fi

  # (3) No result event at all AND rc≠0 (rc=143 already excluded above) → the
  # stream died before producing a result, which only happens when the
  # connection/process collapsed mid-flight → transport died → transient.
  if [[ "$rc" -ne 0 ]]; then return 0; fi

  # (4) Everything else (no result event, clean exit) is a REAL outcome →
  # handle_failure.
  return 1
}

# Set GATE_FILE to now + INFRA_BACKOFF_SECONDS so wait_if_gated makes ALL
# workers sleep briefly — prevents hammering a down API and prevents requeue
# churn while the provider is unavailable. Reuses the SAME GATE_FILE mechanism
# as the usage-limit gate (wait_if_gated already caps each sleep at 300s/loop).
set_infra_backoff_gate() {
  echo $(( $(date +%s) + INFRA_BACKOFF_SECONDS )) > "$GATE_FILE"
  log "transient model/API error — infra backoff gate set until $(farm_epoch_to_iso "$(cat "$GATE_FILE")")"
}

# --------------------------------------------------------------- kanban -----
task_status()  { kb show "$1" --json | jq -r '.status'; }
task_has_tag() { kb show "$1" --json | jq -e --arg t "$2" '(.tags // []) | index($t)' >/dev/null; }

# --------------------------------------------- complexity tiering -----------
# Conservative two-pipeline routing (see
# docs/superpowers/specs/2026-06-22-farm-complexity-tiering-design.md): a
# `tier:light` task runs a cheaper Sonnet implementer that skips its OWN
# pre-commit reviewer, and a cheaper QA (resolve_qa_model: QA_MODEL_LIGHT,
# default sonnet, at unchanged QA_EFFORT); Heavy/default QA stays Opus, and the
# HARD path floor forces Opus QA absolutely, so Two-Actor still holds and
# protected surfaces always get the top-tier reviewer.
# Resolution is deterministic (zero LLM). The safety floor is TWO-LEVEL: the HARD
# floor (a protected-PATH citation) is ABSOLUTE — it overrides a human
# tier:light/model:sonnet, the one line an override cannot cross (First Rule).
# The SOFT floor (a bare safety keyword in prose) forces Heavy only when no
# deliberate tier:light was set, so a doc/copy tweak that merely MENTIONS
# auth/payment is not force-Heavied. See
# docs/adr/2026-06-30-adr-farm-tier-floor-precision.md.

# SOFT-floor safety keywords: present in the body → force Heavy UNLESS a
# deliberate tier:light overrides (word-bounded so 'auth' does not trip
# 'author'). Committed here (not solely in farm.env) so this default survives
# a git-stash. This is a GENERIC baseline; projects extend it with their own
# safety-critical vocabulary (e.g. a domain-specific compliance term or a
# schema-risk keyword) by setting FARM_SAFETY_KEYWORDS_RE in their own
# <repo>/.agent-farm/farm.env — see defaults/farm.env for the pattern.
: "${FARM_SAFETY_KEYWORDS_RE:=\\b(auth|passkey|payment|billing|credential|token|secret|csrf|webhook)\\b}"

# Protected-path substrings AUTO-DERIVED from protected-paths.txt — single source
# of truth. Only PATH-like globs (containing '/' or an ALL-CAPS filename like
# CODEOWNERS); bare *word* globs (e.g. *auth*/*payment*, or a project-added
# *domain-term*) are skipped on purpose — word globs belong in the keyword
# list (FARM_SAFETY_KEYWORDS_RE) or a project's own merge-time file guard, not here.
_protected_path_substrings() {
  local pp line; pp="$(farm_resolve protected-paths.txt)"
  [[ -f "$pp" ]] || return 0
  while IFS= read -r line; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    if [[ "$line" == */* || "$line" =~ ^[A-Z]+$ ]]; then
      line="${line%/\*}"; line="${line#\*}"; line="${line%\*}"
      [[ -n "$line" ]] && printf '%s\n' "$line"
    fi
  done < "$pp"
}

# HARD floor — 0 (force Heavy, ABSOLUTE) iff the body cites a protected PATH
# (auto-derived from protected-paths.txt). The one signal a tier:/model: override
# can never cross (First Rule): a change that names a protected file IS protected
# work. Fail-CLOSED — an unreadable/empty body forces Heavy (a false-Heavy only
# costs tokens; a false-Light is the risk).
task_forces_heavy_hard() { # id -> 0 = force heavy (absolute), 1 = not
  local id="$1" body="" sub
  body="$(kb show "$id" 2>/dev/null)" || return 0
  [[ -z "$body" ]] && return 0
  while IFS= read -r sub; do
    [[ -z "$sub" ]] && continue
    grep -qF "$sub" <<<"$body" && return 0
  done < <(_protected_path_substrings)
  return 1
}

# SOFT floor — 0 iff the body contains a word-bounded safety KEYWORD. Forces
# Heavy for UNTAGGED tasks, but a deliberate tier:light (Opus-high scout or
# human) overrides it — so a doc/copy tweak that merely MENTIONS auth/payment is
# not force-Heavied. The backstop for a real safety-CODE task mis-tagged light is
# the implementer's fail-up gate (implementer.md) + QA at Opus-high. Returns 1
# (no keyword) on an unreadable body — the HARD floor already fails-closed, so
# this is only an additional soft signal.
task_has_safety_keyword() { # id -> 0 = keyword present, 1 = none
  local id="$1" body=""
  body="$(kb show "$id" 2>/dev/null)" || return 1
  [[ -z "$body" ]] && return 1
  grep -qiE "$FARM_SAFETY_KEYWORDS_RE" <<<"$body"
}

# echoes light|heavy. Precedence: HARD path floor (absolute) > explicit tier: tag
# > SOFT keyword floor > default heavy. A deliberate tier:light overrides the
# SOFT keyword floor but NEVER the HARD path floor.
resolve_task_tier() { # id -> light|heavy
  local id="$1"
  task_forces_heavy_hard "$id" && { echo heavy; return 0; }
  task_has_tag "$id" "tier:heavy" 2>/dev/null && { echo heavy; return 0; }
  task_has_tag "$id" "tier:light" 2>/dev/null && { echo light; return 0; }
  task_has_safety_keyword "$id" && { echo heavy; return 0; }
  echo heavy
}

# echoes the implementer model. Precedence: HARD path floor (opus, ABSOLUTE) >
# explicit model: override (validated sonnet|opus|haiku) > tier-derived
# (light=sonnet — which already encodes the SOFT keyword floor for untagged tasks
# via resolve_task_tier) > opus.
resolve_impl_model() { # id -> sonnet|opus|haiku
  local id="$1" m
  # HARD floor → the top model, ABSOLUTE: hardcoded opus, not $IMPL_MODEL, so a
  # global IMPL_MODEL override can never lower a path-protected task below Opus.
  task_forces_heavy_hard "$id" && { echo opus; return 0; }
  for m in sonnet opus haiku; do
    task_has_tag "$id" "model:$m" 2>/dev/null && { echo "$m"; return 0; }
  done
  if [[ "$(resolve_task_tier "$id")" == light ]]; then echo "${IMPL_MODEL_LIGHT:-sonnet}"; else echo "${IMPL_MODEL:-opus}"; fi
}

# echoes the implementer reasoning effort, resolved per task: light at
# IMPL_EFFORT_LIGHT, heavy at IMPL_EFFORT (both default `medium`; the light knob
# can be tuned DOWN independently of heavy). QA/scout effort is never tiered down.
# See docs/adr/2026-06-30-adr-farm-effort-by-complexity.md.
resolve_impl_effort() { # id -> low|medium|high|...
  if [[ "$(resolve_task_tier "$1")" == light ]]; then echo "${IMPL_EFFORT_LIGHT:-medium}"; else echo "${IMPL_EFFORT:-medium}"; fi
}

# echoes the QA model, resolved per task — mirrors resolve_impl_model's shape
# minus the model: tag override (a model: tag steers the IMPLEMENTER; QA keeps
# its own independent knobs so a mis-tag can never drag the reviewer down with
# the author). Precedence: HARD path floor (opus, ABSOLUTE — hardcoded, not
# $QA_MODEL, so no global override can lower a path-protected task's reviewer
# below Opus) > tier-derived (light=QA_MODEL_LIGHT, which already encodes the
# SOFT keyword floor for untagged tasks via resolve_task_tier) > $QA_MODEL.
# QA EFFORT is never tiered down — only the model tiers.
resolve_qa_model() { # id -> sonnet|opus|...
  local id="$1"
  task_forces_heavy_hard "$id" && { echo opus; return 0; }
  if [[ "$(resolve_task_tier "$id")" == light ]]; then echo "${QA_MODEL_LIGHT:-sonnet}"; else echo "${QA_MODEL:-opus}"; fi
}

# Pure decision for the runner's deterministic pre-QA gate (no side effects, no
# network — same factoring as _ci_rescue_decide): given the state of a review
# PR's REQUIRED checks, decide whether spawning an (expensive, Opus-by-default)
# QA session is worth it, BEFORE paying for it. A red build needs the
# implementer, not a reviewer; a still-running build needs patience, not tokens.
#
#   $1 failing_csv   — comma-separated names of the PR's failing REQUIRED checks
#                      (gh pr checks --required, buckets fail/cancel).
#   $2 pending_count — number of REQUIRED checks still running/queued.
#
# Output (one word on stdout):
#   requeue — at least one required check already failed → do NOT spawn QA;
#             hand the task back through handle_failure (bounded two-strike:
#             first strike requeues to the implementer with the failing names
#             in a note, second escalates to the escalated column).
#   defer   — nothing failed but checks are still pending → leave the task for
#             the next poll (no claim, no session, no strike).
#   spawn   — required checks are green (or none reported — fail toward QA:
#             an API hiccup or a checkless repo must never starve review; the
#             QA session verifies CI itself as part of its checklist).
# Always returns 0 — the caller branches on the printed word.
_qa_gate_decide() { # failing_csv, pending_count
  local failing_csv="$1" pending_count="${2:-0}"
  if [[ -n "$failing_csv" ]]; then echo requeue; return 0; fi
  if [[ "$pending_count" =~ ^[0-9]+$ ]] && (( pending_count > 0 )); then echo defer; return 0; fi
  echo spawn
  return 0
}

# Side-effecting wrapper around _qa_gate_decide: fetches the PR's required-check
# state, acts on the verdict, echoes what it did (the runner branches on the
# word): spawn | requeued | escalated | deferred.
#
# STRIKE MEMORY — the `qa-gate-strike` tag. handle_failure's two-strike breaker
# counts via `farm-retry`, but the implementer SUCCESS path (reached `review` +
# clean exit — NOT green checks) unconditionally clears `farm-retry` and resets
# the global failstreak (note_success), so a gate that leaned on farm-retry
# alone would loop UNBOUNDED: red CI → strike 1 → implementer pushes, tag
# cleared, streak reset → still red → strike 1 again, forever (found in review
# of the original gate). `qa-gate-strike` is the gate's OWN marker: only the
# gate writes it, the implementer success path never touches it, and it is
# cleared ONLY when the gate OBSERVES required checks green (non-empty check
# data, nothing failing/pending) — or by QA's own success path. So:
#   * red + no marker  → first strike: set marker, then the normal
#     handle_failure requeue to `ready` (its farm-retry escalation still
#     applies if a real run-failure already struck this ticket);
#   * red + marker     → SECOND consecutive gate strike: the implementer had
#     its retry and CI is still red → escalate to `escalated` directly
#     (note + block name the failing checks), never a third silent cycle;
#   * pending          → release + defer (no strike);
#   * green (observed) → clear the marker, spawn;
#   * no data (gh hiccup / checkless repo) → spawn WITHOUT clearing the marker
#     (not an observation of green — never launder a strike on an API blip).
# Every kb/gh call is best-effort under `set -e`; always returns 0.
qa_gate() { # task_id, pr → echoes spawn|requeued|escalated|deferred
  local id="$1" pr="$2" gate_json failing pending decision
  gate_json="$(farm_timeout 30 gh pr checks "$pr" ${GH_REPO_ARGS[@]+"${GH_REPO_ARGS[@]}"} --required --json bucket,name 2>/dev/null || true)"
  failing="$(jq -r '[.[]? | select(.bucket=="fail" or .bucket=="cancel") | .name] | join(",")' <<<"$gate_json" 2>/dev/null || true)"
  pending="$(jq -r '[.[]? | select(.bucket=="pending")] | length' <<<"$gate_json" 2>/dev/null || echo 0)"
  decision="$(_qa_gate_decide "$failing" "$pending")"
  case "$decision" in
    requeue)
      if task_has_tag "$id" "qa-gate-strike" 2>/dev/null; then
        note_failure_streak
        append_note "$id" "FARM: QA gate SECOND strike — required check(s) still failing on PR #${pr} [${failing}] after an implementer retry; escalated."
        # The marker's memory has served its purpose the moment escalation
        # fires: CLEAR it here, or a ticket a human later fixes and returns to
        # `review` inherits the stale strike and its first new red check
        # insta-escalates as a false "second" strike — denying the fresh
        # attempt the implementer retry every first strike is entitled to.
        kb edit "$id" --remove-tag qa-gate-strike --claim "${AGENT_NAME:-}" >/dev/null 2>&1 || true
        kb edit "$id" --release >/dev/null 2>&1 || true
        kb move "$id" escalated >/dev/null 2>&1 || true
        kb edit "$id" --block "QA gate: two consecutive red-CI strikes on PR #${pr} [${failing}]" >/dev/null 2>&1 || true
        log "task #$id QA gate second strike (PR #$pr red on [$failing]) — escalated"
        echo escalated
      else
        kb edit "$id" --add-tag qa-gate-strike --claim "${AGENT_NAME:-}" >/dev/null 2>&1 || true
        log "task #$id QA gate: PR #$pr red on required check(s) [$failing] — not spawning QA, requeuing to implementer (first gate strike)"
        handle_failure "$id" ready "QA gate: required check(s) failing on PR #${pr} [${failing}] — fix the build before review"
        echo requeued
      fi
      ;;
    defer)
      log "task #$id QA gate: PR #$pr has $pending required check(s) still pending — deferring to next poll"
      kb edit "$id" --release >/dev/null 2>&1 || true
      echo deferred
      ;;
    *)
      # Clear the strike only on OBSERVED green (non-empty check data) — a gh
      # hiccup/empty response spawns QA but must not launder the marker.
      if [[ -n "$gate_json" && "$gate_json" != "[]" ]] && task_has_tag "$id" "qa-gate-strike" 2>/dev/null; then
        kb edit "$id" --remove-tag qa-gate-strike --claim "${AGENT_NAME:-}" >/dev/null 2>&1 || true
      fi
      echo spawn
      ;;
  esac
  return 0
}

# The task↔PR link is a structured `pr-<N>` tag (set by the implementer at
# PR-open, defensively re-asserted by QA on the protected-surface escalation).
# This reads the task's tags and echoes the bare PR NUMBER of the first
# `pr-<N>` tag, empty if none. One-PR-per-task is the current invariant (first
# match wins); multi-PR is a deferred future step. Best-effort: a failed board
# read or a task with no pr tag yields the empty string, never a crash — it runs
# on the janitor's best-effort reconciliation path under `set -e`.
task_pr_from_tags() { # id  → echoes PR number, or empty
  kb show "$1" --json 2>/dev/null \
    | jq -r 'first((.tags // [])[] | select(test("^pr-[0-9]+$")) | ltrimstr("pr-")) // empty' \
    2>/dev/null || true
}

# ------------------------------------------------- token metrics -------------
# Free, accurate per-session token accounting. `claude -p --output-format
# stream-json` emits a final RESULT EVENT carrying the session's CUMULATIVE usage
# (input/output/cache tokens) + total_cost_usd + num_turns/duration_ms; the runner
# already captures the raw stream to $RUN_LOG. These helpers extract it and let
# the runner (1) append a structured record to metrics/usage.jsonl (queried via
# `farmctl metrics`) and (2) surface implementer/QA usage in the PR body. The
# agent itself cannot self-report accurately — its final usage only exists once
# the session ends, in the result event. All best-effort; never crash the caller.
# See docs/adr/2026-06-28-adr-farm-token-metrics.md.

# Extract the result-event usage from the captured stream tail. Echoes a compact
# JSON object; `{}` when there is no result event (hard-killed / transport died).
#
# Token counts come from `.modelUsage` (summed across ALL models), NOT the
# top-level `.usage`: `.usage` covers only the MAIN session loop, silently
# dropping every Task-subagent's API usage — and FARM.md mandates heavy subagent
# delegation, so the old `.usage.*` extraction badly understated in/out/cache
# counts next to an accurate cost (`.total_cost_usd` aggregates everything).
# `.modelUsage` is keyed by model id with camelCase fields (inputTokens, ...);
# snake_case fallbacks per entry guard against a CLI casing change. When
# `.modelUsage` is absent/empty (older CLI versions), fall back to the old
# `.usage.*` read. cost/turns/duration are unchanged (already session-total).
session_usage_json() { # out -> JSON
  local out="$1" line
  # `|| true`: no-match grep + pipefail would otherwise fail this assignment and
  # `set -e`-abort the function before the `echo {}` (a hard-killed session has no
  # result event) — which would then crash the runner's USAGE_JSON=$(...) call.
  line="$(grep '"type":"result"' <<<"$out" 2>/dev/null | tail -1 || true)"
  [[ -z "$line" ]] && { echo '{}'; return 0; }
  jq -c '
    [.modelUsage? // {} | .[]] as $mu
    | ($mu | length > 0) as $has_mu
    | {
    in:             (if $has_mu then ([$mu[] | (.inputTokens              // .input_tokens               // 0)] | add) else (.usage.input_tokens               // 0) end),
    out:            (if $has_mu then ([$mu[] | (.outputTokens             // .output_tokens              // 0)] | add) else (.usage.output_tokens              // 0) end),
    cache_read:     (if $has_mu then ([$mu[] | (.cacheReadInputTokens     // .cache_read_input_tokens     // 0)] | add) else (.usage.cache_read_input_tokens     // 0) end),
    cache_creation: (if $has_mu then ([$mu[] | (.cacheCreationInputTokens // .cache_creation_input_tokens // 0)] | add) else (.usage.cache_creation_input_tokens // 0) end),
    cost_usd:       (.total_cost_usd // 0),
    turns:          (.num_turns  // 0),
    dur_ms:         (.duration_ms // 0)
  }' <<<"$line" 2>/dev/null || echo '{}'
}

# Append one per-session record (run metadata + usage) to metrics/usage.jsonl.
record_task_metrics() { # id role model effort tier outcome usage_json
  local id="$1" role="$2" model="$3" effort="$4" tier="$5" outcome="$6" usage="${7:-}" dir="$STATE_DIR/metrics"
  [[ -z "$usage" ]] && usage='{}'
  mkdir -p "$dir" 2>/dev/null || true
  # Non-fatal, but no longer SILENT: a swallowed append (bad dir perms, full
  # disk, malformed usage json) used to leave `farmctl metrics` showing stale
  # data with zero signal. Emit one log line on failure so the operator can see
  # the gap. Still returns 0 — metrics loss must never abort a runner.
  if ! jq -cn --arg ts "$(farm_now_iso)" --arg id "$id" --arg role "$role" --arg model "$model" \
       --arg effort "$effort" --arg tier "$tier" --arg outcome "$outcome" --argjson u "$usage" \
       '{ts:$ts, task_id:$id, role:$role, model:$model, effort:$effort, tier:$tier, outcome:$outcome} + $u' \
       >> "$dir/usage.jsonl" 2>/dev/null; then
    log "metrics: failed to record usage for task #$id ($role) → $dir/usage.jsonl — 'farmctl metrics' may show stale data (check dir perms / disk / usage json)"
  fi
  return 0
}

# One-line Markdown usage summary for the PR body. Pure.
format_usage_line() { # role model effort tier usage_json -> markdown line
  local role="$1" model="$2" effort="$3" tier="$4" usage="${5:-}"
  [[ -z "$usage" ]] && usage='{}'
  jq -r --arg role "$role" --arg model "$model" --arg effort "$effort" --arg tier "$tier" '
    "- **" + $role + "** (" + $model + " · " + $effort + " · tier:" + $tier + "): "
    + "in "            + ((.in         // 0)|tostring)
    + " · out "        + ((.out        // 0)|tostring)
    + " · cache-read " + ((.cache_read // 0)|tostring)
    + " · $"           + ((.cost_usd   // 0)|tostring)
    + " · "            + ((.turns      // 0)|tostring) + " turns"
    + " · "            + (((.dur_ms    // 0)/1000)|floor|tostring) + "s"
  ' <<<"$usage" 2>/dev/null || echo "- **$role** (token usage unavailable)"
}

# Render the `**Total**` row for the PR usage section. Reads the section's
# per-session markdown lines (format_usage_line output) on stdin, sums
# in/out/cache-read/cost across them, echoes ONE markdown line (empty when no
# line parses). Pure (stdin → stdout, no board/network I/O) → directly
# unit-testable. Ignores any existing Total row and any non-matching line, so
# recomputing over a section that already carries a Total is idempotent. Turns/
# duration are per-session diagnostics, not meaningful sums — left out.
usage_total_line() { # stdin: section markdown lines -> total line (or empty)
  # LC_ALL=C: the cost field is a `.`-decimal number. Under a comma-decimal
  # locale (e.g. de_DE/pl_PL) awk reads "0.8000" as 0 AND prints "%.4f" with a
  # comma ("$0,0000"), corrupting the Total row. Force the C locale so parsing
  # and formatting stay dot-decimal on any operator's machine.
  LC_ALL=C awk '
    /^- \*\*Total\*\*/ { next }
    match($0, /in [0-9]+ · out [0-9]+ · cache-read [0-9]+ · \$[0-9.]+/) {
      s = substr($0, RSTART, RLENGTH)
      split(s, p, / · /)
      sub(/^in /, "", p[1]);         i += p[1]
      sub(/^out /, "", p[2]);        o += p[2]
      sub(/^cache-read /, "", p[3]); c += p[3]
      sub(/^\$/, "", p[4]);          d += p[4]
      n++
    }
    END {
      if (n > 0)
        printf "- **Total** (%d session%s): in %d · out %d · cache-read %d · $%.4f\n", \
          n, (n == 1 ? "" : "s"), i, o, c, d
    }
  ' 2>/dev/null || true
}

# Upsert a "Farm token usage" section line into a PR body (best-effort, gh). The
# implementer and QA each append their own line; they run at different times so
# there is no concurrent edit. An unreadable body is left untouched (never
# clobbered). A `**Total**` row (usage_total_line) is recomputed from all
# per-session lines on every upsert and kept as the section's last line, so the
# operator reads the per-ticket sum without adding token counts by hand.
#
# The write MUST use the REST endpoint (`gh api ... PATCH`), NOT `gh pr edit`:
# `gh pr edit` fetches `repository.pullRequest.projectCards`, which fails with a
# GraphQL error ("Projects (classic) is being deprecated") on any org/repo that
# still has Projects-classic — so `gh pr edit --body` exits non-zero and the
# usage section silently never lands (the whole feature was dead until 2026-07-09
# because of this). The REST PATCH touches only the body and sidesteps it. The
# repo is targeted EXPLICITLY via FARM_REPO_SLUG — the old `{owner}/{repo}`
# placeholder resolved from the process CWD, which silently PATCHed (or read
# nothing from) the wrong repo whenever the caller was not started inside
# REPO_DIR (see the farm_repo_slug rationale). A failure is logged (not
# swallowed silently) but never crashes the runner.
pr_upsert_usage() { # pr_number, markdown_line
  local pr="$1" line="$2" body marker="## 📊 Farm token usage (per session)"
  local pre section total
  [[ -z "$pr" ]] && return 0
  # A body WRITE against a cwd-resolved repo is a wrong-repo hazard — require
  # the explicit slug, and skip LOUDLY without it (a silent skip here is how
  # the missing-usage-section defect survived two review rounds).
  if [[ -z "$FARM_REPO_SLUG" ]]; then
    log "pr_upsert_usage: no parsable origin remote in $REPO_DIR — cannot target PR #$pr explicitly; skipping (token usage not surfaced)"
    return 0
  fi
  body="$(farm_timeout 30 gh pr view "$pr" -R "$FARM_REPO_SLUG" --json body -q '.body' 2>/dev/null || true)"
  if [[ -z "$body" ]]; then
    log "pr_upsert_usage: PR #$pr body unreadable (repo=$FARM_REPO_SLUG) — skipping (token usage not surfaced)"
    return 0
  fi
  if grep -qF "$marker" <<<"$body"; then
    # Split at the marker (fixed-string match — the marker carries regex-hostile
    # chars, so index(), not a regex). Everything after it is OURS: only this
    # function ever writes there, always at the end of the body.
    pre="$(awk -v m="$marker" 'index($0, m) == 1 {exit} {print}' <<<"$body")"
    section="$(awk -v m="$marker" 'f {print} index($0, m) == 1 {f=1}' <<<"$body")"
    # Drop the previous Total row (recomputed below), append the new session line.
    section="$(grep -v '^- \*\*Total\*\*' <<<"$section" || true)"
    section="$(printf '%s\n%s' "$section" "$line")"
  else
    pre="$body"$'\n'
    section="$line"
  fi
  total="$(usage_total_line <<<"$section")"
  body="$(printf '%s\n%s\n%s' "$pre" "$marker" "$section")"
  # A section whose lines all failed to parse (e.g. only the "usage unavailable"
  # fallback) yields no Total — append the row only when there is one.
  [[ -n "$total" ]] && body="$(printf '%s\n%s' "$body" "$total")"
  if ! farm_timeout 30 gh api "repos/${FARM_REPO_SLUG}/pulls/$pr" -X PATCH -f body="$body" >/dev/null 2>&1; then
    log "pr_upsert_usage: could not update PR #$pr body (gh api PATCH failed) — token usage not surfaced (best-effort)"
  fi
  return 0
}

# Does this PR's head branch belong to THIS task? The runner names every
# implementer branch `task/<id>-<slug>` (farm-runner.sh). This guards the
# PR-number race (a stale/mis-applied `pr-<N>` tag pointing at ANOTHER task's
# PR): the janitor cross-checks the PR's headRefName before shipping/archiving on
# its MERGED state, so it never acts on the wrong PR. Pure (no I/O) → directly
# unit-testable; the janitor is the thin side-effecting wrapper.
pr_head_matches_task() { # head_ref, id -> 0 if head_ref is task/<id>-*
  local head="$1" id="$2"
  [[ -n "$head" && -n "$id" && "$head" == "task/${id}-"* ]]
}

# 0 if the task is held by a LIVE runner: a non-empty claim whose `updated` is
# within grace_seconds (the lease guard bumps `updated` every refresh while a
# session is alive). Lets the janitor protect live `doing` work from being
# shipped/rescued out from under an active implementer. Best-effort reads; an
# unclaimed task or an unreadable board → 1 (not fresh, safe to act).
task_claim_is_fresh() { # id, grace_seconds -> 0 = fresh (live), 1 = stale/unclaimed
  local id="$1" grace="${2:-0}" row owner updated cutoff
  row="$(kb show "$id" --json 2>/dev/null || true)"      # ONE board read
  owner="$(jq -r '.claimed_by // ""' <<<"$row" 2>/dev/null || true)"
  [[ -z "$owner" ]] && return 1
  updated="$(jq -r '((.updated // "1970-01-01T00:00:00Z") | fromdateiso8601? // 0)' <<<"$row" 2>/dev/null || true)"
  [[ -z "$updated" ]] && updated=0
  cutoff=$(( $(date +%s) - grace ))
  (( updated >= cutoff ))
}

# Append a timestamped note. MUST be crash-proof: it runs on failure paths
# under `set -e`, so a board rejection here would otherwise kill the runner
# (the 2026-06-13 QA wedge). kanban-md rejects mutations on a task claimed by
# someone else UNLESS --claim names the holder (verified: a claimed task
# rejects `edit --append-body` with exit 1; passing `--claim <holder>`
# succeeds). append_note runs both while WE still hold the claim
# (handle_failure) and after the claim was released (the limit path in
# farm-runner.sh), so it passes --claim only when the task is currently claimed
# by us — passing --claim on an unclaimed task would silently RE-ACQUIRE it.
# Every failure degrades to a journal log line; it never returns non-zero.
append_note() { # id, note  (timestamped)
  local id="$1" note="$2" owner=""
  owner="$(kb show "$id" --json 2>/dev/null | jq -r '.claimed_by // ""')" || owner=""
  if [[ -n "$owner" && "$owner" == "${AGENT_NAME:-}" ]]; then
    kb edit "$id" --append-body "$note" -t --claim "$AGENT_NAME" >/dev/null 2>&1 \
      || log "append_note: board rejected note on task $id (claimed) — continuing"
  else
    kb edit "$id" --append-body "$note" -t >/dev/null 2>&1 \
      || log "append_note: board rejected note on task $id — continuing"
  fi
  return 0
}

# Move a task to a terminal column, releasing any (possibly FOREIGN) claim in the
# SAME successful operation. This is the janitor's reconcile/archive primitive.
#
# Why this exists (the 2026-06-15 #63 wedge): a MERGED-PR review task left claimed
# by a dead QA session (farm-qa-1) must be shipped+archived. The old reconcile did
# a two-step `edit --release` THEN bare `move`, each `|| true`-guarded. kanban-md
# REJECTS a bare `move` on a foreign-claimed task ("claimed by … add: --claim …",
# exit 1 — verified). When the prior `--release` did NOT actually clear the claim
# (silently swallowed by `|| true`; claim-enforcement is version-dependent), the
# bare move was rejected and ALSO swallowed → the task sat in `review` forever, so
# the archive pass never saw it in `shipped` and dependent #69 stayed blocked.
#
# The fix: ONE atomic, claim-aware move. `move --claim <holder>` is ACCEPTED on a
# foreign-claimed task (verified rc=0) and a bare `move` is accepted on an
# unclaimed one; we try the claim-qualified form first when an owner is present,
# fall back to the bare form, then best-effort release so the task does not linger
# claimed in its terminal column. Every call is `|| true`: a per-task board hiccup
# degrades to a log line and the loop continues with the NEXT task — a single
# failure never aborts the pass (runs under `set -e`). Returns 0 iff the task is
# observed in $dest afterward (so callers can log/branch), but NEVER non-zero in a
# way that aborts the caller (the status read itself is guarded). Args: id, dest.
move_release_to() { # id, dest_status  → 0 iff task ends up in dest (never aborts)
  local id="$1" dest="$2" owner="" now=""
  owner="$(kb show "$id" --json 2>/dev/null | jq -r '.claimed_by // ""' || true)"
  if [[ -n "$owner" ]]; then
    # Claim-qualified move (accepted on a foreign claim); claim travels with it,
    # so release afterward. If this form is unsupported/rejected, fall through to
    # the release-then-bare-move path below.
    kb move "$id" "$dest" --claim "$owner" >/dev/null 2>&1 || true
    kb edit "$id" --release >/dev/null 2>&1 || true
  fi
  # If still not in dest (no owner, or the claim-qualified move was rejected),
  # release any remaining claim and try a bare move.
  now="$(kb show "$id" --json 2>/dev/null | jq -r '.status // ""' || true)"
  if [[ "$now" != "$dest" ]]; then
    # Release only when a claim is still present (a bare --release on an unclaimed
    # task is a harmless no-op, but skipping it keeps the unclaimed path minimal).
    local cur=""
    cur="$(kb show "$id" --json 2>/dev/null | jq -r '.claimed_by // ""' || true)"
    [[ -n "$cur" ]] && { kb edit "$id" --release >/dev/null 2>&1 || true; }
    kb move "$id" "$dest" >/dev/null 2>&1 || true
    now="$(kb show "$id" --json 2>/dev/null | jq -r '.status // ""' || true)"
  fi
  [[ "$now" == "$dest" ]]
}

# Dedupe-union two CSV lists (used to merge required-check contexts from the
# legacy branch-protection API with GitHub rulesets — see pass_ci_rescue).
# Pure, order-preserving (first-seen wins), empty-safe. Always returns 0.
union_csv() { # csv1, csv2 -> deduped comma-joined csv (stdout)
  local a="$1" b="$2" seen="," out="" item
  local IFS=','
  for item in $a $b; do
    [[ -z "$item" ]] && continue
    case "$seen" in *",$item,"*) continue ;; esac
    seen="${seen}${item},"
    out="${out:+$out,}$item"
  done
  printf '%s' "$out"
  return 0
}

# Pure decision for the janitor's CI-rescue pass (no side effects, no network):
# given the four facts about a `review` PR, decide what to do. Factoring the
# decision out of the side-effecting shell makes it directly unit-testable (the
# shell stays a thin wrapper around it). Inputs are CSV/boolean strings so the
# whole thing is `set -e`-safe and trivial to drive from a test.
#
#   $1 required_csv    — comma-separated required-status-check contexts, ALREADY
#                        UNIONED by the caller across the legacy branch-protection
#                        API and the GitHub rulesets API (union_csv). Empty means
#                        NEITHER source reported any required context — this is
#                        indistinguishable from "repo genuinely has no required
#                        checks configured" from inside this pure function, so it
#                        is treated as a required-check-DETECTION FAILURE (see the
#                        fail-open branch below), not as "nothing to rescue". The
#                        caller (pass_ci_rescue) is responsible for logging a
#                        detection-failed warning when this happens.
#   $2 failing_csv     — comma-separated names of the PR's FAILED checks
#                        (conclusion FAILURE/TIMED_OUT/CANCELLED).
#   $3 behind_main     — "1" if the PR branch does NOT yet contain main HEAD
#                        (stale, refreshable), else "0".
#   $4 has_ci_stuck    — "1" if the task already carries the `ci-stuck` tag, else "0".
#
# Output (one word on stdout):
#   skip     — no failing check is (or can be confirmed) required → nothing to do.
#   refresh  — a required-or-unconfirmable-required check is red AND the branch
#              is behind main → a server-side update-branch may clear it once
#              main carries the fix.
#   escalate — as above but the branch already contains main HEAD (a genuine
#              failure refresh can't fix it) AND it is not yet escalated.
#   noop     — red + current + ALREADY escalated (carries ci-stuck) →
#              do nothing (idempotent; no repeat churn).
# Always returns 0 — the caller branches on the printed word.
_ci_rescue_decide() { # required_csv, failing_csv, behind_main, has_ci_stuck
  local required_csv="$1" failing_csv="$2" behind_main="${3:-0}" has_ci_stuck="${4:-0}"
  local red_required=0 r f
  if [[ -n "$required_csv" ]]; then
    # Normal path: intersection of (failing) ∩ (required).
    if [[ -n "$failing_csv" ]]; then
      local IFS=','
      for f in $failing_csv; do
        [[ -z "$f" ]] && continue
        for r in $required_csv; do
          [[ "$f" == "$r" ]] && { red_required=1; break 2; }
        done
      done
    fi
  else
    # BOTH required-check sources came back empty (detection failure — see the
    # doc comment above). Fail toward ACTION, not silence: any failing check on
    # this PR is treated as actionable, since we cannot rule out that it is
    # required. This closes the GitHub-rulesets rescue hole (the legacy
    # branches/.../protection/required_status_checks endpoint 404s/empties on a
    # rulesets-only repo, silently permaskipping every red PR forever).
    [[ -n "$failing_csv" ]] && red_required=1
  fi
  if [[ "$red_required" -eq 0 ]]; then echo skip; return 0; fi
  if [[ "$behind_main" == "1" ]]; then echo refresh; return 0; fi
  if [[ "$has_ci_stuck" == "1" ]]; then echo noop; return 0; fi
  echo escalate
  return 0
}

# --------------------------------------------------- post-QA CI watcher -----
# Closes the up-to-JANITOR-cadence (30min) gap between QA arming auto-merge
# and the janitor's own ci-rescue pass ever looking at the PR: the moment a QA
# session's is_armed_handoff is observed (farm-runner.sh), spawn ONE detached
# background watcher that blocks on `gh pr checks --watch` (bounded by
# CI_WATCH_TIMEOUT_SECONDS) and reacts to the FIRST failure immediately, instead
# of waiting for the next janitor tick. On green/merge it does nothing — the
# existing pass_reconcile pass ships the task the normal way. Runs fully
# detached (backgrounded subshell) so it NEVER blocks the runner's main loop —
# the runner claims its next task immediately.
#
# Idempotency (never double-escalate, never double-watch):
#   * a per-PR lock file ($STATE_DIR/ci-watch-<pr>.pid), checked via a LIVE pid
#     (not just file presence) so a stale lock left by a crashed watcher never
#     blocks a legitimate new one (e.g. after a runner restart re-observes the
#     same armed-handoff outcome).
#   * before escalating, re-checks the task does not already carry `ci-stuck` —
#     the janitor's own ci-rescue pass may have gotten there first; this watcher
#     must never re-append a duplicate escalation note.
# Every gh/kb call is best-effort; a hiccup here degrades to a missed early
# signal, never a crash (the caller — farm-runner.sh — is not in the subshell).
CI_WATCH_TIMEOUT_SECONDS="${CI_WATCH_TIMEOUT_SECONDS:-2700}"   # 45min
spawn_ci_watch() { # task_id, pr_number
  local id="$1" pr="$2" lock
  lock="$STATE_DIR/ci-watch-${pr}.pid"
  [[ -z "$id" || -z "$pr" ]] && return 0
  if [[ -f "$lock" ]] && kill -0 "$(cat "$lock" 2>/dev/null || echo 0)" 2>/dev/null; then
    log "ci-watch: a watcher for PR #${pr} is already running — not spawning a second one"
    return 0
  fi
  (
    # Watcher subshell. The lock must record THIS subshell's pid, not the
    # runner's $$ — in a bash subshell $$ is the parent, so a $$-lock made
    # the liveness check above test the wrong process: a watcher dying
    # without its `rm -f` (kill -9/OOM) while the runner lives would wedge
    # every future watcher for the PR for the runner's lifetime. Stock bash
    # 3.2 (macOS) has no subshell-pid builtin, so we can't self-record here;
    # instead the PARENT records our pid via $! immediately after
    # backgrounding us below — for `( … ) &`, the parent's $! equals this
    # subshell's pid, so the lock still ends up holding the watcher's pid.
    if ! farm_timeout "$CI_WATCH_TIMEOUT_SECONDS" gh pr checks "$pr" ${GH_REPO_ARGS[@]+"${GH_REPO_ARGS[@]}"} --watch >/dev/null 2>&1; then
      # Failure OR timeout. Never disturb an already-escalated task (the
      # janitor's ci-rescue pass may have won the race). Before labelling the
      # escalation, re-read the PR's STATE: `gh pr checks --watch` can exit
      # non-zero because the PR merged or was closed mid-watch (checks cancelled
      # on close, or the watch itself erroring on a gone PR) — a "checks
      # failed/timed out" note on a MERGED PR would be flat-out misleading.
      if ! task_has_tag "$id" "ci-stuck" 2>/dev/null; then
        local pr_state="" failing_csv=""
        pr_state="$(farm_timeout 30 gh pr view "$pr" ${GH_REPO_ARGS[@]+"${GH_REPO_ARGS[@]}"} --json state --jq '.state' 2>/dev/null || true)"
        case "$pr_state" in
          MERGED)
            # Merged mid-watch → success; pass_reconcile ships it. No escalation.
            log "ci-watch: PR #${pr} merged during the watch — nothing to do (reconcile ships it)"
            ;;
          CLOSED)
            append_note "$id" "FARM ci-watch: PR #${pr} was CLOSED without merging while auto-merge was armed — needs a decision (reopen/re-implement/drop)."
            kb edit "$id" --add-tag ci-stuck >/dev/null 2>&1 || true
            move_release_to "$id" escalated >/dev/null 2>&1 || true
            log "ci-watch: escalated PR #${pr} (task #${id}) → escalated (PR closed mid-watch)"
            ;;
          *)
            # Still OPEN (or state unreadable — keep the previous honest-default
            # wording): a check genuinely failed, or the watch hit its timeout.
            failing_csv="$(farm_timeout 30 gh pr view "$pr" ${GH_REPO_ARGS[@]+"${GH_REPO_ARGS[@]}"} --json statusCheckRollup \
                --jq '[.statusCheckRollup[]? | select(.conclusion=="FAILURE" or .conclusion=="TIMED_OUT" or .conclusion=="CANCELLED") | .name] | join(",")' \
                2>/dev/null || true)"
            append_note "$id" "FARM ci-watch: PR #${pr} checks failed/timed out [${failing_csv:-unknown}] shortly after auto-merge was armed — needs a supervisor decision."
            kb edit "$id" --add-tag ci-stuck >/dev/null 2>&1 || true
            move_release_to "$id" escalated >/dev/null 2>&1 || true
            log "ci-watch: escalated PR #${pr} (task #${id}) → escalated (checks red post-armed-automerge)"
            ;;
        esac
      fi
    fi
    rm -f "$lock" 2>/dev/null || true
  ) >>"${LOG_DIR:-$STATE_DIR}/ci-watch-${pr}.log" 2>&1 &
  echo "$!" > "$lock" 2>/dev/null || true
  # ^ the farm's one blind actuator gets eyes: the watcher runs fully detached,
  # so its `log` lines (escalate/close/merge decisions) previously went to a
  # discarded stderr — a ticket could be moved to `escalated` with ZERO journal
  # trace. Append them to a per-PR ci-watch log under LOG_DIR (glob-visible to
  # `farmctl tail`) so every ci-watch board mutation is reconstructable.
  return 0
}

# On failure: first strike → tag + requeue; second strike → escalated.
# Circuit breaker: FARM_MAX_FAILSTREAK consecutive failures (across tasks and
# workers) = systemic problem (broken CI, bad deps, expired gh auth) → pause
# the whole farm instead of grinding the board into escalated overnight.
FAILSTREAK_FILE="$STATE_DIR/failstreak"
FARM_MAX_FAILSTREAK="${FARM_MAX_FAILSTREAK:-5}"

# Sustained-outage backstop, mirroring the failstreak circuit breaker but for
# the TRANSIENT-infra class. Transient errors requeue NO-STRIKE (they never
# touch FAILSTREAK_FILE), so without a separate counter a long provider outage
# would churn the board forever. This counter increments on each transient
# event and resets on any task success (note_success). At INFRA_MAX_STREAK it
# PAUSES the farm — never escalates good tasks to escalated, unlike the
# generic failure path that mis-escalated #3/#7/#9 on 2026-06-13.
INFRA_STREAK_FILE="$STATE_DIR/infra-streak"
INFRA_MAX_STREAK="${INFRA_MAX_STREAK:-8}"
# Per-TASK transient cap: after this many CONSECUTIVE transient failures on ONE
# task, the runner escalates it to escalated instead of looping no-strike
# forever (a poison task misclassified transient — distinct from a provider
# outage, which the global INFRA_MAX_STREAK handles).
INFRA_MAX_TASK_RETRIES="${INFRA_MAX_TASK_RETRIES:-3}"

note_success() {
  rm -f "$FAILSTREAK_FILE"
  rm -f "$INFRA_STREAK_FILE"
  rm -f "$INFRA_NOTE_MARKER"
}

# Auto-merge handoff = SUCCESS, not failure. For a non-protected PR the QA agent
# arms auto-merge and intentionally LEAVES the task in `review`, still claimed and
# tagged `pr-<N>`, for the janitor to ship on green (qa.md §6). The runner's QA
# EXPECT_STATUS is `shipped|escalated`, so without this it MISreads that correct
# handoff as a failure → note_failure_streak → the circuit breaker trips when
# several auto-merge PRs drain in a row (the 2026-06-14 false pause: #55/#56/#39/#51,
# all of which actually merged). Recognise the handoff: final=review, clean exit,
# and a `pr-<N>` tag present. Stays strict — a clean-exit QA run that left the task
# in review WITHOUT arming auto-merge (no pr tag) is still a real failure.
# Args: <final_status> <rc> <task_id>. Returns 0 (success) iff this is a handoff.
is_armed_handoff() {
  local final="$1" rc="$2" id="$3"
  [[ "$final" == "review" && "$rc" -eq 0 ]] || return 1
  kb show "$id" --json 2>/dev/null \
    | jq -e '(.tags // []) | map(startswith("pr-")) | any' >/dev/null 2>&1
}

note_failure_streak() {
  local n
  n="$(cat "$FAILSTREAK_FILE" 2>/dev/null || true)"; [[ "$n" =~ ^[0-9]+$ ]] || n=0  # never arithmetic on raw state content
  n=$(( 10#$n + 1 ))
  echo "$n" > "$FAILSTREAK_FILE"
  if (( n >= FARM_MAX_FAILSTREAK )); then
    touch "$PAUSE_FILE"
    log "CIRCUIT BREAKER: $n consecutive failures — farm PAUSED. Inspect logs, fix the systemic cause, then: farmctl resume"
  fi
}

# Sustained transient-infra outage tracker. Increment on each transient event;
# at INFRA_MAX_STREAK pause the farm rather than churning the board. Resets on
# success via note_success. Always returns 0 (runs on the no-strike requeue
# path; a board/file hiccup here must never crash the runner under `set -e`).
note_infra_failure_streak() {
  local n
  n="$(cat "$INFRA_STREAK_FILE" 2>/dev/null || true)"; [[ "$n" =~ ^[0-9]+$ ]] || n=0  # never arithmetic on raw state content
  n=$(( 10#$n + 1 ))
  echo "$n" > "$INFRA_STREAK_FILE" 2>/dev/null || true
  if (( n >= INFRA_MAX_STREAK )); then
    touch "$PAUSE_FILE" 2>/dev/null || true
    log "CIRCUIT BREAKER (infra): sustained model/API outage — farm PAUSED; resume with farmctl resume once the provider recovers."
  fi
  return 0
}

# Append an infra-outage board note AT MOST ONCE per gate window (the marker is
# cleared when the gate expires in wait_if_gated, and on any success). Prevents
# the note flood a network outage used to produce (~900 identical requeue notes
# on one ticket). Always returns 0 — runs on the no-strike path under `set -e`.
note_infra_outage_once() { # id, reason
  local id="$1" reason="$2"
  [[ -f "$INFRA_NOTE_MARKER" ]] && return 0
  append_note "$id" "FARM: infrastructure outage — ${reason}; requeued no-strike, farm backoff gate set (further identical outages this window are suppressed)." || true
  : > "$INFRA_NOTE_MARKER" 2>/dev/null || true
  return 0
}

# A git-fetch/network outage while preparing a worktree is an INFRA event, not a
# task failure — handle it EXACTLY like a transient model/API error: requeue the
# claimed task NO-STRIKE (never escalate a good task on an outage — the
# 2026-06-13 mis-escalation class), set the farm-wide backoff gate so all workers
# pause instead of hammering a down remote, bump the infra streak so the infra
# breaker fires on a SUSTAINED outage, and note the ticket at most once/window.
# Always returns 0 (no-strike path under `set -e`).
requeue_on_infra_outage() { # id, source_status, reason
  local id="$1" source_status="$2" reason="$3"
  kb edit "$id" --release >/dev/null 2>&1 || true
  requeue_unblocked "$id" "$source_status"
  note_infra_outage_once "$id" "$reason"
  note_infra_failure_streak
  set_infra_backoff_gate
  return 0
}

# Per-TASK transient-failure counter (vs the GLOBAL INFRA_STREAK above). A single
# task that deterministically dies (OOM, a tool segfault → rc≠0 with no result
# event) is misclassified transient and requeued no-strike FOREVER — it never
# strikes, never escalates, and the global breaker only catches it if
# INFRA_MAX_STREAK such events cluster. This counts CONSECUTIVE transient failures
# for ONE task: at INFRA_MAX_TASK_RETRIES the runner escalates it to escalated (a
# poison task, not an outage). The id is numeric (kanban-md) → filesystem-safe.
# Reset on any non-transient outcome (success / real failure) via
# clear_task_infra_retry. Always echoes a verdict; never crashes the caller.
note_task_infra_retry() { # id -> echoes "requeue" | "escalate"
  local id="$1" f n
  f="$STATE_DIR/infra-retry-${id}"
  n="$(cat "$f" 2>/dev/null || true)"; [[ "$n" =~ ^[0-9]+$ ]] || n=0  # never arithmetic on raw state content
  n=$(( 10#$n + 1 ))
  echo "$n" > "$f" 2>/dev/null || true
  if (( n >= ${INFRA_MAX_TASK_RETRIES:-3} )); then echo escalate; else echo requeue; fi
}
clear_task_infra_retry() { rm -f "$STATE_DIR/infra-retry-${1}" 2>/dev/null || true; }

# Per-TASK usage-limit requeue cap, mirroring the infra poison-task cap above:
# a task whose runs keep ending on a limit must not requeue no-strike forever.
# Only a PHRASE-sourced limit (limit_detect_source: no TERMINAL rejected
# rate_limit_event in the log) after a session of >= LIMIT_CAP_MIN_SECONDS counts: during a genuine long limit the gate reopens,
# the task hits the limit again within seconds, and must never be escalated.
LIMIT_MAX_TASK_RETRIES=3
LIMIT_CAP_MIN_SECONDS=120
# Pure: source ("event"|"phrase-result"|"phrase") secs count cap -> echoes "<new_count> requeue|escalate".
_limit_retry_decide() {
  local src="$1" secs="$2" n="$3" cap="$4"
  if [[ "$src" == phrase || "$src" == phrase-result ]] && (( secs >= LIMIT_CAP_MIN_SECONDS )); then
    n=$(( n + 1 ))
    if (( n >= cap )); then echo "$n escalate"; return 0; fi
  fi
  echo "$n requeue"
}
note_task_limit_retry() { # id source secs -> echoes "requeue" | "escalate"
  local f="$STATE_DIR/limit-retry-${1}" n d
  n="$(cat "$f" 2>/dev/null || true)"; [[ "$n" =~ ^[0-9]+$ ]] || n=0  # never arithmetic on raw state content
  d="$(_limit_retry_decide "$2" "$3" "$(( 10#$n ))" "$LIMIT_MAX_TASK_RETRIES")"
  echo "${d%% *}" > "$f" 2>/dev/null || true
  echo "${d#* }"
}
clear_task_limit_retry() { rm -f "$STATE_DIR/limit-retry-${1}" 2>/dev/null || true; }

# Failure handler. Runs under `set -e`, so EVERY board call must be
# `|| true` — a single un-guarded rejection here kills the runner and the task
# is never requeued (the 2026-06-13 wedge). The handler must always RETURN.
# Claim semantics (verified on scratch board): at entry the task is still
# claimed by us. `--claim` and `--release` are MUTUALLY EXCLUSIVE
# ("cannot use --claim and --release together", exit 1), so the release calls
# must NOT pass --claim. A combined `--add-tag ... --release` (and a bare
# `--release`) is accepted on a task claimed by us because the release in the
# same call satisfies the ownership guard; once released, a bare `move`/`edit`
# on the now-unclaimed task is accepted. The only call here that mutates while
# still claimed (the `--block` after escalation) runs post-release, so it needs
# no --claim either.
# Move a ticket back into a WORK queue (ready — or review for a QA re-attempt)
# and clear any lingering blocked state IN THE SAME STEP. `kb pick` only serves
# unblocked tickets, so a block flag surviving a requeue — e.g. set by a prior
# escalation whose human answer sent the ticket back to `ready` — leaves it
# INVISIBLE to every worker: parked in a pickable column that nobody can pick,
# stranded silently until a human notices (RC#8, eval run 3). A ticket in a
# work queue is by definition workable, so the unblock is unconditional
# (harmless no-op on an unblocked ticket). Callers release the claim first
# (their existing pattern); best-effort under `set -e`; always returns 0.
requeue_unblocked() { # id, dest_status → 0 always
  local id="$1" dest="$2"
  kb edit "$id" --unblock >/dev/null 2>&1 || true
  kb move "$id" "$dest" >/dev/null 2>&1 || true
  return 0
}

handle_failure() { # id, source_status, reason
  local id="$1" src="$2" reason="$3"
  note_failure_streak
  append_note "$id" "FARM: run by ${AGENT_NAME} failed — ${reason}"
  if task_has_tag "$id" "farm-retry"; then
    kb edit "$id" --release >/dev/null 2>&1 || true
    kb move "$id" escalated >/dev/null 2>&1 || true
    kb edit "$id" --block "two automated attempts failed: ${reason}" >/dev/null 2>&1 || true
    log "task $id escalated (moved to escalated)"
  else
    kb edit "$id" --add-tag farm-retry --release >/dev/null 2>&1 || true
    requeue_unblocked "$id" "$src"
    log "task $id requeued to $src (first failure)"
  fi
  return 0
}

# Release + requeue a task that a runner SIGTERM/INT interrupted MID-RUN (systemd
# restart, `farmctl stop`, operator Ctrl-C). The cleanup() EXIT trap calls this so
# a graceful death no longer leaves the ticket wedged in its in-progress column,
# claimed by a now-dead agent, until kanban-md's 2h claim_timeout PLUS the
# janitor's 3h orphan grace (the "restart ≠ re-pick" wedge). The normal loop
# already releases+requeues on every SESSION-ending outcome; this closes the
# RUNNER-process-killed path that the loop never reaches.
#
# Crash-proof and NON-STOMPING (mirrors the limit / transient no-strike requeue):
#   * ALWAYS returns 0 — it runs inside an EXIT trap; a board hiccup must never
#     leave the trap non-zero under `set -e`. Every kb call is `|| true`.
#   * Acts ONLY when the task is STILL claimed by US and STILL in its in-progress
#     column. That single guard is what makes it a safe no-op for every
#     not-our-job state, so a SIGTERM landing in any of them changes nothing:
#       - empty id            → killed before the first claim, or the loop already
#                               cleared ACTIVE_TASK after handling the outcome;
#       - owner != us         → fenced; the new owner drives the task (and a bare
#                               edit/move would be REJECTED anyway);
#       - status != inprogress→ already handed off (implementer success left it in
#                               `review`; QA armed auto-merge) or already requeued
#                               by an outcome handler (claim already released).
#   * NO strike, NO farm-retry tag: an interrupt is operational, not a task
#     failure — striking good tasks on a deploy restart would re-introduce the
#     2026-06-13 mis-escalation class. Release/move use the verified pattern from
#     handle_failure: a bare `--release` is accepted while WE hold the claim, and
#     the subsequent bare `move` is accepted once unclaimed. append_note re-reads
#     ownership itself, so it is safe to call after the release.
# Args: <task_id> <agent_name> <inprogress_status> <source_status>.
requeue_interrupted_task() {
  local id="${1:-}" me="${2:-}" inprogress="${3:-}" source_status="${4:-}"
  [[ -z "$id" || -z "$me" || -z "$inprogress" || -z "$source_status" ]] && return 0
  local row owner status
  row="$(kb show "$id" --json 2>/dev/null)" || return 0
  owner="$(jq -r '.claimed_by // ""' <<<"$row" 2>/dev/null)" || return 0
  status="$(jq -r '.status // ""'     <<<"$row" 2>/dev/null)" || return 0
  [[ "$owner" == "$me" && "$status" == "$inprogress" ]] || return 0
  kb edit "$id" --release >/dev/null 2>&1 || true
  requeue_unblocked "$id" "$source_status"
  append_note "$id" "FARM: ${me} interrupted mid-run (runner restart/stop); requeued no-strike." || true
  log "task #$id interrupted mid-run — released + requeued ($inprogress→$source_status, no strike)"
  return 0
}

# ------------------------------------------------------------- worktrees ----
# Bounded exponential-backoff git fetch. The old unguarded `git fetch` under
# `set -euo pipefail` turned a transient network/GitHub outage into a tight
# crash/restart/requeue loop (systemd Restart=always) that spammed the board and
# fired no breaker. This retries a small, bounded number of times, then returns
# non-zero WITHOUT aborting the caller — the runner routes the exhaustion into
# the no-strike infra path (requeue_on_infra_outage). Total worst-case wait is
# bounded (2+4+8 = 14s by default). Never masks a real failure: it only retries
# the fetch itself.
FETCH_MAX_TRIES="${FETCH_MAX_TRIES:-4}"
FETCH_BACKOFF_BASE="${FETCH_BACKOFF_BASE:-2}"   # seconds before retry, doubling
git_fetch_with_backoff() { # repo_dir  → 0 on success, 1 after tries exhausted
  local repo="$1" try=1 delay="$FETCH_BACKOFF_BASE"
  while (( try <= FETCH_MAX_TRIES )); do
    if git -C "$repo" fetch origin --prune --quiet 2>/dev/null; then
      return 0
    fi
    (( try >= FETCH_MAX_TRIES )) && break
    log "git fetch failed (attempt $try/$FETCH_MAX_TRIES) — retrying in ${delay}s"
    sleep "$delay"
    delay=$(( delay * 2 ))
    (( try++ ))
  done
  log "git fetch failed after $FETCH_MAX_TRIES attempts — treating as an infra outage"
  return 1
}

make_worktree() { # name, branch ('' => detached at origin/MAIN)
  local branch="${2:-}" wt="$WORKTREES_DIR/$1" base
  # Guarded fetch: on a sustained outage return non-zero (never crash the runner).
  git_fetch_with_backoff "$REPO_DIR" || return 1
  rm -rf "$wt"; git -C "$REPO_DIR" worktree prune >/dev/null 2>&1 || true
  if [[ -n "$branch" ]]; then
    # Resume protocol: if a previous (dead) attempt already pushed this
    # branch, base the worktree on it — never reset pushed work to main.
    if git -C "$REPO_DIR" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
      base="origin/$branch"
      log "remote branch $branch exists — resuming from it"
    else
      base="origin/$MAIN_BRANCH"
    fi
    git -C "$REPO_DIR" worktree add -B "$branch" "$wt" "$base" --quiet
  else
    git -C "$REPO_DIR" worktree add --detach "$wt" "origin/$MAIN_BRANCH" --quiet
  fi
  echo "$wt"
}

drop_worktree() { # path
  git -C "$REPO_DIR" worktree remove --force "$1" >/dev/null 2>&1 || rm -rf "$1"
  git -C "$REPO_DIR" worktree prune >/dev/null 2>&1 || true
}

# WIP-push-on-death (work-recovery, not just ticket-recovery). When an
# implementer dies mid-task, requeuing the TICKET is not enough: any uncommitted
# changes or local commits never pushed live only in the worktree, which the
# janitor prunes at 24h → work lost (the 2026-06-13 task-#3 model-404 incident,
# recovered manually by the operator). This helper best-effort preserves that
# work by committing + PUSHING it to origin/$branch, so the EXISTING resume
# protocol in make_worktree (bases a new worktree on origin/$branch when it
# exists) recovers it automatically on the next attempt.
#
# Hard invariants:
#   * Best-effort: ALWAYS returns 0 — it runs on death/cleanup paths under
#     `set -e`, so it must never crash the caller.
#   * NEVER force-pushes (no --force / --force-with-lease) — a stale local view
#     must never clobber pushed work; a rejected push just leaves the worktree
#     for the janitor backstop.
#   * --no-verify: this is WIP, not a reviewed PR; pre-push/commit hooks must not
#     gate it. Real CI runs when a genuine PR is opened by the resuming agent.
#   * Commits are clearly marked WIP and are never auto-merged.
#   * No-op for QA (empty branch — QA checks out the PR, owns no feature branch)
#     and for an already-clean, fully-pushed worktree (no empty-commit spam).
preserve_worktree_work() { # worktree_path, branch  → always returns 0
  local wt="$1" branch="${2:-}"
  [[ -z "$branch" ]] && return 0                       # QA has no feature branch → skip
  [[ -d "$wt/.git" || -f "$wt/.git" ]] || return 0     # worktree gone → nothing to preserve
  local dirty="" ahead=0
  dirty="$(git -C "$wt" status --porcelain 2>/dev/null)" || return 0
  # Local commits not yet on origin/$branch (0 if the remote ref is absent and
  # we have local commits → rev-list errors, treat as "have commits to push").
  if git -C "$wt" show-ref --verify --quiet "refs/remotes/origin/$branch" 2>/dev/null; then
    ahead="$(git -C "$wt" rev-list --count "origin/$branch..HEAD" 2>/dev/null || echo 0)"
  else
    ahead="$(git -C "$wt" rev-list --count HEAD 2>/dev/null || echo 0)"
  fi
  # Nothing to preserve: clean working tree AND no commits ahead of origin.
  [[ -z "$dirty" && "$ahead" -eq 0 ]] && return 0
  # Only make a commit when there are working changes — never an empty commit.
  if [[ -n "$dirty" ]]; then
    git -C "$wt" add -A >/dev/null 2>&1 || true
    git -C "$wt" commit --no-verify \
      -m "WIP [farm auto-preserve: ${AGENT_NAME:-farm}] — unreviewed partial; resumed by next implementer" \
      >/dev/null 2>&1 || true
  fi
  # Push only if there is now something to push (working changes just committed,
  # or pre-existing local commits ahead of origin). NEVER --force.
  if [[ -n "$dirty" || "$ahead" -gt 0 ]]; then
    if farm_timeout 60 git -C "$wt" push --no-verify -u origin "$branch" >/dev/null 2>&1; then
      log "preserved unpushed work for $branch (resumable)"
    else
      log "WARN: could not preserve/push $branch (best-effort) — work remains in $wt until prune"
    fi
  fi
  return 0
}

# --------------------------------------------------------- lease guard ------
# Real lease semantics with fencing: every cycle the guard (1) verifies we
# still own the claim, (2) renews it (edit --claim bumps claimed_at AND
# `updated`, which the janitor's grace window relies on). If another agent
# owns the task, the guard KILLS the session — a worker that lost its lease
# must stop working immediately, or two agents end up on the same task.
start_lease_guard() { # task_id, session_pid, deadline_epoch  → echoes guard pid
  local id="$1" session_pid="$2" deadline="${3:-0}"
  (
    while sleep "$CLAIM_REFRESH_SECONDS"; do
      kill -0 "$session_pid" 2>/dev/null || exit 0
      if (( deadline > 0 && $(date +%s) > deadline )); then
        log "TASK TIMEOUT on task $id (deadline passed) — killing wedged session $session_pid"
        kill -TERM "$session_pid" 2>/dev/null || true
        sleep 10; kill -KILL "$session_pid" 2>/dev/null || true
        exit 0
      fi
      local owner
      owner="$(kanban-md --dir "$BOARD_DIR" show "$id" --json 2>/dev/null \
                 | jq -r '.claimed_by // ""')" || continue   # transient error: never fence on a failed read
      if [[ -n "$owner" && "$owner" != "$AGENT_NAME" ]]; then
        log "LEASE LOST on task $id (owner now: $owner) — killing session $session_pid"
        kill -TERM "$session_pid" 2>/dev/null || true
        sleep 10; kill -KILL "$session_pid" 2>/dev/null || true
        exit 0
      fi
      kanban-md --dir "$BOARD_DIR" edit "$id" --claim "$AGENT_NAME" >/dev/null 2>&1 || true
    done
  ) >/dev/null &   # stdout detached (command-substitution safety); stderr → journal
  echo $!
}
