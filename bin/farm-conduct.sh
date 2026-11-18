#!/usr/bin/env bash
# farm-conduct.sh — Plan Conductor commands, reached through `farmctl conduct` (PD10:
# farmctl execs this before it sources farm-lib.sh). Contract: contract/README.md.
#   farmctl conduct lint <plan>                          print the units; refuse a bad plan
#   farmctl conduct status <plan> [--json]               one row per unit
#   farmctl conduct adopt <plan> <unit> <handoff path>   record an existing handoff as shipped
#   farmctl conduct run <plan> <unit> [--answer <text>]  carry one unit to a reviewed, merged handoff
#   farmctl conduct run <plan>                           run the plan's units in dependency order
# Sourced with CONDUCT_DEFINE_ONLY=1 it stops before the command dispatch (tests).
# Exit codes (PD26): 0 done, 1 refused or user error, 2 environment error, 3 the run ended
# with a unit stopped or waiting. Plan and handoffs are read from origin/<main> only.

set -euo pipefail
_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Security review M2: the conductor does not source farm-lib.sh, so the work tree's
# .agent-farm/farm.env (bash) is never executed here. It needs only the helpers below.
# Inherited git overrides could redirect every git call; drop them before the first one.
unset GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE \
  GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
while IFS= read -r _v; do
  case "$_v" in GIT_CONFIG_KEY_*|GIT_CONFIG_VALUE_*) unset "$_v" ;; esac
done < <(compgen -e)
# refs/replace/* must never change what <sha>:<path> reads (PD17).
export GIT_NO_REPLACE_OBJECTS=1
# shellcheck source=farm-conduct-lib.sh
source "$_here/farm-conduct-lib.sh" || { echo "farmctl conduct: cannot load farm-conduct-lib.sh" >&2; exit 2; }

die() { echo "farmctl conduct: $2" >&2; exit "$1"; }
log() { echo "farmctl conduct: $*" >&2; }

# Knobs come from the process environment only. Spike S2 = yes.
# shortcut: reading CONDUCT_* knobs from farm.env as data (allowlisted KEY=value, no eval) is M3a's decision.
CONDUCT_LONG_WAIT="${CONDUCT_LONG_WAIT:-1}"
CONDUCT_VERIFY_TIMEOUT_SECONDS="${CONDUCT_VERIFY_TIMEOUT_SECONDS:-1800}"
[[ "$CONDUCT_VERIFY_TIMEOUT_SECONDS" =~ ^[1-9][0-9]{0,6}$ ]] || CONDUCT_VERIFY_TIMEOUT_SECONDS=1800
CONDUCT_LEAD_MODEL="${CONDUCT_LEAD_MODEL:-opus}"
CONDUCT_LEAD_EFFORT="${CONDUCT_LEAD_EFFORT:-high}"
CONDUCT_REVIEW_MODEL="${CONDUCT_REVIEW_MODEL:-opus}"
CONDUCT_REVIEW_EFFORT="${CONDUCT_REVIEW_EFFORT:-high}"
CONDUCT_MAX_SESSION_SECONDS="${CONDUCT_MAX_SESSION_SECONDS:-21600}"
[[ "$CONDUCT_MAX_SESSION_SECONDS" =~ ^[1-9][0-9]{0,6}$ ]] || CONDUCT_MAX_SESSION_SECONDS=21600
CONDUCT_GATE_POLL_SECONDS="${CONDUCT_GATE_POLL_SECONDS:-60}"
[[ "$CONDUCT_GATE_POLL_SECONDS" =~ ^[1-9][0-9]{0,5}$ ]] || CONDUCT_GATE_POLL_SECONDS=60
# Ruling R3: required-check polling (PD27). At most 9 digits, so the arithmetic cannot overflow.
CONDUCT_CHECKS_POLL_SECONDS="${CONDUCT_CHECKS_POLL_SECONDS:-30}"
[[ "$CONDUCT_CHECKS_POLL_SECONDS" =~ ^[1-9][0-9]{0,8}$ ]] || CONDUCT_CHECKS_POLL_SECONDS=30
CONDUCT_CHECKS_TIMEOUT_SECONDS="${CONDUCT_CHECKS_TIMEOUT_SECONDS:-2700}"
[[ "$CONDUCT_CHECKS_TIMEOUT_SECONDS" =~ ^[0-9]{1,9}$ ]] || CONDUCT_CHECKS_TIMEOUT_SECONDS=2700
CONDUCT_RESUME_SESSIONS="${CONDUCT_RESUME_SESSIONS:-1}"
[[ "$CONDUCT_RESUME_SESSIONS" == 0 ]] || CONDUCT_RESUME_SESSIONS=1
[[ -n "${CONDUCT_PIN_FLAGS+set}" ]] || CONDUCT_PIN_FLAGS="--strict-mcp-config --setting-sources project"
# Spike S1. Any value other than settings or plugin-dir refuses to launch (conduct_run_lead).
CONDUCT_GUARD_MODE="${CONDUCT_GUARD_MODE:-plugin-dir}"
CONDUCT_INIT_TIMEOUT_SECONDS="${CONDUCT_INIT_TIMEOUT_SECONDS:-120}"
[[ "$CONDUCT_INIT_TIMEOUT_SECONDS" =~ ^[1-9][0-9]{0,5}$ ]] || CONDUCT_INIT_TIMEOUT_SECONDS=120
CLAUDE_BIN="${CLAUDE_BIN:-claude}"
FARM_DIR="$(cd "$_here/.." && pwd)"   # the plugin root, never from the environment
FARM_LIB="$FARM_DIR/bin/farm-lib.sh"
# Plan loop state (cmd_run_plan), never from the environment: 1 while the loop holds $CDIR/lock for
# the whole plan, so the single-unit path it runs neither takes nor releases it; the file a
# preflight refusal is written to for the pause event.
_PLAN_LOCK=0
_LOOP_REFUSAL=""
# The plan blob the loop pinned (security review M-1, hook finding H1): the unit run it starts in a
# subshell refuses plan-changed when its own setup reads another blob. Empty outside the loop.
_PLAN_PIN=""

REPO_DIR="${FARM_REPO_DIR:-$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || true)}"
[[ -n "$REPO_DIR" && -d "$REPO_DIR" ]] || die 2 "no repository: set FARM_REPO_DIR or run inside a git work tree"
# shellcheck disable=SC2034  # read by conduct_dir (farm-conduct-lib.sh)
FARM_REPO_SLUG="$(conduct_repo_slug "$(git -C "$REPO_DIR" remote get-url origin 2>/dev/null || true)" || true)"
command -v jq >/dev/null 2>&1 || die 2 "jq is not installed: install jq and retry"

# <seconds> <cmd...>: run cmd as its own process group; TERM the whole group after <seconds>,
# KILL it 2 seconds later. Needs no timeout binary (same scheme as farm-lib's _bash_timeout).
bounded() {
  local secs="$1" pid killer rc=0 had_m=0
  shift
  if command -v setsid >/dev/null 2>&1; then
    setsid "$@" & pid=$!
  else
    case $- in *m*) had_m=1 ;; esac
    set -m; "$@" & pid=$!
    [[ "$had_m" == 1 ]] || set +m
  fi
  # The watchdog must not hold the caller's stdout: a $(...) capture would wait for it.
  ( sleep "$secs"; kill -TERM -- "-$pid"; sleep 2; kill -KILL -- "-$pid" ) >/dev/null 2>&1 &
  killer=$!
  wait "$pid" 2>/dev/null || rc=$?
  kill "$killer" 2>/dev/null || true; wait "$killer" 2>/dev/null || true
  return "$rc"
}

usage() {
  echo "usage: farmctl conduct lint <plan> | status <plan> [--json] | adopt <plan> <unit> <handoff path> | run <plan> [<unit> [--answer <text>]]" >&2
  exit 1
}

# stdout: "<branch> <tip sha>" of origin's main, read from the remote itself
# (`git ls-remote --symref origin HEAD`), never from farm.env's MAIN_BRANCH or any local ref
# (refs/remotes/origin/* moves with `git remote set-head` or `git update-ref`). rc 1 when
# ls-remote fails, 2 when HEAD names no valid branch or no 40-hex tip.
origin_main() {
  local out m sha
  out="$(bounded 60 git -C "$REPO_DIR" ls-remote --symref origin HEAD 2>/dev/null)" || return 1
  m="$(printf '%s\n' "$out" | awk -F '\t' '$2 == "HEAD" && $1 ~ /^ref: refs\/heads\/./ { print substr($1, 17); exit }')"
  sha="$(printf '%s\n' "$out" | awk -F '\t' '$2 == "HEAD" && $1 !~ /^ref: / { print $1; exit }')"
  [[ -n "$m" && "$sha" =~ ^[0-9a-f]{40}$ ]] || return 2
  git -C "$REPO_DIR" check-ref-format --branch "$m" >/dev/null 2>&1 || return 2
  printf '%s %s\n' "$m" "$sha"
}

# <cmd...>: run a git command with hooks off, for this call only. NOHOOK is the prefix for
# `bounded`, which cannot run a shell function.
NOHOOK=(env GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/dev/null)
nohook() { "${NOHOOK[@]}" "$@"; }

# PD17: repo-local git config may redirect origin (insteadOf, pushInsteadOf, pushurl) or
# repoint it after the first run. Sets ORIGIN_URL and REPO_PIN; dies 2 when origin is not what
# it says. Two pins: the conductor dir's (named by origin's owner/repo) and the repository
# directory's, so a set-url to another owner/repo is still a change (security review M3a F3).
check_origin() {
  local cu fu pu pin f rd
  cu="$(git -C "$REPO_DIR" config --get remote.origin.url 2>/dev/null)" || cu=""
  # get-url expands insteadOf like `ls-remote --get-url`, and is never a network call.
  fu="$(git -C "$REPO_DIR" remote get-url origin 2>/dev/null)" || fu=""
  pu="$(git -C "$REPO_DIR" remote get-url --push origin 2>/dev/null)" || pu=""
  rd="$(cd "$REPO_DIR" && pwd -P)" || die 2 "cannot resolve the repository directory $REPO_DIR"
  REPO_PIN="${XDG_STATE_HOME:-$HOME/.local/state}/agent-farm/repos/$(printf '%s' "$rd" | cksum | awk '{ print $1 }')/origin_url"
  for f in "$CDIR/origin_url" "$REPO_PIN"; do
    pin=""; [[ -f "$f" ]] && pin="$(head -1 "$f")"
    case "$(conduct_origin_decide "$cu" "$fu" "$pu" "$pin")" in
      ok) ;;
      origin-changed) die 2 "origin-changed: origin is $cu, pinned as $pin; if the change is intended, delete $f" ;;
      *) die 2 "origin-rewritten: git config redirects origin ($cu) to fetch $fu, push $pu; remove the insteadOf/pushurl setting" ;;
    esac
  done
  ORIGIN_URL="$cu"
}
pin_origin() {
  local f
  for f in "$CDIR/origin_url" "$REPO_PIN"; do
    mkdir -p "$(dirname "$f")"
    printf '%s\n' "$ORIGIN_URL" > "$f.tmp.$$" && mv -f "$f.tmp.$$" "$f"
  done
}

# <git dir or work tree>. Dies 2 git-local-config:<key> on a local or worktree config key off
# the allowlist (conduct_git_config_decide), git-info-attributes when the shared
# info/attributes is not empty: either can make git run a program (filter, fsmonitor,
# uploadpack, sshCommand) for the conductor, outside the guard (security review M3a F1/F2).
check_git_config() {
  local l c
  l="$(git -C "$1" config --list --show-scope --name-only 2>/dev/null)" \
    || die 2 "git-local-config: cannot list the git config of $1"
  c="$(printf '%s\n' "$l" | conduct_git_config_decide)"
  [[ "$c" == ok ]] || die 2 "$c: repo-local git config of $1 sets a key the conductor does not allow; remove it (git config --unset)"
  c="$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" \
    || die 2 "git-info-attributes: cannot find the git directory of $1"
  [[ ! -s "$c/info/attributes" ]] || die 2 "git-info-attributes: $c/info/attributes is not empty; empty it"
}

# <plan>. Sets PLAN, KEY, CDIR, ORIGIN_MAIN (origin's main tip commit sha: every plan and
# handoff blob is read as <sha>:<path>, never through a ref), MAIN_LABEL (origin/<branch>, for
# messages), UNITS (conduct_plan_units lines) and SHIPPED (units of this plan with a review or
# adoption record, comma list) after one fetch.
setup() {
  local text main rc
  PLAN="$1"
  KEY="$(conduct_plan_key "$PLAN")" || die 1 "bad plan path: $PLAN (a repo-relative .md path without ..)"
  CDIR="$(conduct_dir)" || die 2 "no origin remote in $REPO_DIR: cannot name the conductor state"
  check_origin
  check_git_config "$REPO_DIR"
  bounded 120 "${NOHOOK[@]}" git -C "$REPO_DIR" fetch origin --prune --quiet 2>/dev/null || log "git fetch failed: using the last fetched origin state"
  main="$(origin_main)" || { rc=$?
    [[ "$rc" == 1 ]] && die 2 "cannot read origin's default branch: git ls-remote origin HEAD failed in $REPO_DIR"
    die 2 "origin's HEAD in $REPO_DIR names no valid branch or tip"; }
  MAIN_LABEL="origin/${main% *}"; ORIGIN_MAIN="${main#* }"
  git -C "$REPO_DIR" cat-file -e "$ORIGIN_MAIN^{commit}" 2>/dev/null \
    || die 2 "$MAIN_LABEL tip $ORIGIN_MAIN is not fetched into $REPO_DIR"
  text="$(git -C "$REPO_DIR" show "$ORIGIN_MAIN:$PLAN" 2>/dev/null)" || die 1 "plan $PLAN is not on $MAIN_LABEL; merge it first"
  UNITS="$(printf '%s\n' "$text" | conduct_plan_units)"
  SHIPPED="$( { records "$CDIR/reviews.jsonl"; records "$CDIR/adopted.jsonl"; } | cut -f1 | sort -u | tr '\n' ',')"
}

