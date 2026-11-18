# shellcheck shell=bash
# agent-farm/bin/farm-conduct-lib.sh — Plan Conductor deciders. Sourced only (no shebang,
# no exec bit), no dependency on farm-lib.sh. Portable to bash 3.2 and BSD awk.
# Tests: engine/tests/conduct.sh.

# A level-2 unit heading. No \b: works in bash 3.2 [[ =~ ]] and BSD awk.
# shellcheck disable=SC2034  # used by callers and tests
CONDUCT_UNIT_RE='^## (M[0-9]+[a-z]?|PR [0-9]+|Iteration [0-9]+)([^A-Za-z0-9]|$)'

# Shared awk prologue: strips CRLF, defines fence(), and skips fenced lines until the fence
# closes (same char, at least as long, nothing after). A backtick run followed by text holding
# a backtick is no fence (CommonMark). Each program opens a fence itself with
# `fence($0) { infence = 1; oc = fc; on = fn; next }` where it fits its own rules.
_CONDUCT_AWK_FENCE='
    # Sets fc (fence char), fn (run length), frest (text after the run); 1 when s is a fence line.
    function fence(s,   n) {
      match(s, /^ */); if (RLENGTH > 3) return 0
      s = substr(s, RLENGTH + 1); fc = substr(s, 1, 1)
      if (fc != "`" && fc != "~") return 0
      n = 0; while (substr(s, n + 1, 1) == fc) n++
      if (n < 3) return 0
      fn = n; frest = substr(s, n + 1)
      if (fc == "`" && index(frest, "`")) return 0
      return 1
    }
    { sub(/\r$/, "") }   # CRLF input: a trailing \r would keep fences open and leak into fields
    infence {
      if (fence($0) && fc == oc && fn >= on && frest ~ /^[ \t]*$/) infence = 0
      next
    }
'

# stdin: plan markdown. stdout: one line per unit, tab-separated
# unit, title, deps (comma list), tasks (count), line. Headings inside fenced code are ignored.
# Default dependency is the previous unit; `Depends-on: none` clears it.
conduct_plan_units() {
  awk -v ure="$CONDUCT_UNIT_RE" "$_CONDUCT_AWK_FENCE"'
    function flush() {
      if (cur != "") printf "%s\t%s\t%s\t%d\t%d\n", cur, title, deps, tasks, line
      cur = ""; fresh = 0
    }
    # Spec 4.4: Depends-on sits directly under the unit heading (first non-blank line).
    fresh && $0 !~ /^[ \t]*$/ {
      fresh = 0
      if ($0 ~ /^Depends-on:/) {
        v = substr($0, 12); n = split(v, a, ","); deps = ""
        for (i = 1; i <= n; i++) {
          d = a[i]; sub(/^[ \t]+/, "", d); sub(/[ \t]+$/, "", d)
          if (d != "" && d != "none") deps = deps (deps == "" ? "" : ",") d
        }
        next
      }
    }
    fence($0) { infence = 1; oc = fc; on = fn; next }
    /^## / {
      flush()
      if ($0 !~ ure) next
      s = substr($0, 4)
      if (s ~ /^M/) match(s, /^M[0-9]+[a-z]?/)
      else if (s ~ /^PR /) match(s, /^PR [0-9]+/)
      else match(s, /^Iteration [0-9]+/)
      cur = substr(s, 1, RLENGTH); title = substr(s, RLENGTH + 1)
      sub(/^( |:|-|—|–)+/, "", title); sub(/[ \t]+$/, "", title)
      deps = prev; prev = cur; tasks = 0; line = NR; fresh = 1
      next
    }
    cur != "" && /^### (Task [^:]+|[A-Za-z]+ ?[0-9]+[a-z]?[-.]T?[0-9]+[a-z]?):/ { tasks++ }
    END { flush() }
  '
}

# Shared graph pass over conduct_plan_units lines. <mode: lint|topo|dependents> <arg>.
# Order = repeated removal of units whose known dependencies are all removed; each round
# keeps document order. Unknown deps are reported by lint, not treated as a cycle.
_conduct_graph() {
  awk -F '\t' -v mode="$1" -v arg="${2:-}" '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    function order(   i, j, k, nd, d, ready, rdy) {
      left = n; no = 0
      while (left > 0) {
        k = 0
        for (i = 1; i <= n; i++) {
          if (gone[i]) continue
          nd = split(dep[i], d, ","); rdy = 1
          for (j = 1; j <= nd; j++) if ((d[j] in idx) && !(d[j] in rem)) rdy = 0
          if (rdy) ready[++k] = i
        }
        if (k == 0) return
        for (j = 1; j <= k; j++) { gone[ready[j]] = 1; rem[id[ready[j]]] = 1; ord[++no] = ready[j]; left-- }
      }
    }
    $1 != "" {
      n++; id[n] = $1; tasks[n] = $4; if ($1 in idx) dup[$1] = 1; idx[$1] = n
      # Trim each dep token once here, so lint, topo and dependents all see clean ids.
      nd = split($3, d, ","); dep[n] = ""
      for (j = 1; j <= nd; j++) { t = trim(d[j]); if (t != "") dep[n] = dep[n] (dep[n] == "" ? "" : ",") t }
    }
    END {
      if (mode == "dependents") {
        for (i = 1; i <= n; i++) {
          nd = split(dep[i], d, ",")
          for (j = 1; j <= nd; j++) if (d[j] == arg) { print id[i]; break }
        }
        exit 0
      }
      order()
      if (mode == "topo") { for (i = 1; i <= no; i++) print id[ord[i]]; exit (left > 0) }
      if (n == 0) { print "LINT: no-units"; exit 1 }
      bad = 0
      for (i = 1; i <= n; i++) if ((id[i] in dup) && !(id[i] in said)) {
        said[id[i]] = 1; print "LINT: duplicate: " id[i]; bad = 1
      }
      for (i = 1; i <= n; i++) {
        nd = split(dep[i], d, ",")
        for (j = 1; j <= nd; j++) if (!(d[j] in idx)) { print "LINT: unknown-dep: " id[i] ": " d[j]; bad = 1 }
      }
      for (i = 1; i <= n; i++) if (tasks[i] + 0 == 0) {
        print "LINT: no-tasks: " id[i] ": unit has no tasks; delete the heading, or give the next unit an explicit Depends-on:"
        bad = 1
      }
      if (left > 0) {
        s = ""; for (i = 1; i <= n; i++) if (!gone[i]) s = s (s == "" ? "" : ",") id[i]
        print "LINT: cycle: " s; bad = 1
      }
      ns = split(arg, sh, ",")
      for (i = 1; i <= ns; i++) {
        u = trim(sh[i])
        if (u != "" && !(u in idx)) { print "LINT: renamed-shipped: " u; bad = 1 }
      }
      exit bad
    }
  '
}

