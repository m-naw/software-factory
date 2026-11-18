#!/usr/bin/env bash
# guard-bash.sh — PreToolUse hook. Deterministic safety net for autonomous runs.
# Works under --dangerously-skip-permissions (the flag skips prompts, not hooks).
# exit 2 = block (stderr goes back to the model); exit 0 = no decision.
#
# Philosophy: this is a LAYER, not the foundation. The foundation is platform
# controls (branch protection, CODEOWNERS, scoped tokens, NO cloud creds on
# the box). This hook catches the dumb-but-fatal commands cheaply.

set -u

deny() { echo "FARM-GUARD BLOCKED: $1" >&2; exit 2; }

# Portable script-dir resolution: BSD/macOS `readlink` has no `-f`, so a
# `dirname "$(readlink -f "$0")"` fallback silently misresolves there. cd into
# $0's directory and print the physical (symlink-resolved-for-directories) pwd
# instead — works on both GNU and BSD userlands. Does not resolve a symlinked
# $0 FILE itself, only its containing directory; that is acceptable here
# because callers must fail CLOSED (deny), never fail-open, when the result is
# wrong.
# shellcheck disable=SC1007  # deliberate `CDPATH=` env-clearing prefix (not an assignment typo) to stop cd's output-changing CDPATH lookup
_script_dir() { CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd -P; }