# <jsonl file>. stdout: "unit<TAB>handoff_path" for each well-formed record of PLAN, in file
# order. A malformed line is skipped.
records() {
  [[ -f "$1" ]] || return 0
  jq -R -r --arg p "$PLAN" 'fromjson? | select(type == "object" and .plan == $p and (.unit | type) == "string")
    | [.unit, (.handoff_path // "" | tostring)] | @tsv' "$1"
}

# stdout: the guard's protected globs at ORIGIN_MAIN (_guard_policy_globs in a child, ruling R1:
# the mandatory list plus the project list as committed there, never the work tree's). Its rc.
policy_globs() {
  GUARD_DEFINE_ONLY=1 CLAUDE_PLUGIN_ROOT="$FARM_DIR" bash -c 'source "$1" || exit 9; _guard_policy_globs "$2" "$3"' _ \
    "$FARM_DIR/hooks/guard-bash.sh" "$REPO_DIR" "$ORIGIN_MAIN" </dev/null 2>/dev/null
}

# Operator decision 2026-11-18: PLAN must match a protected glob on ORIGIN_MAIN, so the guard denies
# a lead's merge that rewrites it. Refused: exit 1 (_conduct_refuse; a pause in the plan loop).
# Exit 2 when the globs cannot be read.
plan_protected_or_die() {
  local g
  g="$(policy_globs)" || die 2 "cannot read the protected globs on $MAIN_LABEL; run again later"
  [[ "$(printf '%s\n' "$g" | conduct_plan_protected_decide "$PLAN")" == ok ]] || _conduct_refuse \
    "plan-unprotected: $PLAN matches no protected glob on $MAIN_LABEL; move the plan under docs/superpowers/plans/ or list it in .agent-farm/protected-paths.txt"
}

# Operator requirement 2026-11-18: PLAN links its spec (conduct_plan_spec), a file on ORIGIN_MAIN,
# never the work tree's. Refused: exit 1 (_conduct_refuse) with no-spec, spec-bad-path or spec-missing.
plan_spec_or_die() {
  local s rc=0
  s="$(git -C "$REPO_DIR" show "$ORIGIN_MAIN:$PLAN" 2>/dev/null | conduct_plan_spec "$PLAN")" || rc=$?
  case "$rc:$s" in
    0:?*) [[ "$(git -C "$REPO_DIR" cat-file -t "$ORIGIN_MAIN:$s" 2>/dev/null)" == blob ]] \
      || _conduct_refuse "spec-missing: $PLAN links its spec as $s, which is not a file on $MAIN_LABEL; merge the spec first" ;;
    *:no-spec) _conduct_refuse "no-spec: $PLAN has no **Spec:** line before its first unit; add one linking the spec, e.g. **Spec:** [spec](../specs/<name>.md)" ;;
    *) _conduct_refuse "spec-bad-path: the **Spec:** line of $PLAN links no repository file (a URL, an absolute path, or a path outside the repository)" ;;
  esac
}

lint_or_die() {
  local out
  out="$(printf '%s\n' "$UNITS" | conduct_lint "$SHIPPED")" || { printf '%s\n' "$out"; exit 1; }
}

# <pid>: rc 0 when it is a valid pid (^[1-9][0-9]{0,9}$, > 1) of a live process. A zombie (an
# exited child not yet reaped, which kill -0 still reaches) is not live.
pid_alive() {
  [[ "$1" =~ ^[1-9][0-9]{0,9}$ ]] && (( 10#$1 > 1 )) && kill -0 "$1" 2>/dev/null \
    && [[ "$(ps -o stat= -p "$1" 2>/dev/null | tr -d ' ')" != Z* ]]
}

long_wait_note() {
  echo "long waits are not available here: a unit whose plan needs one command to wait longer than nine minutes is not eligible for conducting"
}

# Sets REVIEWED (units), ADOPTED (unit<TAB>handoff path) and SHIPPED_NOW="," for unit_status.
load_records() {
  REVIEWED="$(records "$CDIR/reviews.jsonl" | cut -f1)"
  ADOPTED="$(records "$CDIR/adopted.jsonl")"
  SHIPPED_NOW=","
}

# <unit>. stdout: the unit's last adopted handoff path in ADOPTED, or nothing.
adopted_path() { printf '%s\n' "$ADOPTED" | awk -F '\t' -v u="$1" '$1 == u && $2 != "" { p = $2 } END { print p }'; }

# <unit> <deps, comma list>. Sets UD (state dir), HP (handoff path: adopted, else the default)
# and ST (status) and adds a shipped unit to SHIPPED_NOW. Call in dependency order.
unit_status() {
  local u="$1" adp onm rev ds dep st
  UD="$CDIR/$KEY/$(conduct_unit_slug "$u")"
  HP="$(adopted_path "$u")"
  adp=1; [[ -n "$HP" ]] || { adp=0; HP="$(conduct_handoff_path "$PLAN" "$u")"; }
  onm=0; git -C "$REPO_DIR" cat-file -e "$ORIGIN_MAIN:$HP" 2>/dev/null && onm=1
  rev=0; printf '%s\n' "$REVIEWED" | grep -Fx -- "$u" >/dev/null && rev=1
  ds=1
  while IFS= read -r dep; do
    [[ -z "$dep" ]] || case "$SHIPPED_NOW" in *",$dep,"*) ;; *) ds=0 ;; esac
  done < <(printf '%s\n' "$2" | tr ',' '\n')
  st=none; [[ -f "$UD/state" ]] && st="$(head -1 "$UD/state")"
  ST="$(conduct_unit_status "$onm" "$rev" "$adp" "$st" "$ds")"
  [[ "$ST" != shipped ]] || SHIPPED_NOW="$SHIPPED_NOW$u,"
}

# <file>. stdout: its first line when it is a non-negative integer of at most 10 digits
# (no 64-bit overflow), else 0.
int_of() {
  local v=""
  [[ -f "$1" ]] && v="$(head -1 "$1")"
  if [[ "$v" =~ ^[0-9]{1,10}$ ]]; then echo "$((10#$v))"; else echo 0; fi
}

cmd_lint() {
  local u t d
  setup "$1"; plan_protected_or_die; plan_spec_or_die; lint_or_die
  # \037, not a tab: tab is IFS whitespace, so an empty field (no deps) would collapse.
  while IFS=$'\037' read -r u t d _; do
    printf '%s#%s\t%s\tdepends on: %s\n' "$PLAN" "$u" "$t" "${d:-none}"
  done < <(printf '%s\n' "$UNITS" | tr '\t' '\037')
  if [[ "$CONDUCT_LONG_WAIT" == 0 ]]; then
    long_wait_note
  fi
}

# One row (contract/README.md) per unit, computed in dependency order, printed in plan order.
cmd_status() {
  local json=0 plan="" a u t d line claimed sr prs usage rows=""
  for a in "$@"; do
    case "$a" in --json) json=1 ;; -*) usage ;; *) [[ -z "$plan" ]] || usage; plan="$a" ;; esac
  done
  [[ -n "$plan" ]] || usage
  setup "$plan"; lint_or_die
  load_records
  while IFS= read -r u; do
    IFS=$'\037' read -r _ t d _ line < <(printf '%s\n' "$UNITS" | awk -F '\t' -v u="$u" '$1 == u' | tr '\t' '\037')
    unit_status "$u" "$d"
    claimed=""; pid_alive "$(int_of "$UD/pid")" && claimed="${HOSTNAME:-localhost}:$(int_of "$UD/pid")"
    sr=""; [[ -f "$UD/stop_reason" ]] && sr="$(cat "$UD/stop_reason")"
    prs="$(jq -R -s -c '[splits("[ \t\n,]+") | select(test("^[0-9]+$")) | tonumber]' "$( [[ -f "$UD/prs" ]] && echo "$UD/prs" || echo /dev/null)")"
    # usage.jsonl lines (conduct_record_usage; the sums read in, out, cache_read, cache_creation,
    # cost_usd and wall_s): one per session; verify runs (role "verify") are not sessions and are left out.
    usage="$(jq -R -s -c --arg p "$PLAN" --arg u "$u" '
      [split("\n")[] | fromjson? | select(type == "object" and .plan == $p and .unit == $u and .role != "verify")] as $r
      | def n($k): [$r[] | .[$k] | numbers] | add // 0;
      {sessions: ($r | length), in: n("in"), out: n("out"), cache_read: n("cache_read"),
       cache_creation: n("cache_creation"), cost_usd: n("cost_usd"), wall_s: n("wall_s")}' \
      "$( [[ -f "$CDIR/usage.jsonl" ]] && echo "$CDIR/usage.jsonl" || echo /dev/null)")"
    rows+="$line$(printf '\t')$(jq -cn --arg plan "$PLAN" --arg unit "$u" --arg title "$t" --arg status "$ST" \
      --arg deps "$d" --arg c "$claimed" --arg sr "$sr" --argjson prs "$prs" --arg hp "$HP" --argjson usage "$usage" \
      --argjson s "$(int_of "$UD/attempts")" --argjson rw "$(int_of "$UD/rework")" \
      --argjson co "$(int_of "$UD/continuation")" --argjson it "$(int_of "$UD/interruption")" '
      {id: ($plan + "#" + $unit), plan: $plan, unit: $unit, title: $title, status: $status,
       depends_on: [$deps | split(",")[] | select(. != "") | $plan + "#" + .],
       claimed_by: (if $c == "" then null else $c end), stop_reason: (if $sr == "" then null else $sr end),
       prs: $prs, handoff_path: $hp, attempts: {sessions: $s, rework: $rw, continuation: $co, interruption: $it},
       owner_ref: null, usage: $usage}')"$'\n'
  done < <(printf '%s\n' "$UNITS" | conduct_topo_order)
  rows="$(printf '%s' "$rows" | sort -n | cut -f2- | jq -s -c .)"
  if [[ "$json" == 1 ]]; then printf '%s\n' "$rows"
  else printf '%s\n' "$rows" | jq -r '.[] | [.unit, .status, .title] | @tsv'; fi
}

# PD14: the handoff must be on origin/<main> and pass phase two; nothing is written otherwise.
cmd_adopt() {
  local unit hp text deps out
  [[ $# -eq 3 ]] || usage
  setup "$1"; lint_or_die
  unit="$2"; hp="$3"
  printf '%s\n' "$UNITS" | cut -f1 | grep -Fx -- "$unit" >/dev/null || die 1 "unit $unit is not in $PLAN"
  conduct_plan_key "$hp" >/dev/null || die 1 "bad handoff path: $hp"
  text="$(git -C "$REPO_DIR" show "$ORIGIN_MAIN:$hp" 2>/dev/null)" || die 1 "handoff $hp is not on $MAIN_LABEL; merge it first"
  deps="$(printf '%s\n' "$UNITS" | conduct_dependents "$unit" | tr '\n' ',')"
  out="$(printf '%s\n' "$text" | conduct_handoff_validate two "${deps%,}")" \
    || { printf '%s\n' "$out"; die 1 "handoff $hp fails phase two; not adopted"; }
  mkdir -p "$CDIR"
  jq -cn --arg plan "$PLAN" --arg unit "$unit" --arg hp "$hp" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg sha "$ORIGIN_MAIN" \
    '{plan: $plan, unit: $unit, handoff_path: $hp, adopted_at: $at, sha: $sha}' >> "$CDIR/adopted.jsonl"
  pin_origin   # setup's check_origin matched any existing pin, so this only adds a missing one
  echo "adopted $PLAN#$unit: $hp"
}

# <lockdir>: rc 0 with <lockdir>/pid naming this conductor; rc 1 while a live pid holds it.
# A lock whose pid file names a finished process or no valid pid is taken over (PD18).
# shortcut: a takeover can race a lock created but whose pid is not yet written; one conductor per repository is assumed.
conduct_lock() {
  [[ "$_PLAN_LOCK" != 1 ]] || return 0
  mkdir -p "$(dirname "$1")"
  if ! mkdir "$1" 2>/dev/null; then
    pid_alive "$(head -1 "$1/pid" 2>/dev/null)" && return 1
    rm -rf "$1"; mkdir "$1" 2>/dev/null || return 1
  fi
  echo "$$" > "$1/pid"
}
conduct_unlock() { [[ "$_PLAN_LOCK" == 1 ]] || rm -rf "$1"; }

# <plan> <unit> <phase: preflight|pre-merge> <command>. Runs the verify command in a fresh
# work tree detached at ORIGIN_MAIN (from setup), bounded by CONDUCT_VERIFY_TIMEOUT_SECONDS.
# stdout: pass, fail or timeout. Appends a role "verify" line to usage.jsonl; output goes to
# $CDIR/logs/conduct-<unit slug>-verify-<UTC timestamp>.log.
conduct_run_verify() {
  local unit="$2" phase="$3" cmd="$4" slug wt log t0 rc=0 wall out
  slug="$(conduct_unit_slug "$unit")"
  wt="$REPO_DIR/.farm-worktrees/conduct-verify-$(conduct_plan_key "$1")-$slug"
  mkdir -p "$CDIR/logs"; log="$CDIR/logs/conduct-$slug-verify-$(date -u +%Y%m%dT%H%M%SZ).log"
  rm -rf "$wt"; git -C "$REPO_DIR" worktree prune 2>/dev/null || true
  if nohook git -C "$REPO_DIR" worktree add --detach "$wt" "$ORIGIN_MAIN" >"$log" 2>&1; then
    t0=$SECONDS
    # Project code, run outside the guard: the command string comes from a protected path
    # (.agent-farm/farm.env on origin/<main>), the files it runs do not. No API credentials.
    ( cd "$wt" && bounded "$CONDUCT_VERIFY_TIMEOUT_SECONDS" env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN \
        bash -c "$cmd" ) >>"$log" 2>&1 </dev/null || rc=$?
    wall=$((SECONDS - t0))
  else rc=1; wall=0; fi
  out="$(conduct_verify_decide "$rc" "$wall" "$CONDUCT_VERIFY_TIMEOUT_SECONDS")"
  nohook git -C "$REPO_DIR" worktree remove --force "$wt" >/dev/null 2>&1 || rm -rf "$wt"
  git -C "$REPO_DIR" worktree prune 2>/dev/null || true
  jq -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg plan "$1" --arg unit "$unit" --arg phase "$phase" \
    --arg outcome "$out" --argjson rc "$rc" --argjson wall "$wall" \
    '{ts: $ts, plan: $plan, unit: $unit, role: "verify", phase: $phase, outcome: $outcome, exit_code: $rc, wall_s: $wall}' \
    >> "$CDIR/usage.jsonl"
  echo "$out"
}

# <plan> <unit>. Every precondition for running the unit (conduct_preflight_decide order), then
# the verify run, last because it is the only expensive one (PD16). Exit 1 naming the code on a
# refusal (the lock released); on success $CDIR/lock is held and origin's url pinned.
conduct_preflight() {
  local unit="$2" slug d u dep hp e lint=1 deps=1 entry=ok vc=0 cmd mb rules prot bypass=never id b br
  local gm mm=0 lock=0 grc=0 live=0 dec out hps="" vlog
  [[ "${PLAN:-}" == "$1" ]] || setup "$1"
  printf '%s\n' "$UNITS" | cut -f1 | grep -Fx -- "$unit" >/dev/null || die 1 "unit $unit is not in $PLAN"
  [[ "$CONDUCT_LONG_WAIT" != 0 ]] || log "$(long_wait_note)"
  slug="$(conduct_unit_slug "$unit")"
  deps_of() { printf '%s\n' "$UNITS" | awk -F '\t' -v u="$1" '$1 == u { print $3 }'; }
  d="$(deps_of "$unit")"
  printf '%s\n' "$UNITS" | conduct_lint "$SHIPPED" >/dev/null || lint=0
  load_records
  while IFS= read -r u; do
    unit_status "$u" "$(deps_of "$u")"
    case ",$d," in *",$u,"*) hps="$hps$HP"$'\n' ;; esac
  done < <(printf '%s\n' "$UNITS" | conduct_topo_order)
  while IFS= read -r dep; do
    [[ -z "$dep" ]] || case "$SHIPPED_NOW" in *",$dep,"*) ;; *) deps=0 ;; esac
  done < <(printf '%s\n' "$d" | tr ',' '\n')
  # Entry criteria: each dependency's handoff as merged on origin/<main>; worst wins.
  while IFS= read -r hp; do
    [[ -n "$hp" ]] || continue
    e="$(git -C "$REPO_DIR" show "$ORIGIN_MAIN:$hp" 2>/dev/null | conduct_entry_statuses "$unit" | conduct_entry_decide)" || e=invalid
    case "$e" in ok) ;; blocked) [[ "$entry" == invalid ]] || entry=blocked ;; *) entry=invalid ;; esac
  done <<<"$hps"
  # The verify command: farm.env on origin/<main>, parsed and not sourced.
  cmd="$(git -C "$REPO_DIR" show "$ORIGIN_MAIN:.agent-farm/farm.env" 2>/dev/null | conduct_env_value FARM_VERIFY_CMD)" || cmd=""
  [[ -z "$cmd" ]] || vc=1
  # Branch rules (PD17): bypass is never only when every ruleset supplying a counted rule says so.
  mb="${MAIN_LABEL#origin/}"
  # shortcut: a branch name is put into the API path unescaped; fine for names without %, ? or #.
  rules="$(bounded 30 gh api "repos/$FARM_REPO_SLUG/rules/branches/$mb" 2>/dev/null)" || rules=""
  prot="$(bounded 30 gh api "repos/$FARM_REPO_SLUG/branches/$mb/protection" 2>/dev/null)" || prot=""
  while IFS= read -r id; do
    [[ "$id" =~ ^[0-9]{1,12}$ ]] || { bypass=unknown; continue; }
    b="$(bounded 30 gh api "repos/$FARM_REPO_SLUG/rulesets/$id" 2>/dev/null | jq -r '.current_user_can_bypass? // empty' 2>/dev/null)" || b=""
    case "$b" in never) ;; "") [[ "$bypass" == possible ]] || bypass=unknown ;; *) bypass=possible ;; esac
  done < <(printf '%s' "$rules" | jq -r '.[]? | select(type == "object" and (.type == "pull_request" or .type == "required_status_checks")) | .ruleset_id | tostring' 2>/dev/null | sort -u)
  br="$(conduct_branch_rules_decide "$rules" "$prot" "$bypass")"
  # The guard's idea of the main branch must be origin's own; the guard runs in a child, never sourced here.
  gm="$(GUARD_DEFINE_ONLY=1 CLAUDE_PLUGIN_ROOT="$FARM_DIR" bash -c 'source "$1"; _guard_main_ref "$2"' _ \
    "$FARM_DIR/hooks/guard-bash.sh" "$REPO_DIR" 2>/dev/null)" || gm=""
  [[ "$gm" != "$MAIN_LABEL" ]] || mm=1
  conduct_lock "$CDIR/lock" && lock=1
  printf '%s' '{"tool_name":"Bash","tool_input":{"command":"aws s3 rb s3://x"}}' \
    | FARM_AGENT=1 "$FARM_DIR/hooks/guard-bash.sh" >/dev/null 2>&1 || grc=$?
  pid_alive "$(int_of "$CDIR/$KEY/$slug/pid")" && live=1
  dec="$(conduct_preflight_decide "$lint" "$deps" "$entry" "$vc" "$br" "$mm" "$lock" "$grc" "$live")"
  if [[ "$dec" != ok ]]; then
    [[ "$lock" == 0 ]] || conduct_unlock "$CDIR/lock"
    _conduct_refuse "${dec#refuse:} ($PLAN#$unit)"
  fi
  out="$(conduct_run_verify "$PLAN" "$unit" preflight "$cmd")"
  if [[ "$out" != pass ]]; then
    conduct_unlock "$CDIR/lock"
    # shellcheck disable=SC2012  # timestamped names of our own; the newest is this run's
    vlog="$(ls -t "$CDIR/logs/conduct-$slug-verify-"*.log 2>/dev/null | head -1)"
    [[ -z "$vlog" ]] || tail -20 "$vlog" >&2
    [[ "$out" == timeout ]] && _conduct_refuse "verify-timeout ($PLAN#$unit, log $vlog)"
    _conduct_refuse "verify-failed ($PLAN#$unit, log $vlog)"
  fi
  pin_origin
  log "preflight ok: $PLAN#$unit"
}