# <shipped units, comma list>; stdin: unit lines. rc 0, or rc 1 with one
# "LINT: <code>: <detail>" line per problem.
conduct_lint() { _conduct_graph lint "${1:-}"; }

# stdin: unit lines. stdout: unit ids in dependency order (document order among equals).
# rc 1 on a cycle (the units in it are not printed).
conduct_topo_order() { _conduct_graph topo; }

# <unit>; stdin: unit lines. stdout: units that list <unit> as a direct dependency.
conduct_dependents() { _conduct_graph dependents "$1"; }

# "PR 3" -> pr-3
conduct_unit_slug() {
  printf '%s\n' "$1" | tr 'A-Z ' 'a-z-'
}

# docs/plans/2026-11-12-x.md -> 2026-11-12-x. rc 1 unless a repo-relative
# ^[A-Za-z0-9._/-]+\.md$ path without a . or .. component or an empty one (PD12).
conduct_plan_key() {
  local p="$1" b
  [[ "$p" =~ ^[A-Za-z0-9._/-]+\.md$ ]] || return 1
  case "$p" in /*) return 1 ;; esac
  case "/$p/" in */../*|*/./*|*//*) return 1 ;; esac
  b="${p##*/}"; b="${b%.md}"
  [[ -n "$b" ]] || return 1
  printf '%s\n' "$b"
}

conduct_handoff_path() { # <plan path> <unit>
  local k; k="$(conduct_plan_key "$1")" || return 1
  printf 'docs/superpowers/handoffs/%s-%s-handoff.md\n' "$k" "$(conduct_unit_slug "$2")"
}

conduct_branch_prefix() { # <plan path> <unit>
  local k; k="$(conduct_plan_key "$1")" || return 1
  printf 'conduct/%s/%s/\n' "$k" "$(conduct_unit_slug "$2")"
}

# Handoff pass (spec 4.4). <mode: validate|statuses> <phase> <units, comma list>; stdin: handoff.
# A section is a level-2 heading outside a fence, indented at most 3 spaces (GFM),
# "## ([0-9]+[a-z]?\. )?<name>" case-insensitive, anything after allowed. In an "<unit> entry criteria" section every table counts: its first
# row is the header and its second must be a separator row with as many cells (else every row
# of it, header included, is invalid); later separator rows are skipped. The status cell is the
# column headed Status, else the last, chosen per table; a header with two Status columns makes
# every row of that table invalid. An escaped \| stays inside its cell (GFM); two or more
# backslashes before a "|" are ambiguous, so that row is invalid (a header: every row).
# Fail closed where a renderer would show something else: any HTML block start (<x, </, <?, <!) or "<!--"
# outside a fence is an "html" error (statuses: invalid); a "|" line indented 4+ spaces is a
# code block, not a table, and any other line continuing a table is an invalid row.
# An entry-criteria section is an allowlist: blank lines, top-level table lines (a "|" after at
# most 3 spaces) and plain text (no "|", not a blockquote, heading, list item or setext
# underline). Any other line there is "bad-line: <unit>: <line number>" (statuses: invalid).
_conduct_handoff() {
  awk -v mode="$1" -v phase="$2" -v units="$3" "$_CONDUCT_AWK_FENCE"'
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    function cells(s, c,   i, n) {
      s = trim(s); gsub(/\\\|/, "\001", s); sub(/^\|/, "", s); sub(/\|$/, "", s)
      n = split(s, c, "|"); for (i = 1; i <= n; i++) gsub(/\001/, "|", c[i]); return n
    }
    # PD13: the leading token, case-sensitive, then end of cell or a non-alphanumeric character.
    function token(s) {
      s = trim(s)
      if (s ~ /^not met([^A-Za-z0-9]|$)/) return "not met"
      if (s ~ /^met([^A-Za-z0-9]|$)/) return "met"
      if (s ~ /^accepted([^A-Za-z0-9]|$)/) return "accepted"
      return "invalid"
    }
    # Plain text: no "|", and after at most 3 spaces no >, #, list marker, ordered-list
    # marker or setext underline.
    function plain(s) {
      if (s ~ /\|/) return 0
      match(s, /^ */); if (RLENGTH > 3) return 1   # indented code
      s = substr(s, RLENGTH + 1)
      return s !~ /^(>|#|[-*+]([ \t]|$)|[0-9]+[.)]|=+[ \t]*$|-+[ \t]*$)/
    }
    function issep(n, c,   i) { for (i = 1; i <= n; i++) if (trim(c[i]) !~ /^:?-+:?$/) return 0; return 1 }
    function row(t,   r) {
      r = ++rows[cur]
      if (mode == "statuses") print t
      else if (t == "invalid") bad[++nb] = cur ": " r
    }
    # ts: 0 no table, 1 header seen, 2 separator seen, 3 not a table (fails closed).
    function endtable() { if (cur != "" && ts == 1) row("invalid"); ts = 0 }
    BEGIN {
      n = split(units, a, ",")
      for (i = 1; i <= n; i++) {
        u = trim(a[i]); k = tolower(u)
        if (u != "" && !(k in want)) { want[k] = u; ord[++no] = u }
      }
    }
    fence($0) { endtable(); infence = 1; oc = fc; on = fn; next }
    /<!--/ || /^ ? ? ?<[A-Za-z\/?!]/ {
      if (mode == "statuses") print "invalid"; else html[++nh] = $0
    }
    /^ ? ? ?## / {
      endtable()
      h = $0; sub(/^ */, "", h); h = tolower(substr(h, 4)); sub(/^[0-9]+[a-z]?\. /, "", h); cur = ""
      if (index(h, "verification evidence") == 1) has["verification-evidence"] = 1
      if (index(h, "lessons learned") == 1) has["lessons-learned"] = 1
      if (index(h, "security review") == 1) has["security-review"] = 1
      for (k in want) if (index(h, k " entry criteria") == 1) { cur = want[k]; seen[cur] = 1 }
      next
    }
    cur == "" { next }
    /^ ? ? ?\|/ {
      n = cells($0, c)
      if (ts == 0) {
        sc = n; ns = 0; for (i = n; i >= 1; i--) if (tolower(trim(c[i])) == "status") { sc = i; ns++ }
        if (ns > 1 || $0 ~ /\\\\\|/) sc = 0
        hn = n; ts = 1; next
      }
      if (ts == 1) {
        if (n == hn && issep(n, c)) { ts = 2; next }
        ts = 3; row("invalid")   # no separator row: the header line was a data row too
      }
      if (ts == 3) { row("invalid"); next }
      if (issep(n, c)) next
      row(n == hn && sc && $0 !~ /\\\\\|/ ? token(c[sc]) : "invalid")   # fail closed on a shifted row
      next
    }
    $0 !~ /^[ \t]*$/ && !plain($0) {
      if (mode == "statuses") print "invalid"; else bl[++nl] = cur ": " NR
    }
    ts == 2 && $0 !~ /^[ \t]*$/ { row("invalid") }   # GFM keeps it in the table as a row
    { endtable() }   # a non-table line ends the table; the next one has its own header
    END {
      endtable()
      if (mode != "validate") exit 0
      e = 0
      if (!("verification-evidence" in has)) { print "HANDOFF: missing-section: verification-evidence"; e = 1 }
      if (!("lessons-learned" in has)) { print "HANDOFF: missing-section: lessons-learned"; e = 1 }
      if (phase == "two" && !("security-review" in has)) { print "HANDOFF: missing-section: security-review"; e = 1 }
      for (i = 1; i <= no; i++) {
        if (!(ord[i] in seen)) { print "HANDOFF: missing-entry-criteria: " ord[i]; e = 1 }
        else if (rows[ord[i]] + 0 == 0) { print "HANDOFF: empty-entry-criteria: " ord[i]; e = 1 }
      }
      for (i = 1; i <= nb; i++) { print "HANDOFF: bad-status: " bad[i]; e = 1 }
      for (i = 1; i <= nl; i++) { print "HANDOFF: bad-line: " bl[i]; e = 1 }
      for (i = 1; i <= nh; i++) { print "HANDOFF: html: " html[i]; e = 1 }
      exit e
    }
  '
}