# Canonicalize a path: absolute, symlinks resolved, . and .. collapsed. Prefer
# the reference tool so Linux behavior is unchanged; pure-bash only when neither
# realpath -m nor grealpath -m exists (stock macOS). The pure-bash walk is a
# realpath(1)-style WORK-LIST algorithm: components are drained from a queue,
# and when one resolves to a symlink its target's components are PREPENDED
# back onto the queue so they are themselves re-checked for being symlinks.
# This resolves symlinks in every position, including a target's own prefix
# (a plain single-pass walk only re-checks whether the whole substituted
# candidate is a symlink, which lets a symlink inside a target's prefix
# escape the walk undetected). A cycle cap fails closed (echo empty) rather
# than hang the PreToolUse hook.
_canon_path() { # <path>  -> canonical path on stdout
  local p="$1"
  if [[ -z "${_CANON_FORCE_PURE:-}" ]]; then
    if command -v grealpath >/dev/null 2>&1; then grealpath -m -- "$p" 2>/dev/null && return; fi
    if realpath -m -- / >/dev/null 2>&1; then realpath -m -- "$p" 2>/dev/null && return; fi
  fi
  # pure-bash work-list canonicalizer (realpath -m semantics: resolves symlinks
  # in EVERY position, incl. a target's prefix, via a re-processing queue).
  [[ "$p" != /* ]] && p="$PWD/$p"
  local out="" comp cand link iter=0 _oifs="$IFS"
  local -a pending=() tcomp=()
  # Scope IFS=/ to ONLY the field-splits below, then restore. bash 3.2 (macOS
  # system bash) mishandles a quoted array slice `"${arr[@]:1}"` while IFS is a
  # non-default single char — it collapses the slice to one element. Leaving
  # IFS=/ set for the whole function breaks the queue shift on every iteration.
  IFS=/
  set -f
  # shellcheck disable=SC2206  # deliberate IFS=/ word-split (globbing off via set -f) to seed the component queue
  pending=($p)
  set +f
  IFS="$_oifs"
  while [[ ${#pending[@]} -gt 0 ]]; do
    comp="${pending[0]}"
    # bash-3.2-safe shift: avoid slicing an array down to zero elements on
    # the RHS (older bash mishandles that under `set -u`); special-case the
    # last-element pop as an explicit empty assignment instead.
    if [[ ${#pending[@]} -le 1 ]]; then
      pending=()
    else
      pending=("${pending[@]:1}")
    fi
    case "$comp" in
      ''|.) continue ;;
      ..) out="${out%/*}" ;;
      *)
        cand="$out/$comp"
        if [[ -L "$cand" ]]; then
          iter=$((iter+1)); [[ "$iter" -gt 40 ]] && { printf '%s' ''; return 1; }
          link="$(readlink "$cand")"
          IFS=/
          set -f
          # shellcheck disable=SC2206  # deliberate IFS=/ word-split (globbing off via set -f) to split the symlink target into components
          tcomp=($link)
          set +f
          IFS="$_oifs"
          [[ "$link" == /* ]] && out=""      # absolute target: restart from root; relative: keep out
          pending=(${tcomp[@]+"${tcomp[@]}"} ${pending[@]+"${pending[@]}"})
        else
          out="$cand"
        fi ;;
    esac
  done
  [[ -z "$out" ]] && out="/"
  printf '%s' "$out"
}

# The repository the session works in: the first of $FARM_WORKTREE,
# $CLAUDE_PROJECT_DIR, . that is inside a git work tree (in a hook all three name
# the session worktree), printed as that work tree's top level so every later
# git/gh call runs at the root. rc 1 when none is.
_guard_repo_dir() {
  local d t
  for d in "${FARM_WORKTREE:-}" "${CLAUDE_PROJECT_DIR:-}" .; do
    [[ -n "$d" ]] || continue
    [[ "$(git -C "$d" rev-parse --is-inside-work-tree 2>/dev/null)" == true ]] || continue
    t="$(git -C "$d" rev-parse --show-toplevel 2>/dev/null)" && [[ -n "$t" ]] && { printf '%s\n' "$t"; return 0; }
  done
  return 1
}

# Direct-push tripwire (spec 4.3). Pure decider: deny when any `git … push`
# in the command text targets main/master — an explicit refspec destination,
# HEAD/@ or no refspec while the current branch is main/master, --all/--mirror,
# the matching refspec `:`, or a refspec with glob or brace characters (bash or
# git would expand it) — and on any `git send-pack`/`git receive-pack`.
# Reads the text like the guard's other rules (_guard_norm): quotes and
# backslashes removed, so a push named inside a quoted string also denies (a
# false positive only escalates).
# Segments split on ; & | ( ) and backtick, so `$(git push …)` is seen too;
# redirections are normalised first, so 2>&1 / &>f do not split a segment.
# The current branch is the caller's <current branch>, except: under
# `git -C <dir>` it is <dir>'s, taken from a <dir>=<branch> argument — when none
# is given the decider prints `need <dir>` and the caller asks again with it;
# after an earlier `git checkout`/`git switch` in the same command it cannot be
# known from the text, so a bare or HEAD push denies. A bare or HEAD push also
# denies when the -C dir cannot be resolved: its text is empty or holds `~` or
# `$` (the hook cannot expand it like the shell), or the caller answered
# <dir>=? (no work tree there). An empty branch (detached HEAD) allows.
# Known limits, not caught: a branch whose upstream is the default branch
# (bare `git push` from a feature branch tracking main); a push option that
# takes a value before the remote (`--repo x`, `-o x`) shifts the remote/refspec
# split; `--git-dir`/`--work-tree` are not followed for the current branch; git
# aliases (`git -c alias.p=push p origin main`, or one configured in git config)
# are not expanded. This is a tripwire; the boundary is branch protection, which
# the conductor checks.
_push_target_decide() { # <command> <current branch> [<dir>=<branch> ...]  -> deny|allow|need <dir>
  local n
  n="$(_guard_norm "$1")"; shift
  _push_target_scan "$n" "$@"
}

# _push_target_decide over text _guard_norm already read (the guard reads once).
_push_target_scan() { # <normalised command> <current branch> [<dir>=<branch> ...]
  local mk=$'\x1f' rm=$'\x1e' cmd="$1" cur="${2:-}" seg tok dst remote i n usecur cdir cbad br moved=0 p rd
  local -a w
  shift; shift
  # Split on ; & | ( ) and backtick with tr, not ${cmd//…}: linear on bash 3.2 too.
  [[ "$cmd" == *[\;\&\|\(\)\`]* ]] && { cmd="$(printf '%s.' "$cmd" | LC_ALL=C tr ';&|()`' '\n\n\n\n\n\n')"; cmd="${cmd%.}"; }
  while IFS= read -r seg; do
    read -r -a w <<<"$seg"
    n=${#w[@]}; i=0
    while [[ $i -lt $n ]]; do
      tok="${w[$i]}"; i=$((i+1))
      case "$tok" in
        git|*/git) ;;
        git-send-pack|*/git-send-pack|git-receive-pack|*/git-receive-pack) echo deny; return 0 ;;
        *) continue ;;
      esac
      # git's global options before the subcommand; these take a separate value.
      # Repeated -C combine like git does: an absolute one restarts the path.
      cdir=""; cbad=0
      while [[ $i -lt $n && "${w[$i]}" == -* ]]; do
        case "${w[$i]}" in
          -C) i=$((i+1)); tok="${w[$i]:-}"
              case "$tok" in ''|"$mk"|*'~'*|*'$'*) cbad=1 ;; esac
              if [[ "$tok" == /* ]]; then cdir="$tok"; else cdir="${cdir:+$cdir/}$tok"; fi ;;
          -c|--git-dir|--work-tree|--namespace|--config-env) i=$((i+1)) ;;
        esac
        i=$((i+1))
      done
      [[ $i -lt $n ]] || continue
      case "${w[$i]}" in
        checkout|switch) moved=1; continue ;;
        send-pack|receive-pack) echo deny; return 0 ;;   # a push by another name
        push) ;;
        *) continue ;;
      esac
      i=$((i+1)); remote=""; usecur=1; rd=0
      while [[ $i -lt $n ]]; do
        tok="${w[$i]}"; i=$((i+1))
        [[ "$tok" == "$rm" ]] && { rd=1; continue; }
        case "$tok" in
          --all|--mirror) echo deny; return 0 ;;
          -*|"$mk") rd=0; continue ;;   # an empty word is no remote and no refspec
          # Glob/brace characters expand (bash, or git's refs/heads/*:…), and
          # `x:` / `:` (the matching refspec) names no destination: deny.
          *[][{}*?]*|*:) echo deny; return 0 ;;
        esac
        tok="${tok#+}"; dst="${tok##*:}"; dst="${dst#refs/heads/}"; dst="${dst#heads/}"
        # A redirection target is no remote and no refspec, but is still checked
        # as a destination; so is the remote word (`git push <x> origin main`
        # makes main the remote). Deny bias: a false deny only escalates.
        if [[ "$rd" == 1 ]]; then
          rd=0
        elif [[ -z "$remote" ]]; then
          remote="$tok"
        else
          [[ "$usecur" == 1 ]] && usecur=0
          [[ "$dst" == HEAD || "$dst" == @ ]] && { usecur=2; continue; }   # @ is HEAD
        fi
        case "$dst" in main|master) echo deny; return 0 ;; esac
      done
      [[ "$usecur" == 0 ]] && continue
      [[ "$moved" == 1 ]] && { echo deny; return 0; }
      [[ "$cbad" == 1 ]] && { echo deny; return 0; }
      br="$cur"
      if [[ -n "$cdir" ]]; then
        br=" "   # no branch name contains a space: marks "not given"
        for p in "$@"; do [[ "$p" == "$cdir="* ]] && br="${p#"$cdir="}"; done
        [[ "$br" == " " ]] && { echo "need $cdir"; return 0; }
      fi
      case "$br" in main|master|'?') echo deny; return 0 ;; esac
    done
  done <<<"$cmd"
  echo allow
}

# The guard's one reading of a Bash command (every gh/push/merge rule reads it),
# on stdout, padded with a space each side. Bash's own word rules, deny-biased:
# backslash-newline joined, every backslash dropped (\x reads as x), quote
# characters removed — an empty pair that stands alone (whitespace or one of
# ; & | ( ) ` on both sides) becomes the empty-word marker $'\x1f', any other
# pair inside a word (ma''in) just goes — and redirections normalised: an
# operator glued to an fd target (2>&1, >&2, <&-) becomes a word break, any
# other (> >> < << <<< <> >| &> &>>, and a > after fd digits) the standalone
# word $'\x1e', split off a glued word (main>x -> main $'\x1e' x). Both markers
# are control characters stripped from the input first, so text cannot forge
# them. Quoted < and > count as operators too: that only adds denials, since
# the readers still check a redirection target.
# One awk pass over the bytes: linear on every bash (on bash 3.2 a byte loop, or
# a ${x//pat/} over the whole text, is quadratic and can outrun the hook timeout).
_guard_norm() { # <command>
  # Nothing to read (no \ quote < > or marker): the text is its own reading.
  if [[ "$1" != *[\\\"\'\<\>]* && "$1" != *$'\x1f'* && "$1" != *$'\x1e'* ]]; then
    printf ' %s ' "$1"; return 0
  fi
  printf '%s\n' "$1" | LC_ALL=C awk -v mk=$'\x1f' -v rm=$'\x1e' '
    function out(s) { printf "%s", s }
    function step(c) {
      if (op != "") {                        # inside a redirection operator
        if (tgt == 1) {
          if (index("0123456789", c)) return
          out(" "); op = ""; tgt = 0
        } else if (index("<>&|", c)) {
          op = op c; return
        } else if (substr(op, length(op)) == "&" && index("0123456789-", c)) {
          if (c == "-") { out(" "); op = ""; prev = "x"; return }
          tgt = 1; return
        } else {
          out(" " rm " "); op = ""
        }
        prev = "x"                           # a quote right after an operator is no standalone pair
      }
      if (c == "\"" || c == q) {
        if (pq == 1 && c == pqc) pq = 2
        else if (pq == 0 && index(sep, prev)) { out(amp); amp = ""; pq = 1; pqc = c }
        else pq = 0
        prev = c; return
      }
      if (pq == 2 && index(sep, c)) out(mk)
      pq = 0
      if (index("0123456789", c)) { out(amp); amp = ""; dig = dig c }
      else if (c == "&") { out(dig amp); dig = ""; amp = "&" }
      else if (c == ">") { dig = ""; amp = ""; op = ">" }     # fd digits and a & before > belong to it
      else if (c == "<") { out(amp); dig = ""; amp = ""; op = "<" }
      else { out(dig amp c); dig = ""; amp = "" }
      prev = c
    }
    BEGIN { q = sprintf("%c", 39); sep = " \t\n;&|()`"; prev = " "; out(" ") }
    {
      if (NR > 1 && !join) step("\n")         # a backslash-newline joins the lines
      n = split($0, ch, ""); join = (n > 0 && ch[n] == "\\")
      for (i = 1; i <= n; i++) if (ch[i] != "\\" && ch[i] != mk && ch[i] != rm) step(ch[i])
    }
    END {
      if (op != "") out(tgt == 1 ? " " : (" " rm " "))
      if (pq == 2) out(mk)
      out(dig amp " ")
    }'
}

# Quoted strings as one word: whitespace and ; & | ( ) ` < > inside quotes
# become $'\x1d' (stripped from the input first, so text cannot forge it).
# rc 1 when a quote is left open, or holds $ or a backtick (bash expands those
# inside double quotes), or $ starts an ANSI-C/locale string ($'…', $"…");
# with <keep>, those expansions are kept (the text is still printed in full).
_guard_qmark() { # <command> [keep]
  local o rc
  # No quote and no marker: nothing to mark, nothing left open.
  if [[ "$1" != *[\"\']* && "$1" != *$'\x1d'* ]]; then printf '%s' "$1"; return 0; fi
  o="$(printf '%s\n' "$1" | LC_ALL=C awk -v gs=$'\x1d' -v keep="${2:-}" '
    function step(c,   was) {
      was = dol; dol = ""
      if (esc != "") {
        esc = ""                               # an escaped character stays as is
      } else if (qc == "") {
        if (c == "\"" || c == q) { if (keep == "" && was != "") { bad = 1; exit } qc = c; printf "%s", c; return }
        if (c == "$") dol = 1
        else if (c == "\\") esc = 1
      } else if (c == qc) {
        qc = ""
      } else {
        if (keep == "" && (c == "$" || c == "`")) { bad = 1; exit }
        if (qc == "\"" && c == "\\") esc = 1
      }
      if (qc != "" && c != qc && index(" \t\n\v\f\r;&|()`<>", c)) c = gs
      printf "%s", c
    }
    BEGIN { q = sprintf("%c", 39) }
    {
      if (NR > 1) step("\n")
      n = split($0, ch, "")
      for (i = 1; i <= n; i++) if (ch[i] != gs) step(ch[i])
    }
    END { if (bad) exit 2; printf "."; exit (qc != "") }')" && rc=0 || rc=$?
  [[ "$rc" == 2 ]] && return 1
  printf '%s' "${o%.}"
  return "$rc"
}

# The merge target, over normalised text (_guard_norm of _guard_qmark), split
# on ; & | ( ) and backtick. Every `gh` word starts an invocation:
# `gh [flags] pr [flags] merge …` is the porcelain form, `gh [flags] api …` with
# a `pulls/<x>/merge` word the REST form. Prints one line:
#   none                           no merge in the text
#   pr <n> | rest <owner/repo> <n> exactly one merge, naming one number
#   deny repo|ghrepo|cd|admin|number
#   quoted                         a merge, and a $'\x1d' word outside a flag value
# Porcelain selectors: the words after `merge` that are no flag, no flag's value
# and no redirection target. REST: exactly one `repos/<o>/<r>/pulls/<n>/merge`.
# Deny bias: a merge inside echo/grep text counts too; a false deny only escalates.
_merge_scan() { # <normalised command>
  local rm=$'\x1e' gs=$'\x1d' cmd="$1" seg tok i n sub r a nsel sel opt
  local merges=0 num="" slug="" repo=0 admin=0 cd=0 env=0 bad=0 q=0
  local rre='^/?repos/([^/]+)/([^/]+)/pulls/([0-9]+)/merge$'
  local -a w
  # Split on ; & | ( ) and backtick with tr, not ${cmd//…}: linear on bash 3.2 too.
  [[ "$cmd" == *[\;\&\|\(\)\`]* ]] && { cmd="$(printf '%s.' "$cmd" | LC_ALL=C tr ';&|()`' '\n\n\n\n\n\n')"; cmd="${cmd%.}"; }
  while IFS= read -r seg; do
    read -r -a w <<<"$seg"
    n=${#w[@]}; i=0
    while [[ $i -lt $n ]]; do
      tok="${w[$i]}"; i=$((i+1))
      [[ "$tok" == *"$gs"* ]] && q=1
      case "$tok" in
        # gh would resolve the repository from a directory the guard did not check.
        cd|*/cd|pushd|*/pushd|-C*|--chdir*|GIT_DIR=*|GIT_WORK_TREE=*) cd=1; continue ;;
        GH_REPO=*|GH_HOST=*) env=1; continue ;;
        gh|*/gh) ;;
        *) continue ;;
      esac
      r=0; a=0; sub=""
      # gh's flags, the command word, pr's flags, the subcommand word
      while [[ $i -lt $n ]]; do
        tok="${w[$i]}"; i=$((i+1))
        [[ "$tok" == *"$gs"* ]] && q=1
        case "$tok" in
          -R|--repo|--hostname) r=1; i=$((i+1)) ;;
          --repo=*|--hostname=*|-[!-]*R*) r=1 ;;
          -*) ;;
          *) if [[ "$sub" == pr ]]; then sub="pr $tok"; break; fi
             sub="$tok"; [[ "$tok" == pr ]] || break ;;
        esac
      done
      if [[ "$sub" == "pr merge" ]]; then
        nsel=0; sel=""; opt=1
        while [[ $i -lt $n ]]; do
          tok="${w[$i]}"; i=$((i+1))
          [[ "$tok" == "$rm" ]] && { i=$((i+1)); continue; }   # skip its target
          [[ "$tok" == *"$gs"* ]] && q=1   # a flag's value is skipped unread
          if [[ "$opt" == 1 ]]; then
            case "$tok" in
              --) opt=0; continue ;;
              -R|--repo) r=1; i=$((i+1)); continue ;;
              --repo=*|-[!-]*R*) r=1; continue ;;
              --admin|--admin=*) a=1; continue ;;
              -b|--body|-F|--body-file|-t|--subject|-A|--author-email|--match-head-commit) i=$((i+1)); continue ;;
              -?*) continue ;;
            esac
          fi
          nsel=$((nsel+1)); sel="$tok"
        done
        merges=$((merges+1)); repo=$((repo|r)); admin=$((admin|a))
        if [[ "$nsel" == 1 && "$sel" =~ ^[0-9]+$ ]]; then num="$sel"; slug=""; else bad=1; fi
      elif [[ "$sub" == api ]]; then
        nsel=0; sel=""
        while [[ $i -lt $n ]]; do
          tok="${w[$i]}"; i=$((i+1))
          [[ "$tok" == *"$gs"* ]] && q=1
          case "$tok" in
            --hostname) r=1; i=$((i+1)) ;;
            --hostname=*) r=1 ;;
            *pulls/*/merge*) nsel=$((nsel+1)); sel="$tok" ;;
          esac
        done
        [[ "$nsel" == 0 ]] && continue
        merges=$((merges+1)); repo=$((repo|r))
        if [[ "$nsel" == 1 && "$sel" =~ $rre ]]; then
          num="${BASH_REMATCH[3]}"; slug="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
        else
          bad=1
        fi
      fi
    done
  done <<<"$cmd"
  [[ "$merges" == 0 ]] && { echo none; return 0; }
  [[ "$q" == 1 ]] && { echo quoted; return 0; }
  [[ "$repo" == 1 ]] && { echo deny repo; return 0; }
  [[ "$env" == 1 ]] && { echo deny ghrepo; return 0; }
  [[ "$cd" == 1 ]] && { echo deny cd; return 0; }
  [[ "$admin" == 1 ]] && { echo deny admin; return 0; }
  [[ "$bad" == 1 || "$merges" != 1 ]] && { echo deny number; return 0; }
  if [[ -n "$slug" ]]; then echo "rest $slug $num"; else echo "pr $num"; fi
}

# The pull-request number one merge in <command> names (spec 4.3, PD6); rc 1
# when none or more than one selector parses, or the text cannot be read as
# bash would. A plain merge (_merge_plain) is read directly; anything else
# with each quoted string kept as one word (_guard_qmark), and rc 1 when a
# quoted string with a space or separator sits outside a merge flag's value.
# The plan's interface for the merge selector, kept with its tested contract;
# the guard itself admits only a plain merge (_merge_plain) and takes the
# number from it, so _merge_scan is reached from here only.
_merge_pr_number() { # <command>
  local v
  if v="$(_merge_plain "$1")"; then printf '%s\n' "${v##* }"; return 0; fi
  v="$(_guard_qmark "$1")" || return 1
  v="$(_merge_scan "$(_guard_norm "$v")")"
  case "$v" in pr\ *|rest\ *) printf '%s\n' "${v##* }" ;; *) return 1 ;; esac
}

# A merge as one plain command (fix round 1 ruling): the whole text is
#   gh pr merge <digits> plus only --squash --merge --rebase --auto
#   --delete-branch -s -m -r -d and --match-head-commit <40 hex>, in any order; or
#   gh api repos/<o>/<r>/pulls/<n>/merge with -X PUT or --method PUT before or after.
# Letters, digits, space, tab and / . _ - only. Prints `pr <n>` or
# `rest <owner/repo> <n>`; rc 1 otherwise.
_merge_plain() { # <command>
  local n="" i re='^(-X PUT |--method PUT )?repos/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/pulls/([0-9]+)/merge( -X PUT| --method PUT)?$'
  local -a w
  [[ "$1" =~ ^[A-Za-z0-9\ $'\t'/._-]*$ ]] || return 1
  read -r -a w <<<"$1"
  if [[ "${w[*]:0:3}" == "gh pr merge" ]]; then
    for ((i=3; i<${#w[@]}; i++)); do
      case "${w[$i]}" in
        --squash|--merge|--rebase|--auto|--delete-branch|-s|-m|-r|-d) ;;
        --match-head-commit) i=$((i+1)); [[ "${w[$i]:-}" =~ ^[0-9a-f]{40}$ ]] || return 1 ;;
        *) [[ -z "$n" && "${w[$i]}" =~ ^[0-9]+$ ]] || return 1; n="${w[$i]}" ;;
      esac
    done
    [[ -n "$n" ]] || return 1
    echo "pr $n"; return 0
  fi
  [[ "${w[*]:0:2}" == "gh api" && "${w[*]:2}" =~ $re ]] || return 1
  [[ -n "${BASH_REMATCH[1]}" && -z "${BASH_REMATCH[5]}" || -z "${BASH_REMATCH[1]}" && -n "${BASH_REMATCH[5]}" ]] || return 1
  echo "rest ${BASH_REMATCH[2]}/${BASH_REMATCH[3]} ${BASH_REMATCH[4]}"
}

# A gh word: gh, a path ending in /gh, glued to ( { ! $ ` or =.
_GUARD_GH_RE='(^|[^[:alnum:]_.-])gh([^[:alnum:]_.-]|$)'

# gh as a tripwire (round 2 ruling, fix wave). Pure decider: `ok`, or
# `deny <why>` with why = config (text touches .config/gh, GH_CONFIG_DIR or
# XDG_CONFIG_HOME: aliases, hosts), eval (eval with a gh word), ansi ($'…'/$"…
# with a gh word), graphql (gh api graphql with $, a backtick or < anywhere: a
# query built by an expansion or read from a file), or a word-scan verdict of
# _gh_words_check (admin, unknown, literal, glob, apiadmin, apiwrite). Later arguments
# may hold expansions (gh pr create --body "$(cat f)"). Known limit: a gh word
# that is itself built by an expansion is not seen.
# <normalised> is _guard_norm of <command>, computed when not given; the raw
# <command> is read where expansion characters matter.
_gh_literal_decide() { # <command> [<normalised>]
  local c="$1" t="${2:-}" v re
  [[ -n "$t" ]] || t="$(_guard_norm "$c")"
  re='\.config/([^[:alnum:]_.-]|g[^i]|g$|gi[^t]|gi$)|GH_CONFIG_DIR'
  [[ "$t" =~ $re ]] && { echo deny config; return 0; }
  [[ "$t" =~ $_GUARD_GH_RE ]] || { echo ok; return 0; }
  [[ "$c" == *XDG_CONFIG_HOME* ]] && { echo deny config; return 0; }
  re='(^|[^[:alnum:]_.-])eval([^[:alnum:]_.-]|$)'
  [[ "$t" =~ $re ]] && { echo deny eval; return 0; }
  [[ "$c" == *\$\'* || "$c" == *\$\"* ]] && { echo deny ansi; return 0; }
  re='(^|[^[:alnum:]_.-])[Gg][Rr][Aa][Pp][Hh][Qq][Ll]([^[:alnum:]_.-]|$)'
  [[ "$t" =~ $re && "$c" == *[\$\`\<]* ]] && { echo deny graphql; return 0; }
  # Read twice: with each quoted string one word (its quotes visible), and the
  # normalised reading (a gh inside `bash -c '…'` is seen too).
  v="$(_gh_words_check "$(_guard_qmark "$c" keep)")"
  [[ "$v" == ok ]] || { echo "$v"; return 0; }
  _gh_words_check "$t"
}

# The word scan of _gh_literal_decide over one reading of the text: `ok` or
# `deny <why>`. Every gh word (not a standalone gh or */gh argument of which,
# type, hash or command -v/-V) needs a literal command word that is one of gh's built-in
# commands — an alias or extension cannot be read (unknown); alias, extension
# and config set are off-limits (admin); gh with no command word passes only
# with --version or --help. pr needs a literal verb, api a literal endpoint
# (`echo pr merge 5 | xargs gh` has neither: literal) without glob or brace
# characters other than {owner} {repo} {branch} — a `?` only as a query string,
# no % (glob) — and a write (-X/--method other than GET, or a field/--input) to a
# git/, contents, merges or branches/ endpoint, in any case, denies (apiwrite); to
# rulesets, protection, statuses/, check-runs, check-suites, collaborators,
# actions/permissions, transfer, the bare repos/<owner>/<repo> or repositories/<id>,
# or with a . or .. path segment denies (apiadmin). A
# double-quoted endpoint of plain characters is literal.
# The word split of _gh_words_check and _merge_candidate_scan, one awk pass:
# ; & | < > and newline become " ; ". With <stripped>, a second line holds each
# word with \ " ' deleted ($'\x1c' for a word that empties, keeping words aligned).
_guard_words() { # [stripped]  < text
  LC_ALL=C awk -v two="${1:-}" -v e=$'\x1c' '
    BEGIN { q = sprintf("%c", 39) }
    { gsub(/[;&|<>]/, " ; "); a = a (NR > 1 ? " ; " : "") $0 }
    END {
      print a
      if (two == "") exit
      n = split(a, f)
      for (i = 1; i <= n; i++) {
        s = f[i]; gsub(/\\/, "", s); gsub(/"/, "", s); gsub(q, "", s)
        printf "%s ", (s == "" ? e : s)
      }
      print ""
    }'
}

_gh_words_check() { # <text>
  local c="$1" rm=$'\x1e' tok t sub verb ep fl meth wr i n b1="" b2=""
  local are litre='[$`"'"'"'\]' globre='[][{}*?~,]' gre='[({!$`=]gh$'
  local -a w w2
  # ; & | < > newline end a command: a word of its own. w2[i] is w[i] with
  # \ " ' deleted, so g\h and "gh" are gh too. Text with none of those: w2 is w.
  local sw=0
  if [[ "$c" == *[\;\&\|\<\>\\\"\']* || "$c" == *$'\n'* ]]; then
    { read -r -a w; read -r -a w2; } < <(printf '%s\n' "$c" | _guard_words 1); sw=1
  else
    read -r -a w <<<"$c"
  fi
  n=${#w[@]}; i=0
  while [[ $i -lt $n ]]; do
    tok="${w[$i]}"; i=$((i+1))
    t=""; [[ "$tok" == *h* ]] && { t="$tok"; [[ "$sw" == 1 ]] && t="${w2[$((i-1))]}"; }
    if [[ "$t" != gh && "$t" != */gh ]] && ! [[ "$t" =~ $gre ]]; then
      b2="$b1"; b1="$tok"; continue
    fi
    # The exemption covers only a standalone gh word: never x$(gh or gh=$(gh.
    if [[ "$t" == gh || "$t" =~ ^[[:alnum:]_./-]*/gh$ ]]; then
      case "$b1" in which|type|hash) b2="$b1"; b1="$tok"; continue ;; esac
      [[ "$b2" == command && "$b1" == -[vV] ]] && { b2="$b1"; b1="$tok"; continue; }
    fi
    sub=""; verb=""; ep=""; fl=""; meth=""; wr=0
    while [[ $i -lt $n ]]; do
      tok="${w[$i]}"; i=$((i+1))
      [[ "$tok" == ";" ]] && break
      [[ "$tok" == "$rm" ]] && { i=$((i+1)); continue; }   # a redirection and its target
      if [[ "$sub" == api ]]; then
        case "$tok" in   # gh api: flags and their values, up to and after the endpoint
          -X|--method) meth="${w[$i]:-}"; i=$((i+1)); continue ;;
          -X?*) meth="${tok#-X}"; continue ;;
          --method=*) meth="${tok#*=}"; continue ;;
          -f|-F|--field|--raw-field|--input) wr=1; i=$((i+1)); continue ;;
          -f?*|-F?*|--field=*|--raw-field=*|--input=*) wr=1; continue ;;
          -H|--header|-p|--preview|-q|--jq|-t|--template|--hostname|--cache) i=$((i+1)); continue ;;
          -*) continue ;;
        esac
        [[ -n "$ep" ]] && continue
        ep="$tok"
        [[ "$ep" =~ ^\"([^\"\$\`\\]*)\"$ ]] && ep="${BASH_REMATCH[1]}"
        [[ "$ep" =~ $litre ]] && { echo deny literal; return 0; }
        [[ "$ep" == *%* ]] && { echo deny glob; return 0; }   # %2F, %6D… are decoded by GitHub
        ep="$(printf '%s' "$ep" | tr '[:upper:]' '[:lower:]')"   # GitHub routes /GIT/ like /git/
        t="${ep//\{owner\}/}"; t="${t//\{repo\}/}"; t="${t//\{branch\}/}"
        [[ "$t" =~ [][{}*] || "$t" =~ \?[A-Za-z0-9_]*([^A-Za-z0-9_=]|$) || "$t" == *\?=* ]] \
          && { echo deny glob; return 0; }
        continue
      fi
      [[ "$tok" =~ $litre ]] && { echo deny literal; return 0; }
      case "$tok" in
        -R|--repo|--hostname) i=$((i+1)); continue ;;
        --version|--help) fl=1; continue ;;
        -*) continue ;;
      esac
      [[ "$tok" =~ $globre ]] && { echo deny literal; return 0; }
      [[ -z "$sub" ]] && { sub="$tok"; continue; }
      verb="$tok"; break
    done
    b1=""; b2=""
    if [[ -z "$sub" ]]; then
      [[ -n "$fl" ]] && continue
      echo deny literal; return 0
    fi
    case "$sub" in
      pr) [[ -n "$verb" ]] || { echo deny literal; return 0; } ;;
      api) [[ -n "$ep" ]] || { echo deny literal; return 0; }
           if [[ "$wr" == 1 || ( -n "$meth" && "$meth" != [Gg][Ee][Tt] ) ]]; then
             # Canonical path: no scheme/host, query or fragment; // collapsed.
             t="${ep%%\?*}"; t="${t%%#*}"
             are='^https?://[^/]*(.*)$'; [[ "$t" =~ $are ]] && t="${BASH_REMATCH[1]}"
             while [[ "$t" == *//* ]]; do t="${t%%//*}/${t#*//}"; done
             case "/$t/" in */./*|*/../*) echo deny apiadmin; return 0 ;; esac
             case "/$t" in */rulesets*|*/protection*|*/statuses/*|*/check-runs*|*/check-suites*|*/collaborators*|*/actions/permissions*|*/transfer*)
               echo deny apiadmin; return 0 ;; esac
             # The bare repository endpoint (settings: default branch, visibility, archive).
             are='^/?(repos/[^/]+/[^/]+|repositories/[0-9]+)/?$'
             [[ "$t" =~ $are ]] && { echo deny apiadmin; return 0; }
             case "/$t" in */git/*|*/contents*|*/merges*|*/branches/*) echo deny apiwrite; return 0 ;; esac
           fi ;;
      alias|extension) echo deny admin; return 0 ;;
      config) [[ "$verb" == set ]] && { echo deny admin; return 0; } ;;
      attestation|auth|browse|cache|co|codespace|completion|gist|gpg-key|issue|label|org|project|release|repo|ruleset|run|search|secret|ssh-key|status|variable|workflow) ;;
      *) echo deny unknown; return 0 ;;
    esac
  done
  echo ok
}

# A merge candidate (round 3/4 rulings), on the normalised text (_guard_norm,
# computed when not given) read twice: with $ ( ) { } and backticks deleted
# (mer$()ge -> merge), and with them and = turned into word breaks
# (x=$(gh pr merge … -> x gh pr merge …). rc 0 when either reading has
#   a gh word followed in its segment (flags and -R/--repo/--hostname values
#   allowed) by `pr` and then a verb that is not a known non-merge verb
#   (fail closed: `merge`, an unknown verb or none);
#   `pulls/<x>/merge`; or
#   a gh word with graphql and merge, mutation, an @file or --input (any case).
# A PR title or comment that says "merge" is not one.
_merge_candidate() { # <command> [<normalised>]
  local t="${2:-}" a
  [[ -n "$t" ]] || t="$(_guard_norm "$1")"
  [[ "$t" == *[\$\`\(\)\{\}=]* ]] || { _merge_candidate_scan "$t"; return; }   # both readings are t
  # tr, not ${t//…}: linear on bash 3.2 too ('.' keeps trailing newlines).
  a="$(printf '%s.' "$t" | LC_ALL=C tr -d '$`(){}')"; _merge_candidate_scan "${a%.}" && return 0
  a="$(printf '%s.' "$t" | LC_ALL=C tr '$`(){}=' '       ')"; _merge_candidate_scan "${a%.}"
}

_merge_candidate_scan() { # <text>
  local t="$1" tok sub i n rc=1
  local -a w
  [[ "$(printf '%s' "$t" | tr '[:upper:]' '[:lower:]')" =~ pulls/[^/[:space:]]*/merge ]] && return 0
  [[ "$t" =~ $_GUARD_GH_RE ]] || return 1
  shopt -q nocasematch || { shopt -s nocasematch; rc=0; }
  if [[ "$t" == *graphql* && ( "$t" == *merge* || "$t" == *mutation* || "$t" == *@* || "$t" == *--input* ) ]]; then
    [[ "$rc" == 0 ]] && shopt -u nocasematch
    return 0
  fi
  [[ "$rc" == 0 ]] && shopt -u nocasematch
  if [[ "$t" == *[\;\&\|\<\>]* || "$t" == *$'\n'* ]]; then
    read -r -a w < <(printf '%s\n' "$t" | _guard_words)
  else
    read -r -a w <<<"$t"
  fi
  n=${#w[@]}; i=0
  while [[ $i -lt $n ]]; do
    tok="${w[$i]}"; i=$((i+1))
    [[ "$tok" == gh || "$tok" == */gh ]] || continue
    sub=""
    while [[ $i -lt $n ]]; do
      tok="${w[$i]}"; i=$((i+1))
      case "$tok" in
        ";") break ;;
        -R|--repo|--hostname) i=$((i+1)) ;;
        -*) ;;
        *) if [[ "$sub" == pr ]]; then
             case "$tok" in
               create|view|list|diff|checks|status|comment|edit|ready|checkout|close|reopen|review|lock|unlock) sub=""; break ;;
             esac
             return 0
           fi
           sub="$tok"; [[ "$tok" == pr ]] || break ;;
      esac
    done
    [[ "$sub" == pr ]] && return 0   # pr with no verb
  done
  return 1
}