# <code (detail)>: a preflight refusal, exit 1. Inside the plan loop the text also goes to
# _LOOP_REFUSAL: the loop sends it with the pause event.
_conduct_refuse() {
  [[ -z "$_LOOP_REFUSAL" ]] || printf '%s\n' "$1" > "$_LOOP_REFUSAL" || true
  die 1 "preflight refused: $1"
}

# <unit dir> <counter: rework|continuation|interruption|attempts>. Writes the counter + 1 through
# a temp file and mv; an absent file counts 0. Called before the launch it counts. rc 1, file
# unchanged and never evaluated, when it does not hold an integer of at most 10 digits.
conduct_counter_bump() {
  local f="$1/$2" v=0 t
  case "$2" in rework|continuation|interruption|attempts) ;; *) return 1 ;; esac
  if [[ -e "$f" ]]; then v="$(cat "$f")" || return 1; fi
  [[ "$v" =~ ^[0-9]{1,10}$ ]] || return 1
  t="$(mktemp "$1/.$2.XXXXXX")" || return 1
  echo "$((10#$v + 1))" > "$t" && mv -f "$t" "$f" || { rm -f "$t"; return 1; }
}

# <bash code> [args]: run the code (a literal of this file) in a child shell that loaded
# farm-lib.sh; args are its $1... The deciding shell never loads farm-lib.sh or farm.env itself,
# so their results steer pause, resume and notify only.
farm_lib_sh() {
  local c="$1"; shift
  FARM_REPO_DIR="$REPO_DIR" bash -c 'source "$0" || exit 2; '"$c" "$FARM_LIB" "$@"
}
# <farm-lib function> [args]: call it in such a child.
farm_lib_call() { farm_lib_sh '"$@"' "$@"; }

# <event> <plan> <unit> [reason]. Every event the conductor sends goes through here: the line
# "<UTC ts> <event> <plan> <unit>" is appended to $CDIR/notifications.log first, then farm_notify
# runs the operator's FARM_NOTIFY_CMD. Always rc 0.
conduct_notify() {
  local d="${CDIR:-}"
  [[ -n "$d" ]] || d="$(conduct_dir)" || d=""
  if [[ -n "$d" ]] && mkdir -p "$d"; then
    printf '%s %s %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" "$3" >> "$d/notifications.log" || true
  fi
  farm_lib_call farm_notify "$@" >&2 || true
  return 0
}

# <plan> <unit> <outcome>. For outcome limit sends the limit event once; then sleeps
# CONDUCT_GATE_POLL_SECONDS while the farm's pause file exists or its gate is closed (PD31: a
# gate more than eight days ahead counts as absent and is left alone). One log line per ten minutes.
conduct_wait_gate() {
  local st g now last=-600
  [[ "$3" != limit ]] || conduct_notify limit "$1" "$2"
  while :; do
    st="$(farm_lib_sh 'if [[ -f "$PAUSE_FILE" ]]; then echo paused; else echo open; fi; _gate_until')" || st=unread
    now="$(date +%s)"; g="$(sed -n 2p <<<"$st")"
    # Fails closed: a pause file that cannot be read keeps the conductor waiting.
    if [[ "$(sed -n 1p <<<"$st")" != open ]]; then :
    elif [[ "$g" =~ ^[0-9]{1,10}$ ]] && (( 10#$g > now )); then
      if (( 10#$g > now + 8 * 86400 )); then log "limit gate $g is more than eight days ahead: ignored"; return 0; fi
    else return 0; fi
    if (( SECONDS - last >= 600 )); then log "waiting: farm paused or limit gate closed ($1#$2)"; last=$SECONDS; fi
    sleep "$CONDUCT_GATE_POLL_SECONDS"
  done
}

# <pid>: end a session: TERM to its children and to it, five seconds, then KILL.
_conduct_end_session() {
  local p="$1" i=0
  pid_alive "$p" || return 0
  pkill -TERM -P "$p" 2>/dev/null || true; kill -TERM "$p" 2>/dev/null || true
  while (( i < 10 )) && pid_alive "$p"; do sleep 0.5; i=$((i + 1)); done
  if pid_alive "$p"; then pkill -KILL -P "$p" 2>/dev/null || true; kill -KILL "$p" 2>/dev/null || true; fi
}

# <work tree> <commit>. rc 0 when <work tree>/.claude holds exactly <commit>'s .claude tree:
# the same paths, exec bits and bytes (hash-object --no-filters, run in REPO_DIR), only regular
# files and directories, no symlink; both absent is a match. No git command runs in the work
# tree: its index, .git file and gitdir are the session's (re-review of M3a F4).
claude_dir_matches() {
  local wt="$1" e="" a="" rec m h p f tab=$'\t' nl=$'\n'
  [[ ! -L "$wt" ]] || return 1
  git -C "$REPO_DIR" rev-parse --verify -q "$2^{commit}" >/dev/null || return 1
  while IFS= read -r -d '' rec; do
    p="${rec#*"$tab"}"; read -r m _ h <<<"${rec%%"$tab"*}"
    [[ "$p" != *"$nl"* ]] || return 1
    case "$m" in 100644) f=- ;; 100755) f=x ;; *) return 1 ;; esac
    e+="$p $f $h$nl"
  done < <(git -C "$REPO_DIR" ls-tree -r -z --full-tree "$2" -- .claude 2>/dev/null)
  if [[ -e "$wt/.claude" || -L "$wt/.claude" ]]; then
    while IFS= read -r -d '' p; do
      if [[ -L "$p" ]]; then return 1
      elif [[ -d "$p" ]]; then continue
      elif [[ -f "$p" && "$p" != *"$nl"* ]]; then
        f=-; [[ ! -x "$p" ]] || f=x
        h="$(git -C "$REPO_DIR" hash-object --no-filters -- "$p" 2>/dev/null)" || return 1
        a+="${p#"$wt"/} $f $h$nl"
      else return 1; fi
    done < <(find "$wt/.claude" -print0 2>/dev/null)
  fi
  [[ "$(printf '%s' "$a" | LC_ALL=C sort)" == "$(printf '%s' "$e" | LC_ALL=C sort)" ]]
}

# <role: lead|review> <work tree> <prompt> <log> [<resume id>]. Starts one session in the
# background (CONDUCT_SESSION_PID), writes its pid to $CONDUCT_UNIT_DIR/pid and starts the
# watchdog (CONDUCT_WATCHDOG_PID, PD30) and a trap that ends the session if this shell exits.
# Then awaits the init event (conduct_await_init): CONDUCT_GUARD_PROOF is stop when the session
# was ended for lacking the guard, else listed or no-init (the process ended first). rc 0 on a
# launch; the caller waits for CONDUCT_SESSION_PID. rc 1, nothing started, on bad arguments,
# and with CONDUCT_GUARD_PROOF settings-tampered when the work tree's .claude is not origin's
# (a session could switch the guard off for the next one: security review M3a F4).
# The session gets FARM_AGENT=1 and no API key (the billing guard), FARM_WORKTREE and no
# FARM_STATE_DIR (the guard's write confinement keeps the shared gate file out of reach).
conduct_launch() {
  CONDUCT_GUARD_PROOF=""
  local wt="$2" m e pin=() res=() g=() sf t base owner
  case "$1" in
    lead) m="$CONDUCT_LEAD_MODEL"; e="$CONDUCT_LEAD_EFFORT" ;;
    review) m="$CONDUCT_REVIEW_MODEL"; e="$CONDUCT_REVIEW_EFFORT" ;;
    *) return 1 ;;
  esac
  if [[ $# -ge 5 ]]; then [[ "$5" =~ ^[0-9a-f-]{36}$ ]] || return 1; res=(--resume "$5"); fi
  # A session can write the work tree's git config too; check it before git runs there.
  check_git_config "$wt"
  base="${ORIGIN_MAIN:-}"
  if [[ -z "$base" ]]; then base="$(origin_main)" || return 1; base="${base#* }"; fi
  if ! claude_dir_matches "$wt" "$base"; then
    log "$wt/.claude differs from $base (settings-tampered): not launching"
    CONDUCT_GUARD_PROOF=settings-tampered; return 1
  fi
  # Spec 4.5: the conductor registers the guard itself on every launch, resumed ones too (S3).
  case "$CONDUCT_GUARD_MODE" in
    settings)
      sf="${CONDUCT_UNIT_DIR:?}/guard-settings.json"
      t="$(mktemp "$CONDUCT_UNIT_DIR/.guard-settings.XXXXXX")" || return 1
      conduct_guard_settings "$FARM_DIR" > "$t" && mv -f "$t" "$sf" || { rm -f "$t"; return 1; }
      g=(--settings "$sf") ;;
    plugin-dir) g=(--plugin-dir "$FARM_DIR") ;;
    *) return 1 ;;
  esac
  # Split on whitespace only: read assigns words without pathname expansion; never eval'd.
  read -r -a pin <<<"$CONDUCT_PIN_FLAGS" || true
  ( cd "$wt" && exec env -u FARM_STATE_DIR -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN -u GIT_CONFIG_COUNT \
      -u GIT_CONFIG_PARAMETERS FARM_AGENT=1 FARM_WORKTREE="$wt" AGENT_NAME=farm-conduct "$CLAUDE_BIN" -p "$3" \
      --output-format stream-json --verbose --dangerously-skip-permissions --model "$m" --effort "$e" \
      "${g[@]}" ${pin[@]+"${pin[@]}"} ${res[@]+"${res[@]}"} ) >"$4" 2>&1 </dev/null &
  CONDUCT_SESSION_PID=$!
  # The shell that started the session (bash 3.2 has no BASHPID). When it is gone (SIGKILL) the
  # watchdog ends the session and leaves (review M3a F6, re-review N1). It signals only while the
  # session pid, checked every second, is still alive, so never a reused number.
  owner="$(ps -o ppid= -p "$CONDUCT_SESSION_PID" 2>/dev/null | tr -d ' ')"; [[ "$owner" =~ ^[0-9]+$ ]] || owner=$$
  ( sleep "$CONDUCT_MAX_SESSION_SECONDS" & s=$!
    trap 'kill "$s" 2>/dev/null; exit 0' TERM
    while pid_alive "$CONDUCT_SESSION_PID"; do
      if ! pid_alive "$owner"; then
        kill "$s" 2>/dev/null; _conduct_end_session "$CONDUCT_SESSION_PID"; rm -f "$CONDUCT_UNIT_DIR/pid"; exit 0
      fi
      if ! pid_alive "$s"; then wait "$s" && _conduct_end_session "$CONDUCT_SESSION_PID"; exit 0; fi
      sleep 1
    done
    kill "$s" 2>/dev/null ) </dev/null >/dev/null 2>&1 &
  CONDUCT_WATCHDOG_PID=$!
  # A review's verdict directory (CONDUCT_VERDICT_DIR, set only by conduct_run_review) goes too.
  trap '_conduct_stop_watchdog; _conduct_end_session "$CONDUCT_SESSION_PID"; rm -f "$CONDUCT_UNIT_DIR/pid"; _conduct_rm_verdict' EXIT
  trap '_conduct_stop_watchdog; _conduct_end_session "$CONDUCT_SESSION_PID"; rm -f "$CONDUCT_UNIT_DIR/pid"; _conduct_rm_verdict; exit 130' INT
  trap '_conduct_stop_watchdog; _conduct_end_session "$CONDUCT_SESSION_PID"; rm -f "$CONDUCT_UNIT_DIR/pid"; _conduct_rm_verdict; exit 143' TERM
  echo "$CONDUCT_SESSION_PID" > "${CONDUCT_UNIT_DIR:?}/pid"
  # Spec 4.5, every session: no proof of the guard in the init event ends the session. A process
  # that ended before any init event is left to the caller's classifier.
  CONDUCT_GUARD_PROOF="$(conduct_await_init "$4" "$CONDUCT_SESSION_PID")"
  if [[ "$CONDUCT_GUARD_PROOF" == not-listed ]] || { [[ "$CONDUCT_GUARD_PROOF" != listed ]] && pid_alive "$CONDUCT_SESSION_PID"; }; then
    log "the guard is not proven loaded ($CONDUCT_GUARD_PROOF) in $4: ending the session"
    _conduct_end_session "$CONDUCT_SESSION_PID"; CONDUCT_GUARD_PROOF=stop
  fi
}