# <phase: one|two> <dependent units, comma list>; stdin: handoff. rc 0, or rc 1 with
# "HANDOFF: <code>" lines. Phase one (the lead's handoff pull request): verification evidence,
# lessons learned, and per dependent unit an entry-criteria table with at least one row and
# valid statuses. Phase two (after the review session): phase one plus the security review.
conduct_handoff_validate() {
  case "${1:-}" in one|two) ;; *) echo "HANDOFF: bad-phase"; return 1 ;; esac
  _conduct_handoff validate "$1" "${2:-}"
}

# <unit>; stdin: handoff. stdout: met, not met, accepted or invalid, one per table row.
conduct_entry_statuses() { _conduct_handoff statuses "" "$1"; }

# <handoff_on_main 0|1> <reviewed 0|1> <adopted 0|1> <state none|doing|review|escalated>
# <deps_shipped 0|1>. stdout: the unit's status (spec 4.4 vocabulary). A handoff on main is
# shipped once reviewed or adopted; an unknown state is treated as blocked (escalated).
conduct_unit_status() {
  if [[ "$1" == 1 ]]; then
    if [[ "$2" == 1 || "$3" == 1 ]]; then echo shipped; else echo shipped-unreviewed; fi
    return 0
  fi
  case "$4" in
    doing|review|escalated) echo "$4" ;;
    none) if [[ "$5" == 1 ]]; then echo ready; else echo backlog; fi ;;
    *) echo escalated ;;
  esac
}

# <origin url>. stdout: owner/repo, parsed like farm-lib's farm_repo_slug (scheme://[user@]host/
# owner/repo, scp-like user@host:owner/repo, or a path; a trailing / and .git stripped).
# rc 1 when the url has no owner/repo.
conduct_repo_slug() {
  local url="${1%/}" path owner
  url="${url%.git}"
  case "$url" in
    *://*) path="${url#*://}"; path="${path#*@}"; path="${path#*/}" ;;
    *@*:*) path="${url#*:}" ;;
    *)     path="$url" ;;
  esac
  [[ "$path" == */* ]] || return 1
  owner="${path%/*}"; owner="${owner##*/}"
  [[ -n "$owner" && -n "${path##*/}" ]] || return 1
  printf '%s/%s\n' "$owner" "${path##*/}"
}

# stdout: the conductor directory for FARM_REPO_SLUG (owner/repo, "/" -> "__").
# rc 2 when FARM_REPO_SLUG is empty (no parsable origin).
conduct_dir() {
  [[ -n "${FARM_REPO_SLUG:-}" ]] || return 2
  printf '%s/agent-farm/%s/conduct\n' "${XDG_STATE_HOME:-$HOME/.local/state}" "$(printf '%s' "$FARM_REPO_SLUG" | sed 's#/#__#g')"
}