# The host of a URL (scheme://[user@]host[:port]/…, or scp-like [user@]host:…);
# rc 1 when there is none.
_guard_url_host() { # <url>
  local re='^[A-Za-z][A-Za-z0-9+.-]*://([^/@]*@)?([^/:]+)'
  [[ "$1" =~ $re ]] || { re='^([^/:@]*@)?([^/:]+):'; [[ "$1" =~ $re ]] || return 1; }
  printf '%s\n' "${BASH_REMATCH[2]}"
}

# owner/repo of a URL (SSH, HTTPS, scp-like); rc 1 when it cannot be parsed.
_guard_url_slug() { # <url>
  local u="${1%/}" re='^([A-Za-z][A-Za-z0-9+.-]*://[^/]+/|[^/:]+:)([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)$'
  u="${u%.git}"
  [[ "$u" =~ $re ]] || return 1
  printf '%s/%s\n' "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
}

# owner/repo from <dir>'s remote.origin.url as written (SSH, HTTPS, scp-like);
# git config, not `git remote get-url`, which applies insteadOf rewrites. rc 1
# when it cannot be parsed.
_guard_origin_slug() { # <dir>
  local u
  u="$(git -C "$1" config --get remote.origin.url 2>/dev/null)" || return 1
  _guard_url_slug "$u"
}