_conduct_rm_verdict() { [[ -z "${CONDUCT_VERDICT_DIR:-}" ]] || rm -rf "$CONDUCT_VERDICT_DIR"; }

# Stops the watchdog: its sleep first (its wait then fails, so it ends no session), then itself.
_conduct_stop_watchdog() {
  [[ -n "${CONDUCT_WATCHDOG_PID:-}" ]] || return 0
  pkill -TERM -P "$CONDUCT_WATCHDOG_PID" 2>/dev/null || true
  kill -TERM "$CONDUCT_WATCHDOG_PID" 2>/dev/null || true
  wait "$CONDUCT_WATCHDOG_PID" 2>/dev/null || true
  CONDUCT_WATCHDOG_PID=""
}

# <log> <pid>. Waits up to CONDUCT_INIT_TIMEOUT_SECONDS for the session's first system/init line
# (malformed lines skipped). stdout: listed or not-listed (conduct_guard_listed_decide on it), or
# no-init (the timeout, or the process ended first). The init event is the first event of a
# session and tool calls follow a model response, so polling once a second leaves only a small
# window in which an unguarded session could act before it is ended.
conduct_await_init() {
  local i=0 alive ev
  while :; do
    alive=0; pid_alive "$2" && alive=1
    ev="$(jq -R -c -n 'first(inputs | fromjson? | select(type == "object" and .type == "system" and .subtype == "init"))' "$1" 2>/dev/null)" || ev=""
    if [[ -n "$ev" ]]; then
      # Every subscription session reports apiKeySource "none" (spike record); anything else is
      # an API key from somewhere (settings env, apiKeyHelper): no proof (review M3a F4).
      if [[ "$(printf '%s\n' "$ev" | jq -r 'if .apiKeySource == "none" then "none" else "other" end' 2>/dev/null)" != none ]]; then
        echo not-listed; return 0
      fi
      printf '%s\n' "$ev" | conduct_guard_listed_decide "$CONDUCT_GUARD_MODE" "$FARM_DIR"; return 0
    fi
    [[ "$alive" == 1 ]] && (( i < CONDUCT_INIT_TIMEOUT_SECONDS )) || break
    sleep 1; i=$((i + 1))
  done
  echo no-init
}

# <plan> <unit> <mode: start|continue|rework|resume>. Launches one lead session in the unit's
# work tree and waits for it. stdout: only the outcome word: ended (an open handoff pull request
# is never a limit hit, spec 4.5), else limit, else transient, else ended. guard-not-loaded, before
# all of these, when the guard mode is unknown (no session started) or the session's init event
# does not list the guard (the session is ended); settings-tampered, no session started, when
# the reused work tree's .claude differs from origin's. Everything else to stderr.
conduct_run_lead() {
  local unit="$2" mode="$3" slug ud wt dep hp dh="" dn vc f k n=-1 fl=none an=none prompt log rid=() rc=0
  local sid bp prs cnt att t0
  case "$mode" in start|continue|rework|resume) ;; *) die 1 "bad mode: $mode" ;; esac
  [[ "${PLAN:-}" == "$1" && -n "${ORIGIN_MAIN:-}" ]] || setup "$1"
  printf '%s\n' "$UNITS" | cut -f1 | grep -Fx -- "$unit" >/dev/null || die 1 "unit $unit is not in $PLAN"
  case "$CONDUCT_GUARD_MODE" in settings|plugin-dir) ;; *)
    log "unknown CONDUCT_GUARD_MODE $CONDUCT_GUARD_MODE (settings or plugin-dir): not launching"
    echo guard-not-loaded; return 0 ;;
  esac
  slug="$(conduct_unit_slug "$unit")"; ud="$CDIR/$KEY/$slug"; mkdir -p "$ud" "$CDIR/logs"
  # A bad attempts file must not read as 0: that would delete the work tree below.
  att=0; [[ ! -e "$ud/attempts" ]] || att="$(cat "$ud/attempts")" || att=bad
  [[ "$att" =~ ^[0-9]{1,10}$ ]] || die 2 "$ud/attempts does not hold an integer; not launching"
  # Created once from origin's tip and reused afterwards: it holds the session's work.
  wt="$REPO_DIR/.farm-worktrees/conduct-$KEY-$slug"
  if [[ "$((10#$att))" == 0 || ! -d "$wt" ]]; then
    [[ "$((10#$att))" != 0 ]] || { rm -rf "$wt"; printf '%s\n' "$ORIGIN_MAIN" > "$ud/start_sha"; }
    git -C "$REPO_DIR" worktree prune 2>/dev/null || true
    nohook git -C "$REPO_DIR" worktree add --detach "$wt" "$ORIGIN_MAIN" >&2 || die 2 "cannot create the work tree $wt"
  fi
  ADOPTED="$(records "$CDIR/adopted.jsonl")"
  while IFS= read -r dep; do
    [[ -n "$dep" ]] || continue
    hp="$(adopted_path "$dep")"; [[ -n "$hp" ]] || hp="$(conduct_handoff_path "$PLAN" "$dep")"
    dh="${dh:+$dh,}$hp"
  done < <(printf '%s\n' "$UNITS" | awk -F '\t' -v u="$unit" '$1 == u { print $3 }' | tr ',' '\n')
  dn="$(printf '%s\n' "$UNITS" | conduct_dependents "$unit" | tr '\n' ',')"; dn="${dn%,}"
  vc="$(git -C "$REPO_DIR" show "$ORIGIN_MAIN:.agent-farm/farm.env" 2>/dev/null | conduct_env_value FARM_VERIFY_CMD)" || vc=""
  for f in "$ud"/findings-*.md; do
    k="${f##*/findings-}"; k="${k%.md}"
    if [[ "$k" =~ ^[0-9]{1,9}$ ]] && (( 10#$k > n )); then n=$((10#$k)); fl="$f"; fi
  done
  [[ ! -f "$ud/answer.txt" ]] || an="$ud/answer.txt"
  bp="$(conduct_branch_prefix "$PLAN" "$unit")"
  # PD19: the fixed prompt from the plugin, no repository override and no FARM.md.
  prompt="$(cat "$FARM_DIR/defaults/prompts/unit.md")" || die 2 "cannot read $FARM_DIR/defaults/prompts/unit.md"
  prompt="$prompt

<conduct_context>
PLAN: $PLAN
UNIT: $unit
UNIT_TITLE: $(printf '%s\n' "$UNITS" | awk -F '\t' -v u="$unit" '$1 == u && $2 != "" { print $2; f = 1 } END { if (!f) print "none" }')
MAIN_BRANCH: ${MAIN_LABEL#origin/}
WORKTREE: $wt
BRANCH_PREFIX: $bp
HANDOFF_OUT: $(conduct_handoff_path "$PLAN" "$unit")
HANDOFF_BRANCH: ${bp}handoff
DEPENDENCY_HANDOFFS: ${dh:-none}
DEPENDENT_UNITS: ${dn:-none}
VERIFY_CMD: ${vc:-none}
LONG_WAIT: $([[ "$CONDUCT_LONG_WAIT" == 1 ]] && echo yes || echo no)
MODE: $mode
FINDINGS_FILE: $fl
OPERATOR_ANSWER_FILE: $an
</conduct_context>"
  printf 'doing\n' > "$ud/state"
  conduct_counter_bump "$ud" attempts || die 2 "cannot count the attempt in $ud/attempts"
  # The evidence baseline for conduct_refine_ended. A resume continues the interrupted session,
  # so it keeps that session's baseline. A list gh cannot give leaves no count (not evidence).
  if [[ "$mode" != resume || ! -e "$ud/handoff_sha_before" ]]; then
    remote_sha "${bp}handoff" > "$ud/handoff_sha_before"
    rm -f "$ud/merged_before"
    if prs="$(conduct_find_prs "$PLAN" "$unit")"; then
      printf '%s' "$prs" | jq '[.[] | select(.state == "MERGED")] | length' > "$ud/merged_before"
    else log "cannot list the pull requests of $bp: no merged count at session start"; fi
  fi
  sid="$(head -1 "$ud/session_id" 2>/dev/null)" || sid=""
  [[ "$(conduct_launch_mode "$mode" "$CONDUCT_RESUME_SESSIONS" "$sid")" != resume ]] || rid=("$sid")
  # A run with no init event must not leave the previous id behind.
  rm -f "$ud/session_id"
  log="$CDIR/logs/conduct-$slug-lead-$(date -u +%Y%m%dT%H%M%SZ).log"
  CONDUCT_UNIT_DIR="$ud"
  t0="$(date +%s)"
  if ! conduct_launch lead "$wt" "$prompt" "$log" ${rid[@]+"${rid[@]}"}; then
    [[ "$CONDUCT_GUARD_PROOF" != settings-tampered ]] || { echo settings-tampered; return 0; }
    die 2 "cannot launch the lead session"
  fi
  # Final review I1: no end epoch yet. A conductor killed before the rewrite below leaves it for the next run.
  printf 'lead\t%s\t%s\t\n' "$log" "$t0" > "$ud/.session_meta"
  wait "$CONDUCT_SESSION_PID" || rc=$?
  _conduct_stop_watchdog
  trap - EXIT INT TERM
  rm -f "$ud/pid"
  printf 'lead\t%s\t%s\t%s\n' "$log" "$t0" "$(date +%s)" > "$ud/.session_meta"
  sid="$(jq -R -r -n 'first(inputs | fromjson? | select(type == "object" and .type == "system" and .subtype == "init") | .session_id | strings)' "$log" 2>/dev/null)" || sid=""
  if [[ "$sid" =~ ^[0-9a-f-]{36}$ ]]; then printf '%s\n' "$sid" > "$ud/session_id"; fi
  if [[ "$CONDUCT_GUARD_PROOF" == stop ]]; then echo guard-not-loaded; return 0; fi
  # An open pull request from the handoff branch ends the classification. A gh failure is not
  # "no pull request": it falls through to the run-log classifier.
  if prs="$(cd "$REPO_DIR" && bounded 60 gh pr list -R "$FARM_REPO_SLUG" --state all --search "head:$bp" --limit 200 \
       --json number,headRefName,state,files,headRefOid 2>/dev/null)"; then
    cnt="$(printf '%s' "$prs" | jq --arg b "${bp}handoff" '[.[]? | select(type == "object" and .headRefName == $b and .state == "OPEN")] | length' 2>/dev/null)" || cnt=""
    if [[ "$cnt" =~ ^[0-9]+$ ]]; then
      if (( cnt > 0 )); then echo ended; return 0; fi
    else log "cannot read the pull request list of $bp: classifying the run log"; fi
  else log "gh pr list failed for $bp: classifying the run log"; fi
  conduct_classify_log "$log" "$rc"
}

# <run log> <session exit code>. stdout: limit or transient (the farm's limit or backoff gate set,
# never shortened: conduct_gate_keep_decide), else ended.
conduct_classify_log() {
  local log="$1" rc="$2" now res o b a gf
  # The runner's classifier (bin/farm-runner.sh), in one child; PD22 reads the gate around its setter.
  now="$(date +%s)"
  res="$(farm_lib_sh '
    t="$(run_log_tail "$1" 200000)"; o=ended; b=""; a=""
    if output_hit_limit "$t"; then o=limit; b="$(_gate_until)"; set_limit_gate_from_run "$t" "$1"; a="$(_gate_until)"
    elif output_transient_infra_error "$t" "$2"; then o=transient; b="$(_gate_until)"; set_infra_backoff_gate; a="$(_gate_until)"; fi
    printf "%s\n%s\n%s\n%s\n" "$o" "$b" "$a" "$GATE_FILE"' "$log" "$rc")" || { log "run-log classifier failed: $log"; res=""; }
  o="$(sed -n 1p <<<"$res")"; b="$(sed -n 2p <<<"$res")"; a="$(sed -n 3p <<<"$res")"; gf="$(sed -n 4p <<<"$res")"
  case "$o" in limit|transient) ;; *) echo ended; return 0 ;; esac
  _conduct_keep_gate "$b" "$a" "$gf" "$now"
  echo "$o"
}

# <gate before> <gate after> <gate file> <now>: a longer gate that was there before a setter ran
# is put back (conduct_gate_keep_decide).
_conduct_keep_gate() {
  local keep t
  keep="$(conduct_gate_keep_decide "$1" "$2" "$4")"
  if [[ -n "$keep" && "$keep" != "$2" && -n "$3" ]]; then
    if t="$(mktemp "$(dirname "$3")/.limit-until.XXXXXX")" && echo "$keep" > "$t" && mv -f "$t" "$3"; then
      log "kept the longer limit gate $keep"
    else rm -f "${t:-}"; log "cannot restore the limit gate $keep in $3"; fi
  fi
}