# stdin: conduct_entry_statuses tokens. stdout: invalid if any token is not one of
# met / not met / accepted, else blocked on any "not met", else ok; none without tokens.
conduct_entry_decide() {
  awk '
    $0 == "" { next }
    $0 == "met" || $0 == "accepted" { n++; next }
    $0 == "not met" { n++; blk = 1; next }
    { inv = 1 }
    END { print (inv ? "invalid" : (blk ? "blocked" : (n ? "ok" : "none"))) }
  '
}

# <key>; stdin: farm.env text. stdout: the value of the last `[export ]<key>=value` line, one
# layer of matching quotes removed; nothing when absent or empty. Parsed, never evaluated.
conduct_env_value() {
  [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
  awk -v k="$1=" '
    { sub(/\r$/, ""); s = $0; sub(/^[ \t]+/, "", s); sub(/^export[ \t]+/, "", s) }
    index(s, k) == 1 { v = substr(s, length(k) + 1); f = 1 }
    END {
      if (!f) exit 0
      sub(/[ \t]+$/, "", v); n = length(v); q = substr(v, 1, 1)
      if (n >= 2 && (q == "\"" || q == "\047") && substr(v, n, 1) == q) v = substr(v, 2, n - 2)
      if (v != "") print v
    }'
}

# <rules_json> <protection_json> <bypass never|possible|unknown>: the answers of
# rules/branches/<main> and branches/<main>/protection ('' for a call that failed). stdout: ok,
# no-pull-request-rule, no-required-check, admin-bypass or undetermined (neither call answered,
# or a ruleset's bypass is unknown). Ruleset rules bind the lead only when bypass is never;
# classic protection only with enforce_admins.enabled true (the lead runs with the operator's token).
conduct_branch_rules_decide() {
  local r p rpr=false rchk=false ppr=false pchk=false adm=false rs=false
  r="$(printf '%s' "$1" | jq -rs 'if length == 1 and (.[0] | type) == "array" then .[0]
      | [any(.[]; type == "object" and .type == "pull_request"),
         any(.[]; type == "object" and .type == "required_status_checks"
           and ([.parameters.required_status_checks? // [] | .[]? | .context? | strings | select(. != "")] | length > 0))]
      | map(tostring) | join(" ") else "no" end' 2>/dev/null)" || r=""
  p="$(printf '%s' "$2" | jq -rs 'if length == 1 and (.[0] | type) == "object" then .[0]
      | [(.required_pull_request_reviews | type == "object"),
         ([.required_status_checks.contexts? // [] | .[]? | strings | select(. != "")] | length > 0),
         (.enforce_admins.enabled? == true)]
      | map(tostring) | join(" ") else "no" end' 2>/dev/null)" || p=""
  if [[ "$r" =~ ^(true|false)\ (true|false)$ ]]; then read -r rpr rchk <<<"$r"; else r=""; fi
  if [[ "$p" =~ ^(true|false)\ (true|false)\ (true|false)$ ]]; then read -r ppr pchk adm <<<"$p"; else p=""; fi
  [[ -n "$r$p" ]] || { echo undetermined; return 0; }
  [[ "$rpr$ppr" == *true* ]] || { echo no-pull-request-rule; return 0; }
  [[ "$rchk$pchk" == *true* ]] || { echo no-required-check; return 0; }
  # Each rule must come from a source the lead cannot bypass.
  [[ "$3" == never ]] && rs=true
  if [[ "$rpr$rs" == truetrue || "$ppr$adm" == truetrue ]] && [[ "$rchk$rs" == truetrue || "$pchk$adm" == truetrue ]]; then
    echo ok
  elif [[ "$3" == never || "$3" == possible ]]; then echo admin-bypass
  else echo undetermined; fi
}

# <rc> <elapsed_s> <timeout_s>. stdout: pass (rc 0), timeout (rc 124, or a non-zero rc once the
# elapsed time reached the timeout: bounded's TERM/KILL gives 143/137), else fail.
conduct_verify_decide() {
  [[ "$1" =~ ^[0-9]{1,3}$ ]] || { echo fail; return 0; }
  if [[ "$1" == 0 ]]; then echo pass
  elif [[ "$1" == 124 ]]; then echo timeout
  elif [[ "$2" =~ ^[0-9]{1,10}$ && "$3" =~ ^[0-9]{1,10}$ ]] && (( 10#$2 >= 10#$3 )); then echo timeout
  else echo fail; fi
}

# <lint 0|1> <deps 0|1> <entry ok|blocked|invalid|none> <verify_cmd 0|1> <branch_rules>
# <main_match 0|1> <lock 0|1> <guard_rc> <live_session 0|1>. stdout: ok or refuse:<code>,
# the first failing check in this order.
conduct_preflight_decide() {
  [[ "$1" == 1 ]] || { echo refuse:lint; return 0; }
  [[ "$2" == 1 ]] || { echo refuse:dependency-not-shipped; return 0; }
  case "$3" in ok) ;; blocked) echo refuse:entry-criteria-blocked; return 0 ;; *) echo refuse:entry-criteria-invalid; return 0 ;; esac
  [[ "$4" == 1 ]] || { echo refuse:verify-cmd-unset; return 0; }
  case "$5" in ok) ;; no-pull-request-rule|no-required-check|admin-bypass) echo "refuse:$5"; return 0 ;;
    *) echo refuse:branch-rules-undetermined; return 0 ;; esac
  [[ "$6" == 1 ]] || { echo refuse:main-branch-mismatch; return 0; }
  [[ "$7" == 1 ]] || { echo refuse:conductor-active; return 0; }
  [[ "$8" == 2 ]] || { echo refuse:guard-self-test; return 0; }
  [[ "$9" == 0 ]] || { echo refuse:session-alive; return 0; }
  echo ok
}

# <configured url> <effective fetch url> <effective push url> <pinned url or ''> (PD17).
# stdout: origin-rewritten (no configured url, or insteadOf/pushInsteadOf/pushurl redirects
# it), origin-changed (a pin that differs), else ok.
# Programs named in repo-local config (core.sshCommand, remote.*.uploadpack, ...) are refused
# by conduct_git_config_decide, not here.
conduct_origin_decide() {
  if [[ -z "$1" || "$2" != "$1" || "$3" != "$1" ]]; then echo origin-rewritten
  elif [[ -n "$4" && "$4" != "$1" ]]; then echo origin-changed
  else echo ok; fi
}

# stdin: `git config --list --show-scope --name-only` lines (<scope><TAB><key>). stdout: ok, or
# git-local-config:<key> (lower case) for the first local or worktree key off the allowlist.
# Security review M3a F1/F2: repo-local config can name programs git runs for the conductor
# (uploadpack, sshCommand, fsmonitor, filters), so it is an allowlist (lesson 33). Global and
# system config are the operator's.
conduct_git_config_decide() {
  awk -F '\t' '
    $1 == "local" || $1 == "worktree" {
      k = tolower($2)
      if (k !~ /^(core\.(repositoryformatversion|filemode|bare|logallrefupdates|ignorecase|precomposeunicode|symlinks)|extensions\.worktreeconfig|remote\.origin\.(url|fetch|tagopt|prune)|branch\..+\.(remote|merge|rebase)|user\.(name|email)|gc\.auto|fetch\.prune|pull\.rebase)$/) {
        print "git-local-config:" k; bad = 1; exit
      }
    }
    END { if (!bad) print "ok" }'
}

# <outcome> <rework> <continuation> <interruption>. stdout: <action> <detail>. Caps: rework 1,
# continuation 2, interruption 3; an action that bumps a counter is allowed while that counter
# is below its cap (the action's own counter decides). wait is not stop: no counter moves.
conduct_next_decide() {
  local n
  for n in "$2" "$3" "$4"; do [[ "$n" =~ ^[0-9]{1,10}$ ]] || { echo stop invalid-state; return 0; }; done
  case "$1" in
    handoff) echo review - ;;
    merged) echo "done -" ;;
    limit|transient|restart) if (( 10#$4 < 3 )); then echo resume interruption; else echo stop cap-interruption; fi ;;
    progress) if (( 10#$3 < 2 )); then echo continue continuation; else echo stop cap-continuation; fi ;;
    no-progress|review-reject|handoff-invalid) if (( 10#$2 < 1 )); then echo rework rework; else echo stop cap-rework; fi ;;
    guard-blocked) echo stop guard-blocked ;;
    awaiting-merge) echo wait awaiting-operator-merge ;;
    review-noverdict) echo stop review-no-verdict ;;
    guard-not-loaded) echo stop guard-not-loaded ;;
    settings-tampered) echo stop settings-tampered ;;
    shipped-unreviewed) echo stop shipped-unreviewed ;;
    merge-failed) echo stop handoff-merge-failed ;;
    checks-timeout) echo stop required-checks-not-reported ;;
    *) echo stop invalid-state ;;
  esac
}