# Run <command…>; rc 124 when it outlives <seconds>. Uses timeout/gtimeout when
# present, else a background watchdog (bash 3.2-safe).
_guard_bounded() { # <seconds> <command…>
  local s="$1" t pid w wrc rc; shift
  for t in timeout gtimeout; do
    command -v "$t" >/dev/null 2>&1 && { "$t" "$s" "$@"; return; }
  done
  "$@" & pid=$!
  # The watchdog's fds go to /dev/null so it never holds a caller's $(…) pipe open.
  # On TERM it kills and reaps its own sleep, so no orphan sleep outlives the call.
  # shortcut: a grandchild of <command> is not killed; fine for git/gh, which exit on TERM.
  ( sp=""; trap '[[ -n "$sp" ]] && kill -TERM "$sp" 2>/dev/null && wait "$sp"; exit 1' TERM
    sleep "$s" & sp=$!; wait "$sp"; kill -TERM "$pid" 2>/dev/null; exit 0 ) >/dev/null 2>&1 & w=$!
  wait "$pid"; rc=$?
  kill -TERM "$w" 2>/dev/null; wait "$w"; wrc=$?
  [[ "$wrc" == 0 ]] && rc=124   # the watchdog ran to the end: the bound expired
  return "$rc"
}

# The merge gate's time left for one bounded call: <bound>, or less when the
# gate's 90 s in all (the hook times out, failing open, at 120 s) would be
# passed after <elapsed> seconds; rc 1 when no time is left.
_guard_budget() { # <bound> <elapsed>
  local left
  [[ "$1" =~ ^[0-9]+$ && "$2" =~ ^[0-9]+$ && "$1" != 0?* && "$2" != 0?* ]] || return 1   # not a decimal: deny
  left=$((90 - $2))
  [[ "$left" -gt 0 ]] || return 1
  if [[ "$left" -lt "$1" ]]; then echo "$left"; else echo "$1"; fi
}