# A gh or git outage outside a run log (outcome transient): the farm's infra backoff gate, set in
# a child as the run-log classifier does, so conduct_wait_gate waits it out and three quick
# outages cannot reach cap-interruption in seconds. Nothing on stdout.
conduct_outage_backoff() {
  local now res
  now="$(date +%s)"
  res="$(farm_lib_sh 'b="$(_gate_until)"; set_infra_backoff_gate; printf "%s\n%s\n%s\n" "$b" "$(_gate_until)" "$GATE_FILE"')" \
    || { log "cannot set the infra backoff gate"; return 0; }
  _conduct_keep_gate "$(sed -n 1p <<<"$res")" "$(sed -n 2p <<<"$res")" "$(sed -n 3p <<<"$res")" "$now"
}

# <branch>. stdout: origin's tip of refs/heads/<branch> (git ls-remote), or nothing.
remote_sha() {
  local s
  s="$(bounded 60 git -C "$REPO_DIR" ls-remote origin "refs/heads/$1" 2>/dev/null \
    | awk -F '\t' -v r="refs/heads/$1" '$2 == r { print $1; exit }')" || s=""
  [[ ! "$s" =~ ^[0-9a-f]{40}$ ]] || printf '%s\n' "$s"
}

# <plan> <unit>. stdout: JSON array of the pull requests (all states) whose head branch starts
# with the unit's prefix (gh's head: search is not exact, so filtered again) and lives in this
# repository (ruling R4: isCrossRepository false; a fork's branch of the same name is not the
# unit's); their numbers go to the unit's prs file. rc 1, prs file unchanged, when gh fails,
# answers no array, or answers a full page of 200 (more may exist).
conduct_find_prs() {
  local bp ud out
  [[ "${PLAN:-}" == "$1" && -n "${ORIGIN_MAIN:-}" ]] || setup "$1"
  printf '%s\n' "$UNITS" | cut -f1 | grep -Fx -- "$2" >/dev/null || die 1 "unit $2 is not in $PLAN"
  bp="$(conduct_branch_prefix "$PLAN" "$2")"; ud="$CDIR/$KEY/$(conduct_unit_slug "$2")"
  out="$(cd "$REPO_DIR" && bounded 60 gh pr list -R "$FARM_REPO_SLUG" --state all --search "head:$bp" --limit 200 \
    --json number,headRefName,state,files,headRefOid,baseRefName,isCrossRepository 2>/dev/null)" || return 1
  # A full page (--limit 200) may hide more pull requests: the list is unknown (fail closed).
  out="$(printf '%s' "$out" | jq -c --arg p "$bp" 'if type == "array" and length < 200 then [.[] | select(type == "object"
    and .isCrossRepository == false and (.headRefName | type) == "string" and (.headRefName | startswith($p)))]
    else error end' 2>/dev/null)" || return 1
  mkdir -p "$ud"
  printf '%s' "$out" | jq -r '.[].number | select(type == "number") | tostring' > "$ud/prs.tmp.$$" \
    && mv -f "$ud/prs.tmp.$$" "$ud/prs" || { rm -f "$ud/prs.tmp.$$"; return 1; }
  printf '%s\n' "$out"
}

# <plan> <unit> [<conduct_find_prs JSON>]. stdout: conduct_other_open_decide on the open pull
# requests under the prefix other than the handoff one, against the guard's protected globs at
# origin's tip (_guard_policy_globs in a child, ruling R1; globs that cannot be built count every
# such pull request as protected). unknown, rc 1, when the list cannot be read.
conduct_other_open() {
  local js="${3:-}" g grc=0
  [[ "${PLAN:-}" == "$1" && -n "${ORIGIN_MAIN:-}" ]] || setup "$1"
  if [[ $# -lt 3 ]]; then js="$(conduct_find_prs "$PLAN" "$2")" || { echo unknown; return 1; }; fi
  g="$(policy_globs)" || grc=$?
  printf '%s' "$js" | conduct_other_open_decide "$(conduct_branch_prefix "$PLAN" "$2")handoff" \
    "$([[ "$grc" == 0 ]] && echo 1 || echo 0)" "$g"
}

# <plan> <unit>, after conduct_run_lead said ended. Re-reads origin (setup). stdout, first match:
# shipped-unreviewed (the handoff is on origin/<main> without a review or adoption record),
# awaiting-merge (conduct_other_open: protected), handoff (an open pull request from the handoff
# branch), else conduct_progress_decide against the baseline conduct_run_lead recorded and the
# first guard denial in the session's run log (.session_meta), kept in guard_denial for the stop
# reason when the outcome is guard-blocked. A list gh cannot give is transient (the protected check
# cannot run).
conduct_refine_ended() {
  local unit="$2" ud bp prs oo ma="" mb="" sb="" lg gq="" o
  setup "$1"
  printf '%s\n' "$UNITS" | cut -f1 | grep -Fx -- "$unit" >/dev/null || die 1 "unit $unit is not in $PLAN"
  ud="$CDIR/$KEY/$(conduct_unit_slug "$unit")"; bp="$(conduct_branch_prefix "$PLAN" "$unit")"
  if git -C "$REPO_DIR" cat-file -e "$ORIGIN_MAIN:$(conduct_handoff_path "$PLAN" "$unit")" 2>/dev/null; then
    case ",$SHIPPED" in *",$unit,"*) ;; *) echo shipped-unreviewed; return 0 ;; esac
  fi
  if prs="$(conduct_find_prs "$PLAN" "$unit")"; then
    oo="$(conduct_other_open "$PLAN" "$unit" "$prs")" || oo=unknown
    case "$oo" in protected*) echo awaiting-merge; return 0 ;; esac
    if [[ "$(printf '%s' "$prs" | jq --arg b "${bp}handoff" '[.[] | select(.headRefName == $b and .state == "OPEN")] | length' 2>/dev/null)" =~ ^[1-9] ]]; then
      echo handoff; return 0
    fi
    ma="$(printf '%s' "$prs" | jq '[.[] | select(.state == "MERGED")] | length' 2>/dev/null)" || ma=""
  else
    # Fail closed: an unlisted pull request may be protected. An outage costs an interruption, not rework.
    log "cannot list the pull requests of $bp: transient"; conduct_outage_backoff; echo transient; return 0
  fi
  [[ ! -f "$ud/merged_before" ]] || mb="$(head -1 "$ud/merged_before")"
  [[ ! -f "$ud/handoff_sha_before" ]] || sb="$(head -1 "$ud/handoff_sha_before")"
  lg="$(cut -f2 "$ud/.session_meta" 2>/dev/null)" || lg=""
  [[ ! -f "$lg" ]] || gq="$(conduct_first_denial < "$lg")"
  o="$(conduct_progress_decide "$mb" "$ma" "$sb" "$(remote_sha "${bp}handoff")" "${gq:+1}")"
  # The stop reason's quote: .session_meta is gone when _conduct_run_stop runs.
  [[ "$o" != guard-blocked ]] || _conduct_put "$ud" guard_denial "$gq" || log "cannot write $ud/guard_denial"
  echo "$o"
}