# <status> <stop_reason> <answer 0|1>: how `farmctl conduct run` starts a unit (spec 4.5 restart
# rules). stdout: refuse:already-shipped, refuse:shipped-unreviewed, answer (escalated, with an
# answer), refuse:stopped (escalated or an unknown status, without one), refuse:no-answer-needed
# (an answer for a unit that is not stopped), awaiting (doing, stop reason awaiting-operator-merge),
# restart (doing or review: an earlier run ended without a stop), else start.
conduct_run_start_decide() {
  case "$1" in
    shipped) echo refuse:already-shipped ;;
    shipped-unreviewed) echo refuse:shipped-unreviewed ;;
    escalated) if [[ "$3" == 1 ]]; then echo answer; else echo refuse:stopped; fi ;;
    doing|review|ready|backlog)
      if [[ "$3" == 1 ]]; then echo refuse:no-answer-needed
      elif [[ "$1" == ready || "$1" == backlog ]]; then echo start
      elif [[ "$2" == awaiting-operator-merge* ]]; then echo awaiting
      else echo restart; fi ;;
    *) echo refuse:stopped ;;
  esac
}

# <status> <live_session 0|1>: what `farmctl conduct run <plan>` does with a unit, in dependency
# order. stdout: skip (shipped), run (ready, or doing/review with no live session: the single-unit
# path restarts it), else stop:<code> (session-alive, escalated, shipped-unreviewed, backlog,
# invalid-state for an unknown status or live value).
conduct_loop_decide() {
  case "$2" in 0|1) ;; *) echo stop:invalid-state; return 0 ;; esac
  case "$1" in
    shipped) echo skip ;;
    ready|doing|review) if [[ "$2" == 1 ]]; then echo stop:session-alive; else echo run; fi ;;
    escalated|shipped-unreviewed|backlog) echo "stop:$1" ;;
    *) echo stop:invalid-state ;;
  esac
}

# <plan blob at loop start> <plan blob now> (security review M-1). stdout: same only when both are
# 40-hex object names and equal, else changed (an unreadable blob counts as a change: fail closed).
conduct_plan_pin_decide() {
  if [[ "$1" =~ ^[0-9a-f]{40}$ && "$1" == "$2" ]]; then echo same; else echo changed; fi
}