# Globs no project list can remove (PD3): a function, so it cannot be missing.
# Written dir/* because `[[ "$f" == $glob ]]` lets * cross '/'. Agent instruction
# files (CLAUDE.md, CLAUDE.local.md, AGENTS.md): a PR must not steer its reviewer.
_guard_mandatory_globs() {
  printf '%s\n' '.github/workflows/*' '.github/actions/*' 'CODEOWNERS' '*CODEOWNERS' \
    '.claude/*' '.agent-farm/*' 'docs/superpowers/handoffs/*' 'docs/superpowers/plans/*' \
    'CLAUDE.md' '*/CLAUDE.md' 'CLAUDE.local.md' '*/CLAUDE.local.md' 'AGENTS.md' '*/AGENTS.md'
}

# The default branch's remote-tracking ref in <dir> (PD4): the target of
# origin/HEAD when it resolves, else origin/main, else origin/master. rc 1 if none.
_guard_main_ref() { # <dir>
  local d="$1" r
  r="$(git -C "$d" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null)" || r=""
  if [[ "$r" == refs/remotes/origin/?* ]] && git -C "$d" rev-parse -q --verify "$r^{commit}" >/dev/null 2>&1; then
    printf '%s\n' "${r#refs/remotes/}"; return 0
  fi
  for r in origin/main origin/master; do
    git -C "$d" rev-parse -q --verify "refs/remotes/$r^{commit}" >/dev/null 2>&1 && { printf '%s\n' "$r"; return 0; }
  done
  return 1
}

# The merge gate's globs: the mandatory list, then the project list as committed
# at <ref> (never the work tree's copy), or — only when a successful listing of
# <ref>'s tree shows no .agent-farm/protected-paths.txt — the plugin defaults.
# rc 1 when the tree cannot be listed or the file cannot be read; rc 4 when the
# defaults are needed and cannot be found; rc 5 when the project list is over
# 65536 bytes or 2000 lines (it is matched against every file, inside the
# hook's time limit).
_guard_policy_globs() { # <dir> <ref>
  local d="$1" ref="$2" pp e nl
  _guard_mandatory_globs
  e="$(git -C "$d" ls-tree --full-tree --name-only "$ref" -- .agent-farm/protected-paths.txt 2>/dev/null)" || return 1
  if [[ -n "$e" ]]; then
    # <ref>:<path> is root-relative (only <ref>:./<path> is relative to $d).
    e="$(git -C "$d" cat-file -s "$ref:.agent-farm/protected-paths.txt" 2>/dev/null)" || return 1
    [[ "$e" =~ ^[0-9]+$ ]] || return 1
    [[ "$e" -le 65536 ]] || return 5
    pp="$(git -C "$d" show "$ref:.agent-farm/protected-paths.txt" 2>/dev/null)" || return 1
    nl="${pp//[!$'\n']/}"
    [[ "${#nl}" -lt 2000 ]] || return 5
    printf '%s\n' "$pp"   # a list without a final newline must not lose its last glob
    return 0
  fi
  pp="${CLAUDE_PLUGIN_ROOT:-$(_script_dir)/..}/defaults/protected-paths.txt"
  [[ -f "$pp" ]] || return 4
  cat "$pp" && echo
}
# Fix B (spec 4.3 B): the verdict on `gh pr checks --required --json name,bucket`
# output. At least one required check; every one `pass`, or `pending` when <auto>
# is 1; skipping is not passed. Anything unreadable (no jq, not an array of
# objects with a known bucket) is deny-undetermined. No de-duplication by name.
_merge_checks_decide() { # <checks_json> <auto: 0|1>
  local b k='(pass|fail|pending|skipping|cancel)'
  command -v jq >/dev/null 2>&1 || { echo deny-undetermined; return 0; }
  b="$(jq -rs 'if length == 1 and (.[0] | type) == "array"
                  and all(.[0][]; type == "object" and (.bucket | type) == "string")
               then (.[0] | if length == 0 then "none" else [.[].bucket] | unique | join(" ") end)
               else "bad" end' <<<"$1" 2>/dev/null)" || b=bad
  [[ "$b" == none ]] && { echo deny-none; return 0; }
  [[ "$b" =~ ^$k(\ $k)*$ ]] || { echo deny-undetermined; return 0; }
  case " $b " in
    *" fail "*|*" cancel "*) echo deny-failing ;;
    *" skipping "*) echo deny-skipped ;;
    *" pending "*) if [[ "$2" == 1 ]]; then echo allow; else echo deny-pending; fi ;;
    *) echo allow ;;
  esac
}
[[ -n "${GUARD_DEFINE_ONLY:-}" ]] && return 0 2>/dev/null || true

INPUT="$(cat)"
TOOL="$(jq -r '.tool_name // empty' <<<"$INPUT")"
# The Bash tool's working directory, kept between calls (hook input `cwd`).
HOOK_CWD="$(jq -r '.cwd // empty' <<<"$INPUT")"

# Scope: this guard governs ONLY autonomous farm agents (implementer/QA/
# scout/janitor), which export FARM_AGENT=1 via farm-lib.sh. Operator and
# other interactive sessions (and their subagents) are not farm agents and
# pass through untouched — they have their own controls (permission prompts,
# human oversight). Farm agents run with --dangerously-skip-permissions, so
# for THEM this hook is the safety net and stays fail-closed below.
# AGENT_NAME=farm-* is a defence-in-depth fallback: a farm agent can never
# slip through even if FARM_AGENT is somehow unset but its identity is set.
[[ "${FARM_AGENT:-}" == "1" || "${AGENT_NAME:-}" == farm-* ]] || exit 0