# <plan> <unit> <phase: one|two>. Validates the unit's handoff pull request (spec 4.5 steps 2
# and 4): exactly one open pull request from HANDOFF_BRANCH in this repository, into origin's
# main branch, whose headRefOid is origin's tip of that branch (git ls-remote); its files are
# exactly [HANDOFF_OUT], and `git diff --no-renames` from origin's main tip to its head is exactly
# one A or M of HANDOFF_OUT, on exactly one merge base and with no merge commit (ruling R6); no other pull request under BRANCH_PREFIX is open; and the handoff as
# pushed (git show <head sha>:<path> after a fetch, never the work tree) passes
# conduct_handoff_validate <phase>. stdout: ok <pr number> <head sha>, or invalid <first reason>
# (its code, or a conduct_handoff_validate line without "HANDOFF: ") with every reason written to the unit's next findings-<n>.md (outcome handoff-invalid).
conduct_check_handoff_pr() {
  local unit="$2" ph="$3" ud bp hb hb2 gm hout prs pr num sha tip f gd oo text deps out n=0 k r="" t nl=$'\n'
  case "$ph" in one|two) ;; *) die 1 "bad phase: $ph" ;; esac
  [[ "${PLAN:-}" == "$1" && -n "${ORIGIN_MAIN:-}" ]] || setup "$1"
  printf '%s\n' "$UNITS" | cut -f1 | grep -Fx -- "$unit" >/dev/null || die 1 "unit $unit is not in $PLAN"
  ud="$CDIR/$KEY/$(conduct_unit_slug "$unit")"; bp="$(conduct_branch_prefix "$PLAN" "$unit")"
  hb="${bp}handoff"; hout="$(conduct_handoff_path "$PLAN" "$unit")"
  if ! prs="$(conduct_find_prs "$PLAN" "$unit")"; then
    r="no-pr-list -- gh cannot list the pull requests under $bp$nl"
  else
    pr="$(printf '%s' "$prs" | jq -c --arg b "$hb" '[.[] | select(.headRefName == $b and .state == "OPEN")]
      | if length == 1 then .[0] else error end' 2>/dev/null)" || pr=""
    num="$(printf '%s' "$pr" | jq -r '.number | numbers | tostring' 2>/dev/null)" || num=""
    sha="$(printf '%s' "$pr" | jq -r '.headRefOid | strings' 2>/dev/null)" || sha=""
    if [[ ! "$num" =~ ^[0-9]{1,10}$ ]]; then
      r="no-handoff-pr -- not exactly one open pull request from $hb in this repository$nl"
    elif [[ "$(printf '%s' "$pr" | jq -r '.baseRefName' 2>/dev/null)" != "${MAIN_LABEL#origin/}" ]]; then
      r="base -- pull request #$num does not target ${MAIN_LABEL#origin/}$nl"
    elif tip="$(remote_sha "$hb")"; [[ ! "$sha" =~ ^[0-9a-f]{40}$ || "$sha" != "$tip" ]]; then
      r="head-mismatch -- pull request #$num reports head ${sha:-none}, origin's $hb is at ${tip:-none}$nl"
    else
      bounded 120 "${NOHOOK[@]}" git -C "$REPO_DIR" fetch origin --prune --quiet 2>/dev/null || log "git fetch failed before reading $sha"
      # Lead ruling R6: with several merge bases or a merge commit on the branch, GitHub's squash
      # can differ from the one-base diff below. Each check fails closed on a git failure.
      hb2="$("${NOHOOK[@]}" git -C "$REPO_DIR" merge-base --all "$ORIGIN_MAIN" "$sha" 2>/dev/null)" || hb2=""
      [[ "$hb2" =~ ^[0-9a-f]{40}$ ]] \
        || r+="history -- pull request #$num must have exactly one merge base with ${MAIN_LABEL#origin/}; merge bases: $(printf '%s' "${hb2:-none or git failed}" | tr '\n' ' ')$nl"
      gm="$("${NOHOOK[@]}" git -C "$REPO_DIR" rev-list --merges "$ORIGIN_MAIN..$sha" 2>/dev/null && echo .)" || gm=""
      if [[ "$gm" != . ]]; then
        if [[ -n "$gm" ]]; then gm="$(printf '%s' "${gm%.}" | tr '\n' ' ')"; else gm="unknown (git rev-list failed)"; fi
        r+="history -- pull request #$num must have no merge commit on $hb; merge commits: $gm$nl"
      fi
      f="$(printf '%s' "$pr" | jq -r '[.files[]?.path | strings] | join(", ")' 2>/dev/null)" || f=""
      [[ "$(printf '%s' "$pr" | jq -c '[.files[]?.path]' 2>/dev/null)" == "$(jq -cn --arg h "$hout" '[$h]')" ]] \
        || r+="files -- pull request #$num must change only $hout; it changes: ${f:-unknown}$nl"
      # Security review F1: gh names a renamed file by its new path only, so a protected file moved
      # onto HANDOFF_OUT passes the list above. git without rename detection names both sides: exactly
      # one entry, A or M, HANDOFF_OUT. The trailing "." survives only if git succeeded (fail closed).
      gd="$("${NOHOOK[@]}" git -C "$REPO_DIR" diff --no-renames --no-ext-diff --name-status -z "$ORIGIN_MAIN...$sha" 2>/dev/null \
        | tr '\0' '\n' && echo .)" || gd=""
      if [[ "$gd" != "A$nl$hout$nl." && "$gd" != "M$nl$hout$nl." ]]; then
        gd="$("${NOHOOK[@]}" git -C "$REPO_DIR" diff --no-renames --no-ext-diff --name-status "$ORIGIN_MAIN...$sha" 2>/dev/null \
          | awk -F '\t' '{ printf "%s%s %s", s, $1, $2; s = ", " }')" || gd=""
        r+="files -- pull request #$num must change only $hout; git (no rename detection) shows: ${gd:-unknown (git diff failed)}$nl"
      fi
      oo="$(conduct_other_open "$PLAN" "$unit" "$prs")" || oo=unknown
      [[ "$oo" == none ]] || r+="other-pr-open -- open pull requests under $bp: $(printf '%s' "${oo#* }" | sed 's/[0-9][0-9]*/#&/g')$nl"
      if text="$(git -C "$REPO_DIR" show "$sha:$hout" 2>/dev/null)"; then
        deps="$(printf '%s\n' "$UNITS" | conduct_dependents "$unit" | tr '\n' ',')"
        if ! out="$(printf '%s\n' "$text" | conduct_handoff_validate "$ph" "${deps%,}")"; then
          k="$r"
          while IFS= read -r t; do [[ "$t" != "HANDOFF: "?* ]] || r+="${t#HANDOFF: }$nl"; done <<<"$out"
          # Fail closed: a validator that fails without naming a reason (awk failed) is not a pass.
          [[ "$r" != "$k" ]] || r+="handoff-unvalidated -- the handoff validator failed without a reason$nl"
        fi
      else r+="no-handoff-file -- $hout is not in commit $sha$nl"; fi
    fi
  fi
  if [[ -z "$r" ]]; then echo "ok $num $sha"; return 0; fi
  for f in "$ud"/findings-*.md; do
    k="${f##*/findings-}"; k="${k%.md}"
    if [[ "$k" =~ ^[0-9]{1,9}$ ]] && (( 10#$k > n )); then n=$((10#$k)); fi
  done
  mkdir -p "$ud"; f="$ud/findings-$((n + 1)).md"
  { printf '# Handoff pull request invalid (phase %s)\n\n' "$ph"; printf '%s' "$r" | sed 's/^/- /'; } > "$f.tmp.$$" \
    && mv -f "$f.tmp.$$" "$f" || { rm -f "$f.tmp.$$"; log "cannot write $f"; }
  t="${r%%"$nl"*}"; echo "invalid ${t%% -- *}"
}

# <plan> <unit> <pr> <head sha>, after the lead has exited (spec 4.5 step 3). One review session
# through conduct_launch (role review: guard proof, .claude/ byte check, apiKeySource none), in
# its own fresh work tree detached at origin's main tip (setup re-reads it), never the lead's. The
# verdict directory (mktemp -d /tmp/farm-verdict.XXXXXX) and the nonce are made here and passed
# only in the prompt (PD24); the directory is removed on every path. attempts is bumped before the
# launch. stdout: conduct_verdict_parse's line (a reject copies FINDINGS_FILE to the unit's next
# findings-<n>.md), else limit, else transient (the lead's run-log classifier, without the
# open-handoff rule), else review-noverdict; guard-not-loaded and settings-tampered as for the lead.
conduct_run_review() {
  local unit="$2" pr="$3" hs="$4" slug ud wt sb tpl nonce vd vf ff prompt log rc=0 out bp n=0 k f t0
  setup "$1"
  printf '%s\n' "$UNITS" | cut -f1 | grep -Fx -- "$unit" >/dev/null || die 1 "unit $unit is not in $PLAN"
  [[ "$pr" =~ ^[1-9][0-9]{0,9}$ ]] || die 1 "bad pull request number: $pr"
  [[ "$hs" =~ ^[0-9a-f]{40}$ ]] || die 1 "bad head sha: $hs"
  case "$CONDUCT_GUARD_MODE" in settings|plugin-dir) ;; *)
    log "unknown CONDUCT_GUARD_MODE $CONDUCT_GUARD_MODE (settings or plugin-dir): not launching"
    echo guard-not-loaded; return 0 ;;
  esac
  slug="$(conduct_unit_slug "$unit")"; ud="$CDIR/$KEY/$slug"; mkdir -p "$ud" "$CDIR/logs"
  sb="$(head -1 "$ud/start_sha" 2>/dev/null)" || sb=""
  [[ "$sb" =~ ^[0-9a-f]{40}$ ]] || die 2 "$ud/start_sha holds no commit sha: no range to review"
  # PD19/PD25: the fixed prompt from the plugin, no repository override.
  tpl="$(cat "$FARM_DIR/defaults/prompts/unit-review.md")" || die 2 "cannot read $FARM_DIR/defaults/prompts/unit-review.md"
  bp="$(conduct_branch_prefix "$PLAN" "$unit")"
  conduct_counter_bump "$ud" attempts || die 2 "cannot count the attempt in $ud/attempts"
  wt="$REPO_DIR/.farm-worktrees/conduct-review-$KEY-$slug"
  rm -rf "$wt"; git -C "$REPO_DIR" worktree prune 2>/dev/null || true
  nohook git -C "$REPO_DIR" worktree add --detach "$wt" "$ORIGIN_MAIN" >&2 || die 2 "cannot create the work tree $wt"
  nonce="$(command od -An -N16 -tx1 /dev/urandom | tr -d ' \n')" || nonce=""
  [[ "$nonce" =~ ^[0-9a-f]{32}$ ]] || die 2 "cannot read a nonce from /dev/urandom"
  vd="$(mktemp -d /tmp/farm-verdict.XXXXXX)" || die 2 "cannot create a verdict directory in /tmp"
  CONDUCT_VERDICT_DIR="$vd"
  trap _conduct_rm_verdict EXIT
  vf="$vd/verdict.json"; ff="$vd/findings.md"
  prompt="$tpl

<conduct_context>
PLAN: $PLAN
UNIT: $unit
UNIT_TITLE: $(printf '%s\n' "$UNITS" | awk -F '\t' -v u="$unit" '$1 == u && $2 != "" { print $2; f = 1 } END { if (!f) print "none" }')
MAIN_BRANCH: ${MAIN_LABEL#origin/}
WORKTREE: $wt
RANGE: $sb..$ORIGIN_MAIN
HANDOFF_PR: $pr
HANDOFF_HEAD: $hs
HANDOFF_OUT: $(conduct_handoff_path "$PLAN" "$unit")
HANDOFF_BRANCH: ${bp}handoff
FINDINGS_FILE: $ff
VERDICT_FILE: $vf
NONCE: $nonce
</conduct_context>"
  log="$CDIR/logs/conduct-$slug-review-$(date -u +%Y%m%dT%H%M%SZ).log"
  printf '%s\n' "$log" > "$ud/review_log"   # for the review record (conduct_merge_handoff)
  CONDUCT_UNIT_DIR="$ud"
  t0="$(date +%s)"
  if ! conduct_launch review "$wt" "$prompt" "$log"; then
    out=launch-failed; [[ "$CONDUCT_GUARD_PROOF" != settings-tampered ]] || out=settings-tampered
  else
    printf 'review\t%s\t%s\t\n' "$log" "$t0" > "$ud/.session_meta"   # final review I1, as for the lead
    wait "$CONDUCT_SESSION_PID" || rc=$?
    _conduct_stop_watchdog
    rm -f "$ud/pid"
    printf 'review\t%s\t%s\t%s\n' "$log" "$t0" "$(date +%s)" > "$ud/.session_meta"
    if [[ "$CONDUCT_GUARD_PROOF" == stop ]]; then out=guard-not-loaded
    # A verdict that parses wins. Bounded read; a symlink is not the reviewer's file.
    elif [[ -f "$vf" && ! -L "$vf" ]] && out="$(head -c 65536 "$vf" | conduct_verdict_parse "$nonce" "$unit")"; then
      if [[ "$out" == reject* ]]; then
        for f in "$ud"/findings-*.md; do
          k="${f##*/findings-}"; k="${k%.md}"
          if [[ "$k" =~ ^[0-9]{1,9}$ ]] && (( 10#$k > n )); then n=$((10#$k)); fi
        done
        f="$ud/findings-$((n + 1)).md"
        { if [[ -f "$ff" && ! -L "$ff" ]]; then head -c 1048576 "$ff"
          else echo "- The review rejected the unit without a findings file."; fi; } > "$f.tmp.$$" \
          && mv -f "$f.tmp.$$" "$f" || { rm -f "$f.tmp.$$"; log "cannot write $f"; }
      fi
    else
      out="$(conduct_classify_log "$log" "$rc")"
      case "$out" in limit|transient) ;; *) out=review-noverdict ;; esac
    fi
  fi
  trap - EXIT INT TERM
  rm -rf "$vd"; CONDUCT_VERDICT_DIR=""
  nohook git -C "$REPO_DIR" worktree remove --force "$wt" >/dev/null 2>&1 || rm -rf "$wt"
  git -C "$REPO_DIR" worktree prune 2>/dev/null || true
  [[ "$out" != launch-failed ]] || die 2 "cannot launch the review session"
  echo "$out"
}

# <unit dir> <title> <text>: the unit's next findings-<n>.md (temp file, then mv).
conduct_add_findings() {
  local n=0 k f
  for f in "$1"/findings-*.md; do
    k="${f##*/findings-}"; k="${k%.md}"
    if [[ "$k" =~ ^[0-9]{1,9}$ ]] && (( 10#$k > n )); then n=$((10#$k)); fi
  done
  mkdir -p "$1"; f="$1/findings-$((n + 1)).md"
  { printf '# %s\n\n' "$2"; printf '%s\n' "$3"; } > "$f.tmp.$$" && mv -f "$f.tmp.$$" "$f" \
    || { rm -f "$f.tmp.$$"; log "cannot write $f"; }
}

# <unit dir> <reason>: outcome merge-failed (a stop, never a rework: a gh or git outage must not
# spend the rework round), the reason logged and written to the findings.
_conduct_merge_failed() {
  log "merge-failed ($PLAN): $2"
  conduct_add_findings "$1" "Conductor merge failed" "- merge-failed -- $2"
  echo merge-failed
}

# <decision> <clean accept 0|1> <unit dir>: the outcome of a decision other than merge or wait. A
# rework is the reviewer's (review-reject) unless the verdict was a clean accept (handoff-invalid).
_conduct_merge_outcome() {
  case "$1" in
    await-merge) echo awaiting-merge ;;
    rework) if [[ "$2" == 1 ]]; then echo handoff-invalid; else echo review-reject; fi ;;
    *) _conduct_merge_failed "$3" "conduct_merge_decide answered $1" ;;
  esac
}

# <plan> <unit> <pr> <verdict line: accept|reject high medium low head> (spec 4.5 steps 4 and 5).
# The conductor's own merge: the only merge of a protected path in the system, run as plain bash
# outside the guard hook, so the checks here are its whole gate. Every gh or git failure, unreadable
# answer or unknown word is no merge. Cheap checks first: conduct_other_open; for a clean accept, the
# handoff branch tip on origin == the verdict's head, then conduct_check_handoff_pr two, which must
# answer ok <pr> <verdict head> (headRefOid == tip == verdict head, files == [HANDOFF_OUT]). Then
# conduct_run_verify pre-merge on origin's main tip (PD16), then gh pr checks --required polled
# (PD27, R3). conduct_merge_decide is asked after each step; its first answer other than merge ends
# the run. Before the merge the tip and the other pull requests are read once more; the merge is
# `gh pr merge <pr> --squash --match-head-commit <verdict head>` (never --admin or --auto), confirmed
# by state MERGED at headRefOid == the verdict head and the reviewed handoff blob on origin's main tip (ls-remote). Then the review
# record, then the unit-shipped event (the handoff's "Operator actions pending" text as the reason),
# then both work trees go; a record that cannot be written is merge-failed, with no event. stdout: merged, review-reject, handoff-invalid (findings written),
# awaiting-merge, checks-timeout or merge-failed.
conduct_merge_handoff() {
  local unit="$2" pr="$3" re='^(accept|reject) ([0-9]{1,10}) ([0-9]{1,10}) ([0-9]{1,10}) ([0-9a-f]{40})$'
  local v h m l vh slug ud bp hb hout oo ow hs=ok d clean=0 tip ph cmd vo vlog cj c t0 st main nt b1 b2 rlog rid wt text
  setup "$1"
  printf '%s\n' "$UNITS" | cut -f1 | grep -Fx -- "$unit" >/dev/null || die 1 "unit $unit is not in $PLAN"
  [[ "$pr" =~ ^[1-9][0-9]{0,9}$ ]] || die 1 "bad pull request number: $pr"
  [[ "$4" =~ $re ]] || die 1 "bad verdict line: $4"
  v="${BASH_REMATCH[1]}"; h="${BASH_REMATCH[2]}"; m="${BASH_REMATCH[3]}"; l="${BASH_REMATCH[4]}"; vh="${BASH_REMATCH[5]}"
  slug="$(conduct_unit_slug "$unit")"; ud="$CDIR/$KEY/$slug"; mkdir -p "$ud"
  bp="$(conduct_branch_prefix "$PLAN" "$unit")"; hb="${bp}handoff"; hout="$(conduct_handoff_path "$PLAN" "$unit")"
  oo="$(conduct_other_open "$PLAN" "$unit")" || { _conduct_merge_failed "$ud" "cannot list the pull requests under $bp"; return 0; }
  ow="${oo%% *}"
  [[ "$v" == accept ]] && (( 10#$h == 0 && 10#$m == 0 )) && clean=1
  # A rejected verdict is not re-validated: phase two's findings would shadow the reviewer's.
  if [[ "$clean" == 1 && "$ow" != protected ]]; then
    tip="$(remote_sha "$hb")"
    [[ -n "$tip" ]] || { _conduct_merge_failed "$ud" "git ls-remote gives no tip for $hb"; return 0; }
    if [[ "$tip" != "$vh" ]]; then
      hs=invalid
      conduct_add_findings "$ud" "Handoff pull request invalid (merge)" "- head-moved -- head moved after the review: the review named $vh, origin's $hb is at $tip"
    else
      # A check that dies (rc != 0, no answer) is no answer: merge-failed, never a merge.
      ph="$(conduct_check_handoff_pr "$PLAN" "$unit" two)" || ph=""
      case "$ph" in
        "ok $pr $vh") ;;
        "") _conduct_merge_failed "$ud" "the phase-two check of #$pr gave no answer"; return 0 ;;
        "invalid no-pr-list") _conduct_merge_failed "$ud" "gh cannot list the pull requests under $bp (phase two)"; return 0 ;;
        "invalid head-mismatch")
          [[ -n "$(remote_sha "$hb")" ]] || { _conduct_merge_failed "$ud" "git ls-remote gives no tip for $hb (phase two)"; return 0; }
          hs=invalid ;;
        invalid\ *) hs=invalid ;;
        *) hs=invalid
           conduct_add_findings "$ud" "Handoff pull request invalid (merge)" "- head-moved -- phase two answered '$ph', the review named pull request #$pr at $vh" ;;
      esac
    fi
    if [[ "$hs" == ok && "$ow" == open ]]; then
      conduct_add_findings "$ud" "Handoff pull request invalid (merge)" "- other-pr-open -- open pull requests under $bp: ${oo#* }"
    fi
  fi
  d="$(conduct_merge_decide "$v" "$h" "$m" "$hs" "$ow" pass pass)"
  [[ "$d" == merge ]] || { _conduct_merge_outcome "$d" "$clean" "$ud"; return 0; }
  # PD16: the unit's merged code must leave main green. The command is read from main, never sourced.
  cmd="$(git -C "$REPO_DIR" show "$ORIGIN_MAIN:.agent-farm/farm.env" 2>/dev/null | conduct_env_value FARM_VERIFY_CMD)" || cmd=""
  if [[ -z "$cmd" ]]; then vo=fail; vlog="FARM_VERIFY_CMD is not set in .agent-farm/farm.env on $MAIN_LABEL"
  else
    # A verify run that dies gives no word: conduct_merge_decide then answers stop:invalid-state (merge-failed).
    vo="$(conduct_run_verify "$PLAN" "$unit" pre-merge "$cmd")" || vo=""
    # shellcheck disable=SC2012  # timestamped names of our own; the newest is this run's
    vlog="$(ls -t "$CDIR/logs/conduct-$slug-verify-"*.log 2>/dev/null | head -1)" || vlog=""
    [[ -z "$vlog" ]] || vlog="log $vlog, last lines:
$(tail -20 "$vlog" 2>/dev/null)"
  fi
  d="$(conduct_merge_decide "$v" "$h" "$m" "$hs" "$ow" "$vo" pass)"
  if [[ "$d" != merge ]]; then
    [[ "$d" != rework ]] || conduct_add_findings "$ud" "Pre-merge verify $vo on $MAIN_LABEL" "- verify-$vo -- $vlog"
    _conduct_merge_outcome "$d" "$clean" "$ud"; return 0
  fi
  # Review Focus 2: none and undetermined wait like pending, then end as checks-timeout.
  t0=$SECONDS
  while :; do
    cj="$(cd "$REPO_DIR" && bounded 60 gh pr checks "$pr" -R "$FARM_REPO_SLUG" --required --json name,bucket 2>/dev/null)" || true
    c="$(conduct_checks_decide "$cj")"
    d="$(conduct_merge_decide "$v" "$h" "$m" "$hs" "$ow" "$vo" "$c")"
    [[ "$d" == wait ]] || break
    if (( SECONDS - t0 >= 10#$CONDUCT_CHECKS_TIMEOUT_SECONDS )); then
      log "required checks of #$pr still $c after ${CONDUCT_CHECKS_TIMEOUT_SECONDS}s: checks-timeout ($PLAN#$unit)"
      echo checks-timeout; return 0
    fi
    sleep "$CONDUCT_CHECKS_POLL_SECONDS"
  done
  if [[ "$d" != merge ]]; then
    [[ "$d" != rework ]] || conduct_add_findings "$ud" "Required checks failed on #$pr" \
      "- checks-fail -- $(printf '%s' "$cj" | jq -r '[.[]? | select(.bucket == "fail" or .bucket == "skipping" or .bucket == "cancel") | .name | strings] | join(", ")' 2>/dev/null)"
    _conduct_merge_outcome "$d" "$clean" "$ud"; return 0
  fi
  # Review Focus 3, once more right before the merge: the branch may have moved during the wait.
  tip="$(remote_sha "$hb")"
  [[ -n "$tip" ]] || { _conduct_merge_failed "$ud" "git ls-remote gives no tip for $hb before the merge"; return 0; }
  if [[ "$tip" != "$vh" ]]; then
    conduct_add_findings "$ud" "Handoff pull request invalid (merge)" "- head-moved -- head moved after the review: the review named $vh, origin's $hb is at $tip"
    echo handoff-invalid; return 0
  fi
  oo="$(conduct_other_open "$PLAN" "$unit")" || { _conduct_merge_failed "$ud" "cannot list the pull requests under $bp before the merge"; return 0; }
  ow="${oo%% *}"
  d="$(conduct_merge_decide "$v" "$h" "$m" "$hs" "$ow" "$vo" "$c")"
  if [[ "$d" != merge ]]; then
    [[ "$ow" != open ]] || conduct_add_findings "$ud" "Handoff pull request invalid (merge)" "- other-pr-open -- open pull requests under $bp: ${oo#* }"
    _conduct_merge_outcome "$d" "$clean" "$ud"; return 0
  fi
  # GitHub refuses the merge when the head is no longer the reviewed commit.
  (cd "$REPO_DIR" && bounded 120 gh pr merge "$pr" -R "$FARM_REPO_SLUG" --squash --match-head-commit "$vh") >&2 2>&1 \
    || log "gh pr merge #$pr exited non-zero; reading its state"
  # Merged by someone else at another head (Review Focus 5) is not the reviewed merge.
  st="$(cd "$REPO_DIR" && bounded 60 gh pr view "$pr" -R "$FARM_REPO_SLUG" --json state,headRefOid 2>/dev/null \
    | jq -r '"\(.state | strings) \(.headRefOid | strings)"' 2>/dev/null)" || st=""
  [[ "$st" == "MERGED $vh" ]] || { _conduct_merge_failed "$ud" "pull request #$pr is '${st:-unreadable}' after gh pr merge, not MERGED at $vh"; return 0; }
  bounded 120 "${NOHOOK[@]}" git -C "$REPO_DIR" fetch origin --prune --quiet 2>/dev/null || log "git fetch failed after the merge"
  main="$(origin_main)" || { _conduct_merge_failed "$ud" "cannot read origin's main tip after the merge"; return 0; }
  nt="${main#* }"
  b1="$(git -C "$REPO_DIR" rev-parse -q --verify "$nt:$hout" 2>/dev/null)" || b1=""
  b2="$(git -C "$REPO_DIR" rev-parse -q --verify "$vh:$hout" 2>/dev/null)" || b2=""
  [[ -n "$b1" && "$b1" == "$b2" ]] \
    || { _conduct_merge_failed "$ud" "origin's main tip $nt does not hold the reviewed $hout (from $vh)"; return 0; }
  # The review record first: the unit-shipped event reports a shipped unit.
  rlog="$(head -1 "$ud/review_log" 2>/dev/null)" || rlog=""
  rid=""
  if [[ -n "$rlog" && -f "$rlog" ]]; then
    rid="$(jq -R -r -n 'first(inputs | fromjson? | select(type == "object" and .type == "system" and .subtype == "init") | .session_id | strings)' "$rlog" 2>/dev/null)" || rid=""
  fi
  jq -cn --arg plan "$PLAN" --arg unit "$unit" --arg sb "$(head -1 "$ud/start_sha" 2>/dev/null)" --arg eb "$nt" \
    --arg rid "$rid" --arg v "$v" --argjson h "$((10#$h))" --argjson m "$((10#$m))" --argjson l "$((10#$l))" \
    --arg lp "$rlog" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{plan: $plan, unit: $unit, start_sha: $sb, end_sha: $eb, review_session_id: $rid, verdict: $v,
      high: $h, medium: $m, low: $l, log_path: $lp, ts: $ts}' >> "$CDIR/reviews.jsonl" \
    || { _conduct_merge_failed "$ud" "merged, but the review record cannot be written to $CDIR/reviews.jsonl"; return 0; }
  # shortcut: the section is cut at the next "## " line, fences not tracked; the text only informs the operator.
  text="$(git -C "$REPO_DIR" show "$nt:$hout" 2>/dev/null | awk '/^## / { s = (index($0, "Operator actions pending") > 0); next } s')" || text=""
  conduct_notify unit-shipped "$PLAN" "$unit" "${text:-No operator actions pending were listed.}"
  for wt in "$REPO_DIR/.farm-worktrees/conduct-$KEY-$slug" "$REPO_DIR/.farm-worktrees/conduct-review-$KEY-$slug"; do
    [[ ! -e "$wt" ]] || nohook git -C "$REPO_DIR" worktree remove --force "$wt" >/dev/null 2>&1 || rm -rf "$wt"
  done
  git -C "$REPO_DIR" worktree prune 2>/dev/null || true
  echo merged
}

# ---- farmctl conduct run <plan> <unit> [--answer <text>] (spec 4.5 steps 2 to 5) ----

# <fn> [args]: runs it in a background child, stdout to CONDUCT_STEP_OUT, and waits for it. bash
# runs a trap only after a foreground command ends, but `wait` returns at once, so a TERM reaches
# the conductor while a session runs; the child's own traps (conduct_launch, conduct_run_review)
# never replace the conductor's. A child that fails ends the conductor with its exit code.
conduct_child() {
  local rc=0
  "$@" > "$CONDUCT_STEP_OUT" </dev/null &
  CONDUCT_CHILD=$!
  wait "$CONDUCT_CHILD" || rc=$?
  CONDUCT_CHILD=""
  [[ "$rc" == 0 ]] || exit "$rc"
}

# <plan> <unit> <role> <run log> <start epoch> <end epoch> <outcome> <prs opened> <prs merged>.
# Appends one session line to $CDIR/usage.jsonl (a role "verify" line is a precondition, not a
# session). Wall clock is the conductor's own epochs (spike S2), never duration_ms. The first init
# fingerprint of the unit is kept in <unit dir>/first_fp; a later one that differs sets drift.
conduct_record_usage() {
  local plan="$1" unit="$2" role="$3" log="$4" t0="$5" t1="$6" outcome="$7" po="$8" pm="$9" ud vc fpj fp first drift=false
  [[ -r "$log" ]] || log=/dev/null
  [[ "$t0" =~ ^[0-9]{1,10}$ && "$t1" =~ ^[0-9]{1,10}$ ]] || { t0=0; t1=0; }
  [[ "$po" =~ ^[0-9]{1,10}$ ]] || po=0; [[ "$pm" =~ ^[0-9]{1,10}$ ]] || pm=0
  (( 10#$t1 >= 10#$t0 )) || t1=$t0
  ud="$CDIR/$KEY/$(conduct_unit_slug "$unit")"
  vc="$(git -C "$REPO_DIR" show "$ORIGIN_MAIN:.agent-farm/farm.env" 2>/dev/null | conduct_env_value FARM_VERIFY_CMD)" || vc=""
  fpj="$(conduct_init_fingerprint < "$log")"; fp="$(jq -r '.fp' <<<"$fpj")"
  # Security review L-3: an init event the fingerprint cannot read must not switch drift detection off silently.
  if [[ "$fp" == none && -n "$(jq -R -r -n 'first(inputs | fromjson? | select(type == "object" and .type == "system" and .subtype == "init")) | "init"' < "$log" 2>/dev/null)" ]]; then
    log "the init event in $log cannot be fingerprinted: drift detection skipped for this $role session of $plan#$unit"
  fi
  if [[ "$fp" != none ]]; then
    if first="$(head -1 "$ud/first_fp" 2>/dev/null)" && [[ -n "$first" ]]; then
      [[ "$first" == "$fp" ]] || { drift=true; log "init fingerprint drift in $plan#$unit: first $first, $role session $fp"; }
    else mkdir -p "$ud" && printf '%s\n' "$fp" > "$ud/first_fp" || log "cannot write $ud/first_fp"; fi
  fi
  mkdir -p "$CDIR"
  jq -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg plan "$plan" --arg unit "$unit" --arg role "$role" --arg outcome "$outcome" \
    --argjson wall "$((10#$t1 - 10#$t0))" --argjson bm "$(conduct_usage_by_model < "$log")" --argjson counts "$(conduct_log_counts "$vc" < "$log")" \
    --argjson fpj "$fpj" --argjson po "$((10#$po))" --argjson pm "$((10#$pm))" --argjson drift "$drift" --arg sid "$(conduct_session_id < "$log")" '
    def s(k): [$bm[] | .[k] | numbers | select(. >= 0 and . < 1e15)] | add // 0;
    {ts: $ts, plan: $plan, unit: $unit, role: $role, outcome: $outcome, wall_s: $wall,
     in: s("in"), out: s("out"), cache_read: s("cache_read"), cache_creation: s("cache_creation"), cost_usd: s("cost_usd"),
     by_model: $bm, prs_opened: $po, prs_merged: $pm, fingerprint: $fpj, drift: $drift, session_id: $sid} + $counts' \
    >> "$CDIR/usage.jsonl" || log "cannot append to $CDIR/usage.jsonl"
}

# <unit dir> <outcome> <"opened merged" before the session, or empty>. Records the session a step
# left in <unit dir>/.session_meta (role, log, start epoch, end epoch: no meta, no session, no
# record). A meta without an end epoch is a session that did not end normally (final review I1): wall
# time 0. Empty before counts: no gh call, pull request counts 0. Sets PRC to the after counts
# ("x x" when unread), which the next step reuses as its before counts.
_conduct_record_session() {
  local m="$1/.session_meta" role lg t0 t1 po=0 pm=0 bo bm ao am
  PRC="x x"
  [[ -f "$m" ]] || return 0
  IFS=$'\t' read -r role lg t0 t1 < "$m" || true; rm -f "$m"
  case "$role" in lead|review) ;; *) role=unknown ;; esac
  [[ -n "$t1" ]] || t1="$t0"
  if [[ -n "$3" ]]; then
    PRC="$(_conduct_pr_counts)"
    read -r bo bm <<<"$3"; read -r ao am <<<"$PRC"
    if [[ "$ao $am $bo $bm" =~ ^[0-9]{1,9}\ [0-9]{1,9}\ [0-9]{1,9}\ [0-9]{1,9}$ ]]; then
      po=$((10#$ao - 10#$bo)); pm=$((10#$am - 10#$bm))
    fi
  fi
  (( po >= 0 )) || po=0; (( pm >= 0 )) || pm=0
  conduct_record_usage "$PLAN" "$RUN_UNIT" "$role" "$lg" "$t0" "$t1" "$2" "$po" "$pm"
}
# stdout: "<all> <merged>" pull requests whose head branch starts with the unit's prefix; "x x" when
# gh cannot list them. A separate call (not conduct_find_prs) keeps the outage scenarios' gh call
# counts stable; it counts a fork's pull requests too, which can only skew a metric, never a gate.
_conduct_pr_counts() {
  local bp out; bp="$(conduct_branch_prefix "$PLAN" "$RUN_UNIT")"
  out="$(cd "$REPO_DIR" && bounded 60 gh pr list -R "$FARM_REPO_SLUG" --state all --search "head:$bp" --limit 200 \
    --json number,headRefName,state 2>/dev/null)" \
    && printf '%s' "$out" | jq -r --arg p "$bp" '[.[] | select((.headRefName | type) == "string" and (.headRefName | startswith($p)))]
      | "\(length) \([.[] | select(.state == "MERGED")] | length)"' 2>/dev/null || echo "x x"
}

# The conductor's EXIT trap: a running child is sent TERM (conduct_launch's trap in it ends the
# session) and awaited, then the lock is released. The unit's state is left as it is (doing), so
# the next start counts a restart.
_conduct_run_exit() {
  if [[ -n "${CONDUCT_CHILD:-}" ]]; then
    kill -TERM "$CONDUCT_CHILD" 2>/dev/null || true
    wait "$CONDUCT_CHILD" 2>/dev/null || true
  fi
  rm -f "${CONDUCT_STEP_OUT:-/nonexistent}" "${CONDUCT_STEP_OUT:-/nonexistent}".*
  conduct_unlock "$CDIR/lock"
}

# <mode>. One lead session (conduct_run_lead, run in this shell so its traps end the session on a
# TERM); stdout: its outcome, an ended one refined by conduct_refine_ended.
_conduct_step_lead() {
  local o
  setup "$PLAN"
  conduct_run_lead "$PLAN" "$RUN_UNIT" "$1" > "$CONDUCT_STEP_OUT.lead"
  o="$(tail -n 1 "$CONDUCT_STEP_OUT.lead")"
  if [[ "$o" == ended ]]; then conduct_refine_ended "$PLAN" "$RUN_UNIT"; else echo "$o"; fi
}

# The handoff pull request checked (phase one), then one fresh review session, then the
# conductor's merge. stdout: the outcome. gh unable to list the pull requests, or no tip for the
# handoff branch on origin, is transient: an outage costs an interruption, never the rework round.
_conduct_step_review() {
  local ph pr hs v ud f0 o=""
  setup "$PLAN"
  ud="$CDIR/$KEY/$(conduct_unit_slug "$RUN_UNIT")"; f0="$(_conduct_newest_findings "$ud")"
  conduct_check_handoff_pr "$PLAN" "$RUN_UNIT" one > "$CONDUCT_STEP_OUT.check"
  ph="$(tail -n 1 "$CONDUCT_STEP_OUT.check")"
  case "$ph" in
    "ok "*) ;;
    "invalid no-pr-list") o=transient ;;
    "invalid head-mismatch")
      o=handoff-invalid; [[ -n "$(remote_sha "$(conduct_branch_prefix "$PLAN" "$RUN_UNIT")handoff")" ]] || o=transient ;;
    *) o=handoff-invalid ;;
  esac
  if [[ -n "$o" ]]; then
    # An outage is not a finding: the findings file the check just wrote must not reach a later lead.
    if [[ "$o" == transient && "$(_conduct_newest_findings "$ud")" != "$f0" ]]; then rm -f "$(_conduct_newest_findings "$ud")"; fi
    [[ "$o" != transient ]] || conduct_outage_backoff
    echo "$o"; return 0
  fi
  read -r _ pr hs <<<"$ph"
  conduct_run_review "$PLAN" "$RUN_UNIT" "$pr" "$hs" > "$CONDUCT_STEP_OUT.review"
  v="$(tail -n 1 "$CONDUCT_STEP_OUT.review")"
  case "$v" in
    accept\ *|reject\ *) conduct_merge_handoff "$PLAN" "$RUN_UNIT" "$pr" "$v" ;;
    *) echo "$v" ;;
  esac
}