# Operator requirement 2026-11-18. <plan path>; stdin: the plan. The first line starting **Spec:**
# outside fenced code and before the first unit heading names the spec: its first markdown link's
# target, resolved against the plan's directory, else its first backticked path, taken as
# repo-relative. A #fragment is dropped; . and .. are resolved. stdout, rc 0: the repo-relative path.
# rc 1: no-spec (no such line), or spec-bad-path (no target, a URL or any scheme:, an absolute path,
# an empty result, or one that leaves the repository).
conduct_plan_spec() {
  awk -v plan="$1" -v ure="$CONDUCT_UNIT_RE" "$_CONDUCT_AWK_FENCE"'
    fence($0) { infence = 1; oc = fc; on = fn; next }
    $0 ~ ure { exit }
    /^\*\*Spec:\*\*/ { spec = substr($0, 10); found = 1; exit }
    END {
      if (!found) { print "no-spec"; exit 1 }
      t = ""; base = plan; if (!sub(/\/[^\/]*$/, "", base)) base = ""
      if (match(spec, /\[[^]]*\]\([^)]*\)/)) {
        t = substr(spec, RSTART, RLENGTH); sub(/^\[[^]]*\]\(/, "", t); sub(/\)$/, "", t)
        sub(/^[ \t]+/, "", t); sub(/[ \t].*$/, "", t)
      } else if (match(spec, /`[^`]+`/)) { t = substr(spec, RSTART + 1, RLENGTH - 2); base = "" }
      sub(/#.*$/, "", t)
      if (t == "" || t ~ /^\// || t ~ /^[A-Za-z][A-Za-z0-9+.-]*:/) { print "spec-bad-path"; exit 1 }
      n = split((base == "" ? "" : base "/") t, a, "/"); k = 0
      for (i = 1; i <= n; i++) {
        if (a[i] == "" || a[i] == ".") continue
        if (a[i] == "..") { if (k == 0) { print "spec-bad-path"; exit 1 }; k--; continue }
        st[++k] = a[i]
      }
      if (k == 0) { print "spec-bad-path"; exit 1 }
      r = st[1]; for (i = 2; i <= k; i++) r = r "/" st[i]
      print r
    }'
}

# Operator decision 2026-11-18. <plan path>; stdin: protected globs, one per line (CR, blank and #
# lines skipped, as in the guard's merge gate). stdout: ok when the path passes conduct_plan_key and
# matches a glob the guard's way (* crosses /), else refuse:plan-unprotected (no glob: fail closed).
conduct_plan_protected_decide() {
  local glob hit=0
  if conduct_plan_key "$1" >/dev/null; then
    while IFS= read -r glob || [[ -n "$glob" ]]; do
      glob="${glob%$'\r'}"
      [[ -z "$glob" || "$glob" == \#* ]] && continue
      # shellcheck disable=SC2053  # the glob is the pattern, as in the guard's merge gate
      [[ "$1" == $glob ]] && hit=1
    done
  else cat >/dev/null; fi
  if [[ "$hit" == 1 ]]; then echo ok; else echo refuse:plan-unprotected; fi
}

# <action> <resume_enabled 0|1> <session_id>. stdout: resume only for a resume action with
# resuming enabled and a session id matching ^[0-9a-f-]{36}$, else fresh.
conduct_launch_mode() {
  if [[ "$1" == resume && "$2" == 1 && "$3" =~ ^[0-9a-f-]{36}$ ]]; then echo resume; else echo fresh; fi
}

# <before> <after> <now>: gate epochs read around a gate setter (PD22). stdout: before when it
# is a later gate than after that has not expired and is at most eight days ahead, else after.
# A value that is not an integer of at most 10 digits counts as absent.
conduct_gate_keep_decide() {
  local b="$1" a="$2" n="$3"
  [[ "$a" =~ ^[0-9]{1,10}$ ]] || a=""
  if [[ "$b" =~ ^[0-9]{1,10}$ && "$n" =~ ^[0-9]{1,10}$ ]] && (( 10#$b > 10#$n && 10#$b <= 10#$n + 8 * 86400 )) \
     && { [[ -z "$a" ]] || (( 10#$b > 10#$a )); }; then
    echo "$((10#$b))"
  else
    echo "$a"
  fi
}

# <farm dir>. stdout: a settings JSON registering <farm dir>/hooks/guard-bash.sh as a PreToolUse
# command hook for the matchers of hooks/hooks.json, with its timeout (120).
conduct_guard_settings() {
  jq -n --arg c "$1/hooks/guard-bash.sh" '{hooks: {PreToolUse: [("Bash", "Write|Edit|MultiEdit|NotebookEdit", "mcp__.*")
    | {matcher: ., hooks: [{type: "command", command: ($c | @sh), timeout: 120}]}]}}'
}

# <mode: settings|plugin-dir> <farm dir>; stdin: the session's init event. stdout: listed or
# not-listed (PD23). settings: some string value equals the guard command exactly, raw
# (<farm dir>/hooks/guard-bash.sh) or as conduct_guard_settings writes it (@sh-quoted).
# plugin-dir: a plugins entry has path <farm dir> or its physical form (pwd -P); an operator's
# installed copy elsewhere is not relied on. Bad input, an unknown mode or a relative farm dir -> not-listed.
conduct_guard_listed_decide() {
  local r="" pp
  if [[ "$2" == /* ]]; then
    case "$1" in
      settings) r="$(jq -rs --arg g "$2/hooks/guard-bash.sh" 'if length == 1 and (.[0] | type) == "object"
          and any(.[0] | .. | strings; . == $g or . == ($g | @sh)) then "listed" else empty end' 2>/dev/null)" ;;
      plugin-dir)
        pp="$(cd "$2" 2>/dev/null && pwd -P)" || pp="$2"
        r="$(jq -rs --arg p "$2" --arg q "$pp" 'if length == 1 and (.[0] | type) == "object"
          and any(.[0].plugins | arrays | .[]; type == "object" and (.path == $p or .path == $q)) then "listed" else empty end' 2>/dev/null)" ;;
    esac
  fi
  if [[ "$r" == listed ]]; then echo listed; else echo not-listed; fi
}

# <merged_before> <merged_after> <handoff_sha_before> <handoff_sha_after> [<guard_denials>]: merged
# pull request counts under the unit's prefix and origin's handoff-branch tip, at session start and
# end, and the run log's guard denial count. stdout: progress when both counts are integers and the
# count rose, or the handoff branch has a tip that differs from the start's; else guard-blocked when
# the denial count is an integer above 0 (a rework would meet the same denial); else no-progress.
# A non-integer count is not evidence.
conduct_progress_decide() {
  if [[ "$1" =~ ^[0-9]{1,10}$ && "$2" =~ ^[0-9]{1,10}$ ]] && (( 10#$2 > 10#$1 )); then echo progress
  elif [[ -n "$4" && "$4" != "$3" ]]; then echo progress
  elif [[ "${5:-}" =~ ^[0-9]{1,10}$ ]] && (( 10#$5 > 0 )); then echo guard-blocked
  else echo no-progress; fi
}

# <handoff branch> <globs_ok 0|1> <globs, one per line>; stdin: conduct_find_prs JSON. stdout:
# protected <numbers> when an OPEN pull request other than the handoff branch's is protected, else
# open <numbers> for all such, else none; unknown, rc 1, when stdin is not an array of objects.
# Protected (fail closed): globs_ok is not 1, a file matches a glob ([[ == ]], as the guard's merge
# gate), 100 or more files (gh returns at most 100), or a file list that is not an array of
# newline-free path strings.
conduct_other_open_decide() {
  local js n c f glob hit open="" prot=""
  js="$(cat)"
  printf '%s' "$js" | jq -e 'type == "array" and all(.[]; type == "object")' >/dev/null 2>&1 || { echo unknown; return 1; }
  for n in $(printf '%s' "$js" | jq -r --arg h "$1" '.[] | select(.state == "OPEN" and .headRefName != $h)
      | .number | select(type == "number" and . == floor and . > 0) | tostring'); do
    c="$(printf '%s' "$js" | jq -r --argjson n "$n" '[.[] | select(.number == $n)][0].files
      | if type == "array" and all(.[]; type == "object" and (.path | type) == "string" and (.path | test("\n") | not))
        then length else "x" end')"
    hit=0
    if [[ "$2" != 1 || ! "$c" =~ ^[0-9]{1,10}$ ]] || (( 10#$c >= 100 )); then hit=1
    else
      while IFS= read -r f; do
        while IFS= read -r glob; do
          glob="${glob%$'\r'}"
          [[ -z "$glob" || "$glob" == \#* ]] && continue
          # shellcheck disable=SC2053  # the glob is the pattern, as in the guard's merge gate
          [[ "$f" == $glob ]] && { hit=1; break 2; }
        done <<<"$3"
      done < <(printf '%s' "$js" | jq -r --argjson n "$n" '[.[] | select(.number == $n)][0].files[].path')
    fi
    open="$open $n"; [[ "$hit" == 0 ]] || prot="$prot $n"
  done
  if [[ -n "$prot" ]]; then echo "protected$prot"
  elif [[ -n "$open" ]]; then echo "open$open"
  else echo none; fi
}

# <nonce> <unit>; stdin: the review session's verdict file. stdout: "<accept|reject> <high>
# <medium> <low> <head>". rc 1, nothing printed, unless the input is exactly one JSON object with
# this unit and this (non-empty) nonce, verdict accept or reject, counts that are numbers of the
# form ^[0-9]{1,9}$ and a head of 40 lowercase hex characters. Values are compared and printed by jq
# only, never evaluated.
conduct_verdict_parse() {
  local out
  [[ -n "$1" ]] || return 1
  out="$(jq -r -s --arg n "$1" --arg u "$2" '
    def cnt: type == "number" and (tostring | test("^[0-9]+$"));
    if length == 1 and (.[0] | type == "object" and .nonce == $n and .unit == $u
        and (.verdict == "accept" or .verdict == "reject")
        and (.high | cnt) and (.medium | cnt) and (.low | cnt)
        and (.head | type == "string" and test("^[0-9a-f]{40}$")))
    then .[0] | "\(.verdict) \(.high) \(.medium) \(.low) \(.head)" else empty end' 2>/dev/null)" || return 1
  # At most 9 digits: 1e11 or a 20-digit count would later abort the caller's arithmetic.
  [[ "$out" =~ ^(accept|reject)\ [0-9]{1,9}\ [0-9]{1,9}\ [0-9]{1,9}\ [0-9a-f]{40}$ ]] || return 1
  printf '%s\n' "$out"
}

# <checks JSON>: the output of `gh pr checks <n> --required --json name,bucket` (PD27). stdout:
# none (an empty array), fail (any bucket fail, skipping or cancel), pass (at least one check, every
# bucket pass), pending (only pass and pending), else undetermined (not one JSON array of objects
# with a string bucket, or an unknown bucket). none and undetermined are no pass (fail closed).
conduct_checks_decide() {
  local r
  r="$(printf '%s' "$1" | jq -r -s 'if length == 1 and (.[0] | type == "array" and all(.[]; type == "object" and (.bucket | type) == "string"))
    then .[0] | if length == 0 then "none"
      elif any(.[]; .bucket == "fail" or .bucket == "skipping" or .bucket == "cancel") then "fail"
      elif all(.[]; .bucket == "pass") then "pass"
      elif all(.[]; .bucket == "pass" or .bucket == "pending") then "pending"
      else "undetermined" end
    else "undetermined" end' 2>/dev/null)" || r=""
  case "$r" in pass|pending|fail|none) echo "$r" ;; *) echo undetermined ;; esac
}

# <verdict accept|reject> <high> <medium> <handoff ok|invalid> <others none|open|protected>
# <verify pass|fail|timeout> <checks pass|pending|fail|none|undetermined>. stdout: stop:invalid-state
# on any unknown word or a count that is not ^[0-9]+$; else await-merge (a protected pull request
# under the prefix outranks everything); rework (a reject, a High or Medium finding, an invalid
# handoff, another open pull request, a failed or timed-out verify, a failing required check);
# wait (checks pending, none or undetermined); else merge.
conduct_merge_decide() {
  case "$1" in accept|reject) ;; *) echo stop:invalid-state; return 0 ;; esac
  [[ "$2" =~ ^[0-9]{1,10}$ && "$3" =~ ^[0-9]{1,10}$ ]] || { echo stop:invalid-state; return 0; }
  case "$4" in ok|invalid) ;; *) echo stop:invalid-state; return 0 ;; esac
  case "$5" in none|open|protected) ;; *) echo stop:invalid-state; return 0 ;; esac
  case "$6" in pass|fail|timeout) ;; *) echo stop:invalid-state; return 0 ;; esac
  case "${7:-}" in pass|pending|fail|none|undetermined) ;; *) echo stop:invalid-state; return 0 ;; esac
  if [[ "$5" == protected ]]; then echo await-merge
  elif [[ "$1" != accept || "$4" != ok || "$5" != none || "$6" != pass || "$7" == fail ]] || (( 10#$2 > 0 || 10#$3 > 0 )); then echo rework
  elif [[ "$7" == pass ]]; then echo merge
  else echo wait; fi
}

# ---- per-session metrics (section "metrics"): each reads a run log on stdin ----
# Every line is parsed as JSON on its own (fromjson?), so text a session read never counts.

# stdout: the session id of the first init event, or nothing.
conduct_session_id() {
  jq -R -r -n 'first(inputs | fromjson? | select(type == "object" and .type == "system" and .subtype == "init") | .session_id | strings)' 2>/dev/null || true
}

# stdout: JSON object keyed by model id, {in, out, cache_read, cache_creation, cost_usd} summed over
# every result event's modelUsage (spike S7: the usage block counts the main model only); {} when absent.
# Security review L-1: a token count that is not an integer in [0, 1e15) and a cost that is not a
# number in [0, 1e15) count 0, so a malformed or hostile line cannot dominate the totals.
conduct_usage_by_model() {
  jq -R -c -n 'def s(f): [.[] | .value | f | numbers | select(. >= 0 and . < 1e15)] | add // 0;
    def t(f): [.[] | .value | f | numbers | select(. >= 0 and . < 1e15 and . == floor)] | add // 0;
    [inputs | fromjson? | select(type == "object" and .type == "result") | .modelUsage | objects | to_entries[]]
    | group_by(.key) | map({key: .[0].key, value: {in: t(.inputTokens), out: t(.outputTokens),
        cache_read: t(.cacheReadInputTokens), cache_creation: t(.cacheCreationInputTokens), cost_usd: s(.costUSD)}})
    | from_entries' 2>/dev/null || echo '{}'
}

# <verify command>. stdout: {agent_dispatches, agent_dispatches_by_model, verify_runs, guard_denials}.
# Dispatches: assistant tool_use blocks named Agent or Task, by input.model ("inherit" when absent).
# Verify runs: assistant Bash tool_use whose command is the verify command or starts with it and a space.
# Denials: tool_result content in a user event, never assistant text.
conduct_log_counts() {
  jq -R -c -n --arg v "$1" '[inputs | fromjson? | select(type == "object")] as $e
    | [$e[] | select(.type == "assistant") | .message.content? | arrays[] | select(type == "object" and .type == "tool_use")] as $tu
    | [$tu[] | select(.name == "Agent" or .name == "Task") | ((.input | objects | .model | strings) // "inherit")] as $ag
    | {agent_dispatches: ($ag | length),
       agent_dispatches_by_model: ($ag | group_by(.) | map({key: .[0], value: length}) | from_entries),
       verify_runs: (if $v == "" or $v == "none" then 0
         else [$tu[] | select(.name == "Bash") | (.input | objects | .command | strings) | select(. == $v or startswith($v + " "))] | length end),
       guard_denials: [$e[] | select(.type == "user") | .message.content? | arrays[] | select(type == "object" and .type == "tool_result")
         | .content | (if type == "string" then . elif type == "array" then ([.[]? | select(type == "object") | .text? | strings] | join("\n")) else "" end)
         | select(contains("FARM-GUARD BLOCKED"))] | length}' 2>/dev/null \
    || echo '{"agent_dispatches":0,"agent_dispatches_by_model":{},"verify_runs":0,"guard_denials":0}'
}

# stdin: a run log. stdout: the first line holding FARM-GUARD BLOCKED of the first tool result
# that holds it (as conduct_log_counts counts denials), control characters removed, at most 200
# characters; nothing when there is none. The text is the session's: untrusted.
conduct_first_denial() {
  jq -R -r -n 'first(inputs | fromjson? | select(type == "object" and .type == "user") | .message.content? | arrays[]
      | select(type == "object" and .type == "tool_result")
      | .content | (if type == "string" then . elif type == "array" then ([.[]? | select(type == "object") | .text? | strings] | join("\n")) else "" end)
      | split("\n")[] | select(contains("FARM-GUARD BLOCKED")))
    | explode | map(select(. >= 32 and . != 127)) | implode | .[0:200]' 2>/dev/null || true
}

# stdout: {tools, mcp_servers, plugins, model, permission_mode, api_key_source, version, fp} from the
# first init event; fp is the cksum of the key-sorted compact JSON of the other fields (a changed tool
# set, server, plugin, model, mode, key source or version changes it), "none" when there is no init.
# Servers and plugins by name only: a server's status (connected, failed) is its health, not the set.
conduct_init_fingerprint() {
  local j fp
  j="$(jq -R -c -n '[inputs | fromjson? | select(type == "object" and .type == "system" and .subtype == "init")] | .[0] // empty
    | {tools: ((.tools // []) | sort),
       mcp_servers: ([.mcp_servers[]? | if type == "object" then (.name // "") else . end] | sort),
       plugins: ([.plugins[]? | if type == "object" then (.name // "") else . end] | sort),
       model: (.model // null), permission_mode: (.permissionMode // null),
       api_key_source: (.apiKeySource // null), version: (.claude_code_version // null)}' 2>/dev/null)" || j=""
  if [[ -z "$j" ]]; then
    echo '{"tools":null,"mcp_servers":null,"plugins":null,"model":null,"permission_mode":null,"api_key_source":null,"version":null,"fp":"none"}'
    return 0
  fi
  fp="$(printf '%s' "$j" | jq -S -c . | cksum | cut -d ' ' -f1)"
  printf '%s' "$j" | jq -c --argjson fp "$fp" '. + {fp: $fp}'
}