case "$TOOL" in
  Bash)
    CMD="$(jq -r '.tool_input.command // empty' <<<"$INPUT")"
    GUARD_T0=$SECONDS   # the merge gate's 90 s budget counts from here
    # One reading of the text for every gh/push/merge rule (_guard_norm). A
    # cheap reading first (backslash-newline joined, \ " ' dropped): the full
    # one only splits words further, so when the cheap one names no gh word and
    # no push, none of those rules can fire and it stands in for the full one.
    # Bounded input: the full reading and the checks on it must finish well
    # inside the hook's timeout, so a long command that names gh or push is not
    # read at all.
    # (awk, not ${CMD//…}: linear on bash 3.2 too; '.' keeps trailing newlines)
    GN="$CMD"
    if [[ "$GN" == *[\\\"\']* ]]; then
      GN="$(printf '%s\n' "$CMD" | LC_ALL=C awk -v q="'" '{ s = $0; j = sub(/\\$/, "", s)
        gsub(/\\/, "", s); gsub(/"/, "", s); gsub(q, "", s)
        printf "%s%s", (NR > 1 && !pj ? "\n" : ""), s; pj = j }'; printf .)"; GN="${GN%.}"
    fi
    if [[ "$GN" =~ $_GUARD_GH_RE || "$GN" == *push* || "$GN" == *send-pack* || "$GN" == *receive-pack* ]]; then
      [[ "$(LC_ALL=C; echo "${#CMD}")" -gt 16384 ]] \
        && deny "command too large for the guard to check (over 16384 bytes, with gh or push in it) — write long content to a file first, then run the gh/git command on its own."
      GN="$(_guard_norm "$CMD")"
    else
      GN=" $GN "
    fi

    # --- AWS: repair & expand = allowed; destroy & spend = human decision ---
    # Allowed implicitly: describe-*/get-*/list-*/tail, s3 ls/cp, update-*,
    # put-*, modify-*, create-* (expansion), restart/redeploy operations.
    if grep -qE '(^|[;&|[:space:]])aws[[:space:]]' <<<"$CMD"; then
      grep -qE 'aws[[:space:]]+[a-z0-9-]+[[:space:]]+[a-z0-9-]*(delete|terminate|remove|release|revoke|deregister|disable|purge)[a-z0-9-]*' <<<"$CMD" \
        && deny "destructive AWS action (delete/terminate/revoke/...) requires a human. Repair and expansion are allowed; removal is not. Escalate (move the task to 'escalated')."
      grep -qE 'aws[[:space:]]+s3[[:space:]]+(rb|rm)([[:space:]]|$)|aws[[:space:]]+s3[[:space:]]+sync[^|;&]*--delete' <<<"$CMD" \
        && deny "S3 deletion requires a human."
      grep -qE 'aws[[:space:]]+iam[[:space:]]+(create|put|attach|detach|update|add|tag|untag|set)' <<<"$CMD" \
        && deny "IAM mutations are off-limits — agents must not change their own permissions."
      grep -qE 'aws[[:space:]]+(organizations|account)[[:space:]]|aws[[:space:]]+[a-z0-9-]+[[:space:]]+purchase-|savingsplans|marketplace[^|;&]*subscribe|create-reserved' <<<"$CMD" \
        && deny "account-level / purchasing AWS actions require a human."
      grep -qE 'aws[[:space:]]+cloudtrail[[:space:]]+(stop-logging|put-event-selectors)|aws[[:space:]]+config[[:space:]]+(stop|put)-' <<<"$CMD" \
        && deny "tampering with audit/logging requires a human."
    fi
    # Other clouds + the box's own provider stay fully blocked (hcloud could
    # delete the very server this farm runs on).
    grep -qE '(^|[;&|[:space:]])(gcloud|az|doctl|hcloud)([[:space:]]|$)' <<<"$CMD" \
      && deny "non-AWS cloud CLIs are off-limits for farm agents."
    # IaC: plan/preview allowed, mutation is a human decision.
    grep -qE '(^|[;&|[:space:]])terraform[[:space:]]+(apply|destroy|import|state[[:space:]]+rm)' <<<"$CMD" \
      && deny "terraform mutations require a human (terraform plan is allowed)."
    grep -qE '(^|[;&|[:space:]])(pulumi[[:space:]]+(up|destroy)|cdk[[:space:]]+(deploy|destroy))' <<<"$CMD" \
      && deny "IaC deploy/destroy requires a human (preview/diff is allowed)."
    grep -qE '(^|[;&|[:space:]])kubectl[[:space:]]+(delete|drain|replace[^|;&]*--force)' <<<"$CMD" \
      && deny "kubectl destructive operations require a human."

    # --- gh tripwire: literal subcommands, gh's own config off-limits --------
    case "$(_gh_literal_decide "$CMD" "$GN")" in
      'deny config') deny "gh's own configuration (.config/gh, GH_CONFIG_DIR) is off-limits for farm agents — it can alias or repoint gh. Escalate (move the task to 'escalated')." ;;
      'deny eval') deny "eval together with gh is forbidden — the guard cannot read what gh would run." ;;
      'deny ansi') deny "\$'…' or \$\"…\" strings together with gh are forbidden — the guard cannot read them." ;;
      'deny admin') deny "gh alias, gh extension and gh config set are off-limits for farm agents. Escalate (move the task to 'escalated')." ;;
      'deny literal') deny "gh subcommand must be literal — no \$, backtick, quote or backslash in gh's command words (gh pr <verb>, gh api <endpoint>)." ;;
      'deny unknown') deny "gh's command word must be one of gh's built-in commands (pr, api, issue, run, repo, …) — gh aliases and extensions are off-limits for farm agents. Escalate (move the task to 'escalated')." ;;
      'deny glob') deny "gh api endpoint has glob or brace characters or a % (only {owner}, {repo}, {branch} and a ?name=value query are allowed) — write the endpoint literally." ;;
      'deny graphql') deny "gh api graphql together with \$, a backtick or < is forbidden — the guard cannot read a query built by an expansion or read from a file. Write the query literally." ;;
      'deny apiwrite') deny "gh api writes to git refs, contents, merges or branches are off-limits for farm agents — change the repository through a pull request. Escalate (move the task to 'escalated')." ;;
      'deny apiadmin') deny "gh api writes to repository administration (rulesets, protection, statuses, check runs, collaborators, actions permissions, repository settings) are off-limits for farm agents. Escalate (move the task to 'escalated')." ;;
      ok) ;;
      *) deny "gh tripwire: no readable verdict — blocked (fail-closed)." ;;
    esac

    # --- merge gate: auto-merge is OFF for protected surfaces ---------------
    # Deterministic enforcement of the Two-Actor backstop: a PR touching any
    # protected path cannot be merged by an agent, green CI or not. Fails
    # CLOSED: if the changed-file list cannot be determined, the merge is
    # blocked too.
    # Both merge routes must go through the changed-files check: the porcelain
    # `gh pr merge N` AND the REST route `gh api .../pulls/N/merge` (verified
    # bypass — `-X PUT`/`--method PUT`/field-implied PUT all reach the same
    # endpoint). Chasing every Bash form is unwinnable; so a merge is allowlisted
    # (fix round 1 ruling): text that looks like one — a `gh` word followed by
    # `merge`, or `pulls/…merge`, read with backslash-newline joined and
    # backslashes and quotes removed — passes only as one plain command
    # (_merge_plain). Specific denials first, each with its own reason.
    if _merge_candidate "$CMD" "$GN"; then
      MT="$GN"
      MT_RE='(^|[[:space:]])(--repo|--hostname)([[:space:]=]|$)|(^|[[:space:]])-[[:alpha:]]*R'   # -R, glued or in a short-flag cluster
      [[ "$MT" =~ $MT_RE ]] \
        && deny "merge gate: the merge names a repository (-R/--repo/--hostname) — the guard cannot tell whether it is the same one. Merge from the session's repository without it."
      [[ "$MT" == *GH_REPO=* || "$MT" == *GH_HOST=* || -n "${GH_REPO:-}${GH_HOST:-}" ]] \
        && deny "merge gate: the command or the environment sets GH_REPO or GH_HOST — gh would take the repository from it, which the guard cannot check. Merge without it."
      MT_RE='(^|[^[:alnum:]_.-])(cd|pushd|popd)([^[:alnum:]_.-]|$)|(^|[[:space:]])(-C|--chdir)|GIT_DIR=|GIT_WORK_TREE='
      [[ "$MT" =~ $MT_RE ]] \
        && deny "merge gate: the command changes directory (cd/pushd/popd/-C/GIT_DIR) — gh would resolve the repository from a directory the guard did not check. Run the merge alone, from the session's repository."
      MT_RE='(^|[[:space:]])--admin([[:space:]=]|$)'
      [[ "$MT" =~ $MT_RE ]] \
        && deny "merge gate: --admin bypasses branch protection — forbidden for farm agents. Escalate (move the task to 'escalated')."
      MERGE="$(_merge_plain "$CMD")" && PR_NUM="${MERGE##* }" \
        || deny "merge gate: name the pull request by number — a merge must be one plain command: gh pr merge <number> [--squash|--merge|--rebase] [--auto] [--delete-branch], or gh api repos/<owner>/<repo>/pulls/<number>/merge -X PUT; no quotes, variables, redirections, line continuations or other commands. Blocked."
      # Fix A: the policy comes from the default branch as fetched from origin,
      # never from the work tree an agent can edit, plus a mandatory list no
      # project file can remove. What this is NOT: a trusted source.
      # refs/remotes/origin/* (origin/HEAD included) is local state a session can
      # move with one git command (update-ref, symbolic-ref). The fetch narrows
      # that: it overwrites origin/main and origin/master, but never moves
      # origin/HEAD or removes extra refs. The mandatory list does not depend on
      # any ref. The guard is a tripwire (spec 2.4); branch protection is the boundary.
      GDIR="$(_guard_repo_dir)" \
        || deny "merge gate: no git work tree (FARM_WORKTREE, CLAUDE_PROJECT_DIR, cwd) — cannot read the merge policy; blocked (fail-closed). Escalate (move the task to 'escalated')."
      # gh resolves the pull request from the Bash tool's cwd, not from GDIR:
      # when the hook names a cwd, its work tree must be GDIR; any failure denies.
      if [[ -n "$HOOK_CWD" ]]; then
        MT_TOP="$(git -C "$HOOK_CWD" rev-parse --show-toplevel 2>/dev/null)" || MT_TOP=""
        [[ -n "$MT_TOP" && "$MT_TOP" == "$GDIR" ]] \
          || deny "merge gate: the current directory ($HOOK_CWD) is not the session's work tree ($GDIR) — gh would resolve the pull request there. Blocked."
      fi
      ORIGIN_SLUG="$(_guard_origin_slug "$GDIR")" || ORIGIN_SLUG=""
      # remote.origin.url with more than one value: git and gh use the first,
      # `git config --get` (the slug above) the last — two repositories.
      MT_RAW="$(git -C "$GDIR" config --get-all remote.origin.url 2>/dev/null)" || MT_RAW=""
      [[ -n "$MT_RAW" && "$MT_RAW" != *$'\n'* ]] \
        || deny "merge gate: origin must have exactly one URL (remote.origin.url) — git and gh would read different repositories. Blocked."
      MT_HOST="$(_guard_url_host "$MT_RAW")" || MT_HOST=""
      # url.*.insteadOf / pushInsteadOf rewrite origin for git and gh alike
      # (each applies the rules itself, so every rule that matches counts): a
      # rewrite to a network URL of another owner/repo repoints the merge. A
      # local path or file:// (the test fixtures) is no other GitHub repository.
      while read -r MT_K MT_V; do
        [[ -n "$MT_V" && "$MT_RAW" == "$MT_V"* ]] || continue
        MT_U="${MT_K#url.}"; MT_U="${MT_U%.*}${MT_RAW#"$MT_V"}"
        case "$MT_U" in /*|./*|../*|'~'*|file://*) continue ;; esac
        [[ -n "$ORIGIN_SLUG" && "$(_guard_url_slug "$MT_U")" == "$ORIGIN_SLUG" \
           && "$(_guard_url_host "$MT_U")" == "$MT_HOST" ]] \
          || deny "merge gate: origin is rewritten ($MT_K, insteadOf) to $MT_U, not origin's host and owner/repo — gh would resolve another repository. Blocked."
      done < <(git -C "$GDIR" config --get-regexp '^url\..*\.(insteadof|pushinsteadof)$' 2>/dev/null)
      # git's own answer (first value, insteadOf applied) must name the same
      # repository: unchanged, a local rewrite (checked above), or origin's
      # host and owner/repo.
      MT_GU="$(git -C "$GDIR" remote get-url origin 2>/dev/null)" || MT_GU=""
      case "$MT_GU" in
        "$MT_RAW"|/*|./*|../*|'~'*|file://*) ;;
        *) [[ -n "$ORIGIN_SLUG" && "$(_guard_url_slug "$MT_GU")" == "$ORIGIN_SLUG" \
              && "$(_guard_url_host "$MT_GU")" == "$MT_HOST" ]] \
             || deny "merge gate: git remote get-url origin (${MT_GU:-unreadable}) is not origin's configured repository — gh would resolve another repository. Blocked." ;;
      esac
      # `gh repo set-default` writes remote.<name>.gh-resolved; it repoints a bare `gh pr merge`.
      while read -r MT_K MT_V; do
        [[ "$MT_K" == remote.origin.gh-resolved && "$MT_V" == base ]] && continue
        [[ -n "$ORIGIN_SLUG" && "$MT_V" == "$ORIGIN_SLUG" ]] && continue
        deny "merge gate: gh's default repository ($MT_K $MT_V, from gh repo set-default) is not origin — the merge would land elsewhere. Blocked."
      done < <(git -C "$GDIR" config --get-regexp '^remote\..*\.gh-resolved$' 2>/dev/null)
      # gh prefers an upstream/github remote over origin: a porcelain merge needs
      # origin as the only remote, or origin pinned as gh's base.
      if [[ "$MERGE" == pr\ * && "$(git -C "$GDIR" remote 2>/dev/null)" != origin \
            && "$(git -C "$GDIR" config --get remote.origin.gh-resolved 2>/dev/null)" != base ]]; then
        deny "merge gate: origin is not the only remote and not gh's base (gh repo set-default) — gh may pick another remote. Use the REST form with origin's owner/repo, or escalate."
      fi
      if [[ "$MERGE" == rest\ * ]]; then
        MERGE_SLUG="${MERGE#rest }"; MERGE_SLUG="${MERGE_SLUG% *}"
        [[ -n "$ORIGIN_SLUG" && "$MERGE_SLUG" == "$ORIGIN_SLUG" ]] \
          || deny "merge gate: the REST merge targets $MERGE_SLUG, another repository than origin (${ORIGIN_SLUG:-unparseable}) — blocked."
      fi
      # Every lookup below names origin's repository, host included (gh's
      # default host is github.com; origin may be on another). Without a
      # parseable origin only the file list is read (gh resolves {owner}/{repo}
      # itself), so a protected file keeps its own reason; the merge is denied
      # after that check.
      MT_REPO="$MT_HOST/$ORIGIN_SLUG"; MT_FA=(--paginate "repos/{owner}/{repo}/pulls/$PR_NUM/files")
      [[ -n "$ORIGIN_SLUG" && -n "$MT_HOST" ]] && MT_FA=(--hostname "$MT_HOST" --paginate "repos/$ORIGIN_SLUG/pulls/$PR_NUM/files")
      # Cumulative deadline: the bounded calls below share 90 s from the start
      # of this hook, so the guard answers before the hook's 120 s timeout
      # (which fails open). mt_time <bound> sets MT_B or denies.
      mt_time() {
        MT_B="$(_guard_budget "$1" "$((SECONDS - GUARD_T0))")" \
          || deny "merge gate ran out of time (90 s for the fetch and gh lookups) — blocked (fail-closed). Retry, or escalate (move the task to 'escalated')."
      }
      mt_time 15
      GIT_TERMINAL_PROMPT=0 _guard_bounded "$MT_B" git -C "$GDIR" fetch --quiet origin >/dev/null 2>&1 || true
      mt_time 1
      MAIN_REF="$(_guard_main_ref "$GDIR")" \
        || deny "merge gate: cannot resolve the default branch (origin/HEAD, origin/main, origin/master) — cannot read the merge policy; blocked (fail-closed). Escalate (move the task to 'escalated')."
      GLOBS="$(_guard_policy_globs "$GDIR" "refs/remotes/$MAIN_REF")"; GLOBS_RC=$?
      [[ "$GLOBS_RC" == 4 ]] \
        && deny "merge gate: cannot locate protected-paths.txt — cannot verify the PR is safe to merge; blocked (fail-closed). Escalate (move the task to 'escalated')."
      [[ "$GLOBS_RC" == 5 ]] \
        && deny "merge gate: protected-paths.txt on $MAIN_REF is too large (over 65536 bytes or 2000 lines) — blocked (fail-closed). Escalate (move the task to 'escalated')."
      [[ "$GLOBS_RC" == 0 ]] \
        || deny "merge gate: cannot read protected-paths.txt from $MAIN_REF — blocked (fail-closed). Escalate (move the task to 'escalated')."
      # --auto merges later, whatever the head is then: it must be pinned to the
      # head whose files are checked here (the file list cannot be pinned, so the
      # head is read before and after it and must not move).
      MT_AUTO=0; MT_PIN=""; read -r -a MT_W <<<"$CMD"
      for ((MT_I=0; MT_I<${#MT_W[@]}; MT_I++)); do
        case "${MT_W[$MT_I]}" in
          --auto) MT_AUTO=1 ;;
          --match-head-commit) MT_PIN="${MT_W[$((MT_I+1))]:-}" ;;
        esac
      done
      [[ "$MT_AUTO" == 1 && -z "$MT_PIN" ]] \
        && deny "merge gate: --auto needs --match-head-commit <the PR's head sha> — otherwise a later push lands unchecked files. Blocked."
      mt_head() { _guard_bounded "$MT_B" gh pr view "$PR_NUM" --repo "$MT_REPO" --json headRefOid -q .headRefOid 2>/dev/null; }
      if [[ -n "$MT_PIN" ]]; then
        [[ -n "$ORIGIN_SLUG" && -n "$MT_HOST" ]] \
          || deny "merge gate: cannot read owner/repo from origin's URL — the guard cannot tell which repository gh merges in. Blocked."
        mt_time 20
        MT_H1="$(cd "$GDIR" && mt_head)" || MT_H1=""
        mt_time 1
        [[ -n "$MT_H1" && "$MT_H1" == "$MT_PIN" ]] \
          || deny "merge gate: --match-head-commit $MT_PIN is not the PR's current head (${MT_H1:-unreadable}) — blocked."
      fi
      # The PR's files from the REST list, a renamed file under its old name too
      # (gh pr diff --name-only lists only the new one). A gh that timed out or
      # failed may have printed a partial list: discard it. No fallback to a
      # local diff: the work tree is no gate input (fail closed).
      mt_time 20
      FILES="$(cd "$GDIR" && _guard_bounded "$MT_B" gh api "${MT_FA[@]}" \
               --jq '.[] | .filename, (.previous_filename // empty)' 2>/dev/null)" || FILES=""
      mt_time 1
      if [[ -n "$MT_PIN" ]]; then
        mt_time 20
        MT_H2="$(cd "$GDIR" && mt_head)" || MT_H2=""
        mt_time 1
        [[ "$MT_H2" == "$MT_PIN" ]] \
          || deny "merge gate: the PR's head moved while its files were read (${MT_H2:-unreadable}) — blocked; retry with the new head."
      fi
      MT_F=(); while IFS= read -r f; do [[ -n "$f" ]] && MT_F+=("$f"); done <<<"$FILES"
      [[ "${#MT_F[@]}" -gt 0 ]] \
        || deny "merge gate: cannot determine the PR's changed files — merging blind is forbidden. Verify the PR number and retry, or escalate (move the task to 'escalated')."
      while IFS= read -r glob; do
        glob="${glob%$'\r'}"   # a CRLF list keeps its globs
        [[ -z "$glob" || "$glob" == \#* ]] && continue
        for f in "${MT_F[@]}"; do
          # shellcheck disable=SC2053
          [[ "$f" == $glob ]] \
            && deny "merge gate: PR touches protected path '$f' (rule: $glob). Auto-merge is OFF for safety-critical surfaces — move the task to escalated with your full QA verdict; a human merges."
        done
      done <<<"$GLOBS"
      # After the protected-path check, so a protected file keeps its own reason.
      [[ -n "$ORIGIN_SLUG" && -n "$MT_HOST" ]] \
        || deny "merge gate: cannot read owner/repo from origin's URL — the guard cannot tell which repository gh merges in. Blocked."
      # Fix B: the required checks, decided on their JSON buckets, never gh's exit
      # code; a failed, empty or timed-out answer is undetermined. The REST route
      # never counts as --auto (PD7): an administrator's token merges at once.
      MT_CA=0; [[ "$MERGE" == pr\ * ]] && MT_CA="$MT_AUTO"
      mt_time 20
      CHECKS="$(cd "$GDIR" && _guard_bounded "$MT_B" gh pr checks "$PR_NUM" --repo "$MT_REPO" --required --json name,bucket 2>/dev/null)" || CHECKS=""
      mt_time 1
      case "$(_merge_checks_decide "$CHECKS" "$MT_CA")" in
        allow) ;;
        deny-none) deny "merge gate: the PR has no required status check — nothing proves it green, so it waits for a human. Escalate (move the task to 'escalated')." ;;
        deny-failing) deny "merge gate: a required check failed or was cancelled — blocked. Fix the PR, or escalate." ;;
        deny-pending) deny "merge gate: a required check is still pending — wait for it, or merge with --auto --match-head-commit <head sha>." ;;
        deny-skipped) deny "merge gate: a required check was skipped — a skipped check does not count as passed. Blocked; escalate (move the task to 'escalated')." ;;
        *) deny "merge gate: cannot determine the PR's required checks (gh pr checks --required failed, timed out or gave no readable answer; a repository with no required check answers so) — blocked (fail-closed). Escalate (move the task to 'escalated')." ;;
      esac
    fi

    # --- destructive git / github ------------------------------------------
    # On the guard's reading (GN), so quotes or backslashes do not hide them.
    grep -qE 'git[[:space:]]+push[^|;&]*(--force|-f([[:space:]]|$)|--force-with-lease)' <<<"$GN" \
      && deny "force-push is forbidden (CLAUDE.md shipping rules)."
    grep -qE 'git[[:space:]]+push[^|;&]*[[:space:]](--delete|:)[[:space:]]*(origin/)?(main|master)' <<<"$GN" \
      && deny "deleting main is forbidden."
    # After the two rules above, so a force push and a deletion keep their own reason.
    if [[ "$GN" == *push* || "$GN" == *send-pack* || "$GN" == *receive-pack* ]]; then
      # The current branch: of the Bash tool's cwd when that is a work tree, else of the session's.
      d=""; [[ -n "$HOOK_CWD" ]] && d="$(git -C "$HOOK_CWD" rev-parse --show-toplevel 2>/dev/null || true)"
      [[ -n "$d" ]] || d="$(_guard_repo_dir || true)"
      PUSH_BRANCH="$([[ -n "$d" ]] && git -C "$d" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
      PUSH_VERDICT="$(_push_target_scan "$GN" "$PUSH_BRANCH")"; PUSH_DIRS=(); PUSH_ROUNDS=0
      # `need <dir>`: a bare/HEAD push under `git -C <dir>`; read <dir>'s branch
      # (relative to the Bash tool's cwd, as git does) and ask again. Bounded; an
      # unresolved answer denies (fail closed).
      while [[ "$PUSH_VERDICT" == "need "* && "$PUSH_ROUNDS" -lt 8 ]]; do
        d="${PUSH_VERDICT#need }"
        # `?` = no work tree at <dir> (denies); empty = a detached HEAD there (allows)
        if [[ -n "$d" && "$(git -C "${HOOK_CWD:-.}" -C "$d" rev-parse --is-inside-work-tree 2>/dev/null)" == true ]]; then
          PUSH_DIRS+=("$d=$(git -C "${HOOK_CWD:-.}" -C "$d" symbolic-ref --quiet --short HEAD 2>/dev/null || true)")
        else
          PUSH_DIRS+=("$d=?")
        fi
        PUSH_VERDICT="$(_push_target_scan "$GN" "$PUSH_BRANCH" "${PUSH_DIRS[@]}")"
        PUSH_ROUNDS=$((PUSH_ROUNDS+1))
      done
      [[ "$PUSH_VERDICT" == allow ]] \
        || deny "direct push to the default branch is forbidden — open a pull request (a push to main/master, HEAD or @ on it, --all/--mirror, a matching ':' or glob/brace refspec, and git send-pack/receive-pack all count)"
    fi
    grep -qE 'gh[[:space:]]+(repo[[:space:]]+(delete|archive|edit)|secret[[:space:]]|variable[[:space:]]+set|workflow[[:space:]]+(disable|enable)|release[[:space:]]+delete|ruleset|api[^|;&]*-X[[:space:]]*(DELETE|PATCH)[^|;&]*(branch.protection|rulesets))' <<<"$GN" \
      && deny "repo administration via gh is off-limits (secrets, workflows, protection, deletion). Escalate (move the task to 'escalated')."

    # --- self-tampering: the farm must not weaken its own rails ------------
    grep -qE '(^|[;&|[:space:]])(rm|mv|cp|sed|tee|truncate)[^|;&]*((\.claude/settings)|((agent-farm|software-factory)/(hooks|bin|systemd|launchd))|(/hooks/guard-bash\.sh)|(\.agent-farm/(protected-paths|farm\.env))|(\.github/workflows)|CODEOWNERS)' <<<"$CMD" \
      && deny "guard/CI/farm configuration is read-only for agents. If a task genuinely requires changing it, escalate (move the task to 'escalated')."
    # The verb-anchored rule above only catches commands that START with rm|mv|
    # cp|sed|tee|truncate — a shell redirection (`echo x > protected-paths.txt`)
    # or ANY interpreter one-liner (`python3 -c "open(...,'w')"`, `node -e
    # writeFileSync`, `ruby -e File.write`, `perl -e`) slips past it. Enumerating
    # write MECHANISMS is a losing whack-a-mole, so INVERT it for the guard's own
    # config + CI rails: if a Bash command NAMES one of these protected paths,
    # DENY it unless the WHOLE command is a pure read. "Pure read" = it uses none
    # of {output redirection, tee/dd, an in-place editor, a general-purpose
    # interpreter, or a copy/move/remove/truncate/install verb}. Every write
    # path — known or not — is denied by default; only cat/grep/less/head/tail/
    # diff/… style reads pass. False positives only escalate — the safe direction.
    #
    # Coverage (exact — do not overclaim): redirection `>`/`>>`; `tee`/`dd`;
    # `sed -i`/`-i inplace`/`--in-place`/`ex`/`ed`/`patch`; the interpreters
    # python|python3|node|deno|bun|ruby|perl|php|lua|tclsh|Rscript|osascript|
    # pwsh|powershell; `git checkout --`; `rm`/`mv`/`cp`/`install`/`truncate`.
    # A pure `cat`/`grep`/`less` of the file is allowed (agents must read these).
    if grep -qE '(protected-paths\.txt|farm\.env|guard-bash\.sh|hooks\.json|CODEOWNERS|\.github/workflows|\.claude/settings|Library/LaunchAgents/com\.agent-farm|com\.agent-farm\.[a-z.-]*\.plist|engine/launchd/)' <<<"$CMD" \
       && grep -qE '(>>?)|((^|[[:space:]])(tee|dd|truncate|install|rm|mv|cp)([[:space:]]|$))|(-i([[:space:]]|=)*inplace)|(--in-place)|((^|[[:space:]])sed[[:space:]]+[^|;&]*-i)|((^|[[:space:]])(ex|ed|patch|python|python3|node|deno|bun|ruby|perl|php|lua|tclsh|Rscript|osascript|pwsh|powershell)([[:space:]]|$))|(checkout[[:space:]]+--)' <<<"$CMD"; then
      deny "guard/CI/farm configuration is read-only for agents. A command NAMING a protected config file (protected-paths.txt / farm.env / guard-bash.sh / hooks.json / CODEOWNERS / .github/workflows / .claude/settings) is allowed only as a pure read (cat/grep/less); any write mechanism — redirection, tee/dd, in-place editor, or an interpreter one-liner — is blocked. Escalate (move the task to 'escalated') if a change is genuinely required."
    fi
    grep -qE '(^|[;&|[:space:]])systemctl[[:space:]]+(--user[[:space:]]+)?(stop|disable|mask|kill)' <<<"$CMD" \
      && deny "agents do not manage services."
    # macOS equivalent of the systemctl rule above. NOTE: `kickstart` alone (no
    # `-k`) is sup_scout_now's legitimate way to nudge a launchd job — only
    # `kickstart -k` (which kills the running instance first) is denied.
    grep -qE '(^|[;&|[:space:]])launchctl[[:space:]]+(bootout|boot-out|unload|remove|stop|kill|disable|(kickstart[[:space:]]+-k))' <<<"$CMD" \
      && deny "agents do not manage services."

    # --- system-destructive -------------------------------------------------
    grep -qE '(^|[;&|[:space:]])rm[[:space:]]+(-[a-zA-Z]*r[a-zA-Z]*f|-[a-zA-Z]*f[a-zA-Z]*r)[[:space:]]+(/([[:space:]]|$)|/(home|etc|usr|var|root|opt)([/[:space:]]|$)|"?\$HOME"?([/[:space:]]|$))' <<<"$CMD" \
      && deny "recursive force-delete of system/home paths."
    grep -qE '(^|[;&|[:space:]])(mkfs|shutdown|reboot|halt)([[:space:]]|$)|dd[[:space:]][^|;&]*of=/dev/' <<<"$CMD" \
      && deny "system-destructive command."
    grep -qE '(curl|wget)[^|;&]*\|[[:space:]]*(sudo[[:space:]]+)?(ba|z|da)?sh' <<<"$CMD" \
      && deny "piping downloads into a shell is forbidden. Download, inspect, then run."

    # --- publishing ----------------------------------------------------------
    grep -qE '(^|[;&|[:space:]])(npm|pnpm|yarn)[[:space:]]+publish' <<<"$CMD" \
      && deny "publishing packages is a human decision."
    ;;

  Write|Edit|MultiEdit|NotebookEdit)
    FP="$(jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' <<<"$INPUT")"
    # Anchor protected segments to a path boundary (^ or /) rather than a literal
    # leading slash, so a RELATIVE file_path (e.g. `.agent-farm/protected-paths.txt`)
    # is caught too — "fails closed", not "fails closed only for absolute paths".
    grep -qE '(\.claude/settings(\.local)?\.json$)|((^|/)(agent-farm|software-factory)/(hooks|bin|systemd|launchd)/)|((^|/)hooks/guard-bash\.sh$)|((^|/)\.agent-farm/(protected-paths\.txt|farm\.env|prompts)/?)|(\.github/workflows/)|(CODEOWNERS$)' <<<"$FP" \
      && deny "protected path ($FP): guard, farm internals/config, CI workflows and CODEOWNERS are not editable by agents. Escalate (move the task to 'escalated') if the task requires it."

    # --- worktree confinement ----------------------------------------------
    # The observed live-eval failure: a session wrote OUTSIDE its worktree,
    # into the shared REPO_DIR checkout — the work never lands in the PR
    # (silent loss) and pollutes state no PR explains. When the runner/scout
    # exports FARM_WORKTREE, deny any tool write that resolves outside it.
    # Allowed: the worktree itself, the farm's state dir (scout REPORT etc.,
    # which lives under .agent-farm/state, NOT the worktree), and /tmp scratch.
    # This is a LAYER on the tool write-path — bash redirections stay uncovered
    # (documented stance); it is NOT a shell/AST parser. A relative file_path
    # resolves against the session's CWD (the worktree, via `cd "$WT"`) → allowed.
    if [[ -n "${FARM_WORKTREE:-}" && -n "$FP" ]]; then
      WT_CANON="$(_canon_path "$FARM_WORKTREE")"
      ST_CANON="$(_canon_path "${FARM_STATE_DIR:-/nonexistent-state}")"
      FP_CANON="$(_canon_path "$FP")"
      # _canon_path returns EMPTY on a symlink-cycle cap (fail-closed by design).
      # An empty WT_CANON/ST_CANON would make the allow-pattern "$WT_CANON"/*
      # collapse to a bare "/*", which matches EVERY absolute path -> confinement
      # defeated (fail-OPEN). Deny outright if either anchor failed to canonicalize.
      [[ -z "$WT_CANON" || -z "$ST_CANON" ]] \
        && deny "worktree confinement: could not canonicalize the worktree/state path (possible symlink cycle) — write blocked (fail-closed). Escalate (move the task to 'escalated')."
      case "$FP_CANON" in
        "$WT_CANON"|"$WT_CANON"/*) : ;;
        "$ST_CANON"|"$ST_CANON"/*) : ;;
        # macOS canonicalizes /tmp -> /private/tmp and /var/tmp -> /private/var/tmp
        # (both are symlinks to /private/... there); _canon_path resolves them, so
        # a write under /tmp/... arrives here already in its /private/tmp/... form.
        # Additive only — the Linux (unresolved) forms above still match too.
        /tmp|/tmp/*|/var/tmp|/var/tmp/*|/private/tmp|/private/tmp/*|/private/var/tmp|/private/var/tmp/*) : ;;
        *) deny "write outside the session worktree ($FP → $FP_CANON): sessions may write ONLY inside $WT_CANON (or /tmp). Work written elsewhere never lands in the PR and pollutes the shared checkout. If the task genuinely needs an out-of-worktree write, escalate (move the task to 'escalated')." ;;
      esac
    fi
    ;;
  mcp__*)
    deny "MCP tools are off-limits for farm agents — connector tools reach systems the farm has no mandate over. Use the repo, gh and the board; escalate (move the task to 'escalated') if the task needs a connector."
    ;;
esac

exit 0