# <unit dir>. stdout: its newest findings-<n>.md, or nothing.
_conduct_newest_findings() {
  local f k n=0 p=""
  for f in "$1"/findings-*.md; do
    k="${f##*/findings-}"; k="${k%.md}"
    if [[ "$k" =~ ^[0-9]{1,9}$ && -f "$f" ]] && (( 10#$k > n )); then n=$((10#$k)); p="$f"; fi
  done
  printf '%s\n' "$p"
}

# <file>: a counter's text for conduct_next_decide (an absent file is 0; anything else is passed
# as it is, so a bad file stops the unit as invalid-state).
_conduct_ctr() { if [[ -e "$1" ]]; then head -1 "$1" 2>/dev/null || echo bad; else echo 0; fi; }

# <unit dir> <file> <text>: the file written through a temp file and mv.
_conduct_put() { printf '%s\n' "$3" > "$1/.$2.tmp.$$" && mv -f "$1/.$2.tmp.$$" "$1/$2"; }

# <unit dir> <reason>: stop: state escalated, stop_reason, the stop event; exit 3. A merge that
# failed after the handoff reached origin's main says so (no review record was written); a
# guard-blocked stop quotes the session's first denial (guard_denial, conduct_refine_ended).
_conduct_run_stop() {
  local r="$2" m
  [[ "$r" != guard-blocked || ! -f "$1/guard_denial" ]] || r="$r: $(head -1 "$1/guard_denial")"
  if [[ "$r" == handoff-merge-failed ]]; then
    bounded 120 "${NOHOOK[@]}" git -C "$REPO_DIR" fetch origin --prune --quiet 2>/dev/null || true
    if m="$(origin_main)" && git -C "$REPO_DIR" cat-file -e "${m#* }:$(conduct_handoff_path "$PLAN" "$RUN_UNIT")" 2>/dev/null; then
      r="$r: the handoff pull request is merged on origin/${m% *}, but no review record was written"
    fi
  fi
  _conduct_put "$1" stop_reason "$r" || die 2 "cannot write $1/stop_reason"
  printf 'escalated\n' > "$1/state" || die 2 "cannot write $1/state"
  log "stopped: $PLAN#$RUN_UNIT: $r"
  conduct_notify stop "$PLAN" "$RUN_UNIT" "$r"
  exit 3
}

# <unit dir>: wait for the operator's merge: stop_reason awaiting-operator-merge with the protected
# pull requests, state left doing, the awaiting-operator-merge event; exit 3.
_conduct_run_wait() {
  local r=awaiting-operator-merge oo
  oo="$(conduct_other_open "$PLAN" "$RUN_UNIT")" || oo=""
  case "$oo" in "protected "*) r="$r: $(printf '%s' "${oo#protected }" | sed 's/[0-9][0-9]*/#&/g')" ;; esac
  _conduct_put "$1" stop_reason "$r" || die 2 "cannot write $1/stop_reason"
  log "waiting: $PLAN#$RUN_UNIT: $r; merge it, then run the command again"
  conduct_notify awaiting-operator-merge "$PLAN" "$RUN_UNIT" "$r"
  exit 3
}

# <plan> (spec 4.5, the plan loop). Exit 0 when every unit is shipped. The units in
# conduct_topo_order, the status recomputed (setup re-reads origin) before each pick:
# conduct_loop_decide; run goes through the single-unit path (cmd_run, in a background child so a
# TERM reaches this shell) while this conductor holds $CDIR/lock for the whole plan. Exit 3 with
# the pause event (the refusal's code and detail as its reason) when that path's preflight
# refuses; exit 3 and no event on a stop:<code> or a unit still waiting for an operator merge (its
# own event was sent when it happened). Any other exit of the child ends the loop with that code.
# Security review M-1: the plan's blob on origin/<main> is pinned at loop start; a different blob at a
# re-read (re-ordered units, a dropped Depends-on, new units) sends pause with reason plan-changed
# naming both blobs and exits 3, launching nothing: the operator checks the new plan and restarts.
cmd_run_plan() {
  local u nu dec live last="" rc sr order pin cur
  setup "$1"; plan_protected_or_die; plan_spec_or_die; lint_or_die
  pin="$(git -C "$REPO_DIR" rev-parse -q --verify "$ORIGIN_MAIN:$PLAN" 2>/dev/null)" || pin=""
  _PLAN_PIN="${pin:-unreadable}"   # no pin reads as a change in the unit run (fail closed)
  conduct_lock "$CDIR/lock" || die 1 "preflight refused: conductor-active ($PLAN)"
  _PLAN_LOCK=1; _LOOP_REFUSAL="$CDIR/.loop-refusal.$$"; CONDUCT_CHILD=""
  trap '_conduct_run_exit; rm -f "$_LOOP_REFUSAL"; _PLAN_LOCK=0; conduct_unlock "$CDIR/lock"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  while :; do
    if [[ -n "$last" ]]; then
      setup "$PLAN"
      cur="$(git -C "$REPO_DIR" rev-parse -q --verify "$ORIGIN_MAIN:$PLAN" 2>/dev/null)" || cur=""
      if [[ "$(conduct_plan_pin_decide "$pin" "$cur")" != same ]]; then
        # The unit after the last shipped one in the order the loop started with.
        nu="$(printf '%s\n' "$order" | awk -v l="$last" 'f { print; exit } $0 == l { f = 1 }')"; nu="${nu:-$last}"
        sr="plan-changed ($PLAN#$nu): $PLAN on $MAIN_LABEL is blob ${cur:-unreadable}, the loop started on blob ${pin:-unreadable}; check it with farmctl conduct lint $PLAN, then run the loop again"
        log "paused: $sr"
        conduct_notify pause "$PLAN" "$nu" "$sr"; exit 3
      fi
      lint_or_die
    fi
    order="$(printf '%s\n' "$UNITS" | conduct_topo_order)" || die 1 "plan $PLAN has a dependency cycle: farmctl conduct lint $PLAN"
    load_records; nu=""; dec=""
    while IFS= read -r u; do
      [[ -n "$u" ]] || continue
      unit_status "$u" "$(printf '%s\n' "$UNITS" | awk -F '\t' -v u="$u" '$1 == u { print $3 }')"
      live=0; pid_alive "$(int_of "$UD/pid")" && live=1
      dec="$(conduct_loop_decide "$ST" "$live")"
      [[ "$dec" == skip ]] || { nu="$u"; break; }
    done <<<"$order"
    if [[ -z "$nu" ]]; then log "plan shipped: $PLAN"; exit 0; fi
    sr=""; [[ ! -f "$UD/stop_reason" ]] || sr="$(head -1 "$UD/stop_reason")"
    if [[ "$dec" != run ]]; then log "$PLAN#$nu: ${dec#stop:}${sr:+: $sr}; the plan loop stops"; exit 3; fi
    # A child that exits 0 has shipped its unit; picking it again would loop.
    [[ "$nu" != "$last" ]] || die 2 "$PLAN#$nu is not shipped after its run exited 0"
    rm -f "$_LOOP_REFUSAL"
    ( cmd_run "$PLAN" "$nu" ) </dev/null &
    CONDUCT_CHILD=$!; rc=0
    wait "$CONDUCT_CHILD" || rc=$?
    CONDUCT_CHILD=""
    case "$rc" in
      0) last="$nu" ;;
      1)
        if [[ -s "$_LOOP_REFUSAL" ]]; then
          log "paused: $PLAN#$nu: $(head -1 "$_LOOP_REFUSAL")"
          conduct_notify pause "$PLAN" "$nu" "$(cat "$_LOOP_REFUSAL")"; exit 3
        fi
        # cmd_run named the protected pull request that is still open.
        sr=""; [[ ! -f "$UD/stop_reason" ]] || sr="$(head -1 "$UD/stop_reason")"
        case "$sr" in awaiting-operator-merge*) exit 3 ;; esac
        exit 1 ;;
      *) exit "$rc" ;;
    esac
  done
}

# <plan> <unit> [--answer <text>]. Exit 0 shipped, 1 refused, 2 environment, 3 the unit stopped
# (escalated) or waits for the operator's merge. Refusals first (conduct_run_start_decide, the
# protected pull requests of a waiting unit, conduct_preflight); nothing is written before them.
# Then the loop: a lead or review step, conduct_next_decide on its outcome, the counter bumped
# before the launch it counts, conduct_wait_gate after a limit or transient.
cmd_run() {
  local plan="" unit="" ans="" ha=0 ud sr st oo o="" act ctr next="" last=lead c pb
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --answer) [[ $# -ge 2 && -n "$2" ]] || usage; ans="$2"; ha=1; shift 2 ;;
      -*) usage ;;
      *) if [[ -z "$plan" ]]; then plan="$1"; elif [[ -z "$unit" ]]; then unit="$1"; else usage; fi; shift ;;
    esac
  done
  [[ -n "$plan" ]] || usage
  if [[ -z "$unit" ]]; then [[ "$ha" == 0 ]] || usage; cmd_run_plan "$plan"; fi
  setup "$plan"; plan_protected_or_die; plan_spec_or_die
  # Hook finding H1: the plan may change between the loop's pin check and this setup. A pin only adds
  # this refusal; the loop sends it as its one pause event and exits 3. Nothing is written before it.
  if [[ -n "$_PLAN_PIN" ]]; then
    c="$(git -C "$REPO_DIR" rev-parse -q --verify "$ORIGIN_MAIN:$PLAN" 2>/dev/null)" || c=""
    [[ "$(conduct_plan_pin_decide "$_PLAN_PIN" "$c")" == same ]] \
      || _conduct_refuse "plan-changed ($PLAN#$unit): $PLAN on $MAIN_LABEL is blob ${c:-unreadable}, the loop started on blob $_PLAN_PIN; check it with farmctl conduct lint $PLAN, then run the loop again"
  fi
  printf '%s\n' "$UNITS" | cut -f1 | grep -Fx -- "$unit" >/dev/null || die 1 "unit $unit is not in $PLAN"
  load_records; unit_status "$unit" ""; ud="$UD"
  sr=""; [[ ! -f "$ud/stop_reason" ]] || sr="$(head -1 "$ud/stop_reason")"
  st="$(conduct_run_start_decide "$ST" "$sr" "$ha")"
  case "$st" in
    refuse:already-shipped) die 1 "$PLAN#$unit is already shipped" ;;
    refuse:shipped-unreviewed) die 1 "$PLAN#$unit is shipped-unreviewed: its handoff is on $MAIN_LABEL without a review record (farmctl conduct adopt records it)" ;;
    refuse:stopped) die 1 "$PLAN#$unit is stopped: ${sr:-no stop reason recorded}; run again with --answer <text>" ;;
    refuse:*) die 1 "$PLAN#$unit is not stopped: --answer is only for an escalated unit" ;;
    awaiting)
      oo="$(conduct_other_open "$PLAN" "$unit")" || die 2 "cannot list the pull requests of $PLAN#$unit; run again later"
      case "$oo" in "protected "*)
        die 1 "awaiting-operator-merge: pull request $(printf '%s' "${oo#protected }" | sed 's/[0-9][0-9]*/#&/g') is still open; merge it, then run again" ;;
      esac ;;
  esac
  conduct_preflight "$PLAN" "$unit"
  RUN_UNIT="$unit"; CONDUCT_STEP_OUT="$ud/.step"; CONDUCT_CHILD=""
  trap _conduct_run_exit EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  mkdir -p "$ud"
  # Final review I1: a session the last run did not see end (killed conductor, a step that failed after it).
  _conduct_record_session "$ud" killed ""
  case "$st" in
    answer)
      _conduct_put "$ud" answer.txt "$ans" || die 2 "cannot write $ud/answer.txt"
      for c in rework continuation interruption; do _conduct_put "$ud" "$c" 0 || die 2 "cannot reset $ud/$c"; done
      rm -f "$ud/stop_reason"; printf 'doing\n' > "$ud/state"; next="lead continue" ;;
    awaiting) rm -f "$ud/stop_reason"; next="lead continue" ;;
    restart) o=restart ;;
    *) next="lead start" ;;
  esac
  while :; do
    if [[ -n "$next" ]]; then
      last="${next%% *}"; pb="$PRC"; [[ "$pb" =~ ^[0-9]+\ [0-9]+$ ]] || pb="$(_conduct_pr_counts)"
      if [[ "$last" == lead ]]; then conduct_child _conduct_step_lead "${next#lead }"; else conduct_child _conduct_step_review; fi
      o="$(tail -n 1 "$CONDUCT_STEP_OUT")"; next=""
      _conduct_record_session "$ud" "$o" "$pb"
    fi
    act=""; ctr=""
    read -r act ctr < <(conduct_next_decide "$o" "$(_conduct_ctr "$ud/rework")" "$(_conduct_ctr "$ud/continuation")" "$(_conduct_ctr "$ud/interruption")") || true
    log "$PLAN#$unit: ${o:-no outcome} -> $act $ctr"
    case "$act" in
      done) rm -f "$ud/stop_reason"; log "shipped: $PLAN#$unit"; exit 0 ;;
      wait) _conduct_run_wait "$ud" ;;
      review) next=review ;;
      resume|continue|rework)
        conduct_counter_bump "$ud" "$ctr" || die 2 "cannot count $ctr in $ud"
        case "$o" in limit|transient) conduct_child conduct_wait_gate "$PLAN" "$unit" "$o" ;; esac
        # An interrupted review is relaunched as a review: fresh, with a new nonce and verdict directory.
        if [[ "$act" == resume && "$last" == review ]]; then next=review; else next="lead $act"; fi ;;
      stop) _conduct_run_stop "$ud" "${ctr:-invalid-state}" ;;
      *) _conduct_run_stop "$ud" invalid-state ;;
    esac
  done
}

[[ -n "${CONDUCT_DEFINE_ONLY:-}" ]] && return 0 2>/dev/null || true

cmd="${1:-}"; [[ $# -eq 0 ]] || shift
case "$cmd" in
  lint)   [[ $# -eq 1 ]] || usage; cmd_lint "$1" ;;
  status) cmd_status "$@" ;;
  adopt)  cmd_adopt "$@" ;;
  run)    cmd_run "$@" ;;
  *)      usage ;;
esac
