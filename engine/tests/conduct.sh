#!/usr/bin/env bash
# agent-farm/tests/conduct.sh — tests for the Plan Conductor (bin/farm-conduct-lib.sh).
# No framework; exits non-zero on any failure. CI: conduct-linux (full tier) on every
# event, conduct-macos (CONDUCT_TEST_TIER=smoke, stock bash 3.2/BSD) nightly/on dispatch.
# PD9: decider assertions always run; a scenario runs in the smoke tier only when its
# line is marked [smoke], every other scenario sits inside `if is_full`.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # engine/tests
FARM="$(cd "$HERE/../.." && pwd)"                       # plugin root
LIB="$FARM/bin/farm-conduct-lib.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
nope() { FAIL=$((FAIL+1)); echo "FAIL [$1]"; }
expect_eq() { # got, want, description
  if [[ "$1" == "$2" ]]; then ok; else nope "$3: got=[$1] want=[$2]"; fi
}
is_full() { [[ "${CONDUCT_TEST_TIER:-full}" != smoke ]]; }
TAB="$(printf '\t')"

# ---- the unit heading pattern ----
# shellcheck source=../../bin/farm-conduct-lib.sh
got="$(source "$LIB" && printf '%s' "${CONDUCT_UNIT_RE:-}")"
expect_eq "$got" '^## (M[0-9]+[a-z]?|PR [0-9]+|Iteration [0-9]+)([^A-Za-z0-9]|$)' "CONDUCT_UNIT_RE text"
for h in '## M1' '## M1: x' '## M10 — y' '## PR 3 (z)'; do
  # shellcheck source=../../bin/farm-conduct-lib.sh
  if (source "$LIB" && [[ "$h" =~ $CONDUCT_UNIT_RE ]]); then ok; else nope "unit RE matches '$h'"; fi
done
for h in '## M1x2' '## PR 3a'; do
  # shellcheck source=../../bin/farm-conduct-lib.sh
  if (source "$LIB" && [[ -n "${CONDUCT_UNIT_RE:-}" ]] && ! [[ "$h" =~ $CONDUCT_UNIT_RE ]]); then ok; else nope "unit RE rejects '$h'"; fi
done

# ---- conduct_plan_units on an inline plan ----
PLAN="$(cat <<'EOF'
# Test plan

## M1 — Rails

Depends-on: none

### Task M1.1: a

```text
## M9 — fake
### Task M9.1: fake
```

````markdown
```bash
## M8 — fake
```
````

## M2a — Contract

### M2a-T1: x

### M2a-T2: y

### M2a exit checklist

## PR 3: Loop

Depends-on: M1, M2a

### Task 1: z

## Iteration 2 — folded into the next

## M2ab — no

## Mx

## PR 3a

## Iteration 2b

## 0. How to run
EOF
)"
lno() { printf '%s\n' "$PLAN" | grep -n -x -- "$1" | cut -d: -f1; }
want="M1${TAB}Rails${TAB}${TAB}1${TAB}$(lno '## M1 — Rails')
M2a${TAB}Contract${TAB}M1${TAB}2${TAB}$(lno '## M2a — Contract')
PR 3${TAB}Loop${TAB}M1,M2a${TAB}1${TAB}$(lno '## PR 3: Loop')
Iteration 2${TAB}folded into the next${TAB}PR 3${TAB}0${TAB}$(lno '## Iteration 2 — folded into the next')"
# shellcheck source=../../bin/farm-conduct-lib.sh
got="$(source "$LIB" && printf '%s\n' "$PLAN" | conduct_plan_units)"
expect_eq "$got" "$want" "conduct_plan_units inline plan"
UNITS4="$want"   # the four units of M2.1, independent of the library (reused by "lint:")

# ---- slug, plan key, handoff path, branch prefix ----
for pair in 'M2a=m2a' 'PR 3=pr-3' 'Iteration 2=iteration-2'; do
  # shellcheck source=../../bin/farm-conduct-lib.sh
  got="$(source "$LIB" && conduct_unit_slug "${pair%%=*}")"
  expect_eq "$got" "${pair#*=}" "conduct_unit_slug ${pair%%=*}"
done
P=docs/superpowers/plans/2026-11-12-x.md
# shellcheck source=../../bin/farm-conduct-lib.sh
got="$(source "$LIB" && conduct_plan_key "$P")"
expect_eq "$got" 2026-11-12-x "conduct_plan_key"
for bad in '../x.md' '/abs/x.md' 'docs/a b.md' 'docs/x.txt' 'docs/../x.md' 'docs/./x.md' './x.md' 'docs//x.md'; do
  # shellcheck source=../../bin/farm-conduct-lib.sh
  (source "$LIB"; declare -F conduct_plan_key >/dev/null || exit 9; conduct_plan_key "$bad" >/dev/null 2>&1); rc=$?
  expect_eq "$rc" 1 "conduct_plan_key rejects '$bad'"
done
# shellcheck source=../../bin/farm-conduct-lib.sh
got="$(source "$LIB" && conduct_handoff_path "$P" "PR 3")"
expect_eq "$got" docs/superpowers/handoffs/2026-11-12-x-pr-3-handoff.md "conduct_handoff_path"
# shellcheck source=../../bin/farm-conduct-lib.sh
got="$(source "$LIB" && conduct_branch_prefix "$P" "PR 3")"
expect_eq "$got" conduct/2026-11-12-x/pr-3/ "conduct_branch_prefix"

# ---- the synthetic fixture and the real plan ----
# shellcheck source=../../bin/farm-conduct-lib.sh
got="$(source "$LIB" && conduct_plan_units < "$FARM/contract/fixtures/plan.md" | cut -f1,3,4 | tr '\t\n' ':;')"
expect_eq "$got" "M1::1;M2:M1:1;" "fixture plan: M1 and M2, one task each"

# ---- CRLF input: fences still close, deps and titles carry no \r ----
CR=$'\r'
# shellcheck source=../../bin/farm-conduct-lib.sh
got="$(source "$LIB" && printf '## M1 — A\r\nDepends-on: none\r\n\r\n### Task M1.1: a\r\n```\r\n## M9 — fake\r\n```\r\n\r\n## M2 — B\r\n\r\n### Task M2.1: b\r\n' | conduct_plan_units)"
expect_eq "$got" "M1${TAB}A${TAB}${TAB}1${TAB}1
M2${TAB}B${TAB}M1${TAB}1${TAB}9" "conduct_plan_units on a CRLF plan"
case "$got" in *"$CR"*) nope "CRLF plan output contains \\r" ;; *) [[ -n "$got" ]] && ok || nope "CRLF plan output empty" ;; esac

# ---- Depends-on counts only as the first non-blank line under the unit heading ----
# shellcheck source=../../bin/farm-conduct-lib.sh
got="$(source "$LIB" && printf '## M1 — A\n\n### Task M1.1: a\n\n## M2 — B\n\n### Task M2.1: b\n\nDepends-on: none\n' | conduct_plan_units | cut -f1,3 | tr '\t\n' ':;')"
expect_eq "$got" "M1:;M2:M1;" "Depends-on after a task heading is ignored"

# ---- lint: conduct_lint, conduct_topo_order, conduct_dependents ----
# run_fn <function> <arg>; stdin unit lines -> stdout of the function, then "rc=N".
# rc=9 when the library or the function is missing, so no assertion passes without it.
run_fn() {
  # shellcheck source=../../bin/farm-conduct-lib.sh
  (source "$LIB" || exit 9; declare -F "$1" >/dev/null || exit 9; "$@"); echo "rc=$?"
}
got="$(printf '%s\n' "$UNITS4" | run_fn conduct_lint '')"
case "$got" in
  "LINT: no-tasks: Iteration 2"*"delete the heading, or give the next unit an explicit Depends-on:"$'\n'"rc=1") ok ;;
  *) nope "lint: four units of M2.1 -> one no-tasks line: got=[$got]" ;;
esac
expect_eq "$(printf '%s\n' "$got" | grep -c '^LINT:')" 1 "lint: four units of M2.1 -> exactly one LINT line"
got="$(run_fn conduct_lint '' </dev/null)"
expect_eq "$got" "LINT: no-units
rc=1" "lint: empty input"
got="$(printf 'M1\ta\t\t1\t1\nM2\tb\tM9\t1\t3\n' | run_fn conduct_lint '')"
expect_eq "$got" "LINT: unknown-dep: M2: M9
rc=1" "lint: M2 depends on M9"
got="$(printf 'M1\ta\tM2\t1\t1\nM2\tb\tM1\t1\t3\n' | run_fn conduct_lint '')"
expect_eq "$got" "LINT: cycle: M1,M2
rc=1" "lint: M1 and M2 depend on each other"
got="$(printf 'M1\ta\t\t1\t1\nM1\tb\t\t1\t3\n' | run_fn conduct_lint '')"
expect_eq "$got" "LINT: duplicate: M1
rc=1" "lint: two units named M1"
VALID="$(printf '%s\n' "$UNITS4" | head -3)"   # M1, M2a, PR 3
got="$(printf '%s\n' "$VALID" | run_fn conduct_lint 'M0')"
expect_eq "$got" "LINT: renamed-shipped: M0
rc=1" "lint: valid plan, shipped M0"
got="$(printf '%s\n' "$VALID" | run_fn conduct_lint 'M1')"
expect_eq "$got" "rc=0" "lint: valid plan, shipped M1"
got="$(printf '%s\n' "$VALID" | run_fn conduct_lint 'M1, PR 3')"
expect_eq "$got" "rc=0" "lint: valid plan, shipped list with a spaced id"
got="$(printf 'A\ta\t\t1\t1\nC\tc\tB\t1\t2\nB\tb\tA\t1\t3\n' | run_fn conduct_topo_order)"
expect_eq "$got" "A
B
C
rc=0" "lint: conduct_topo_order A, C(dep B), B(dep A)"
got="$(printf 'A\ta\t\t1\t1\nB\tb\t\t1\t2\nC\tc\tA\t1\t3\n' | run_fn conduct_topo_order | tr '\n' ' ')"
expect_eq "$got" "A B C rc=0 " "lint: conduct_topo_order keeps document order among equals"
got="$(printf 'M1\ta\t\t1\t1\nM2a\tb\t M1 \t1\t2\nPR 3\tc\tM1, M2a\t1\t3\n' | run_fn conduct_lint '')"
expect_eq "$got" "rc=0" "lint: raw deps 'M1, M2a' with spaces lint clean"
got="$(printf '%s\n' "$UNITS4" | run_fn conduct_topo_order)"
expect_eq "$got" "M1
M2a
PR 3
Iteration 2
rc=0" "lint: conduct_topo_order on the M2.1 plan"
got="$(printf '%s\n' "$UNITS4" | run_fn conduct_dependents M1)"
expect_eq "$got" "M2a
PR 3
rc=0" "lint: conduct_dependents M1 on the M2.1 plan"
got="$(printf '%s\n' "$UNITS4" | run_fn conduct_dependents 'PR 3')"
expect_eq "$got" "Iteration 2
rc=0" "lint: conduct_dependents PR 3 on the M2.1 plan"

# ---- handoff: conduct_handoff_validate, conduct_entry_statuses, conduct_entry_decide ----
HO="$(cat "$FARM/contract/fixtures/handoff.md")"
drop() { # <heading line prefix>; stdin: handoff. Removes that section up to the next level-2 heading.
  awk -v h="$1" 'index($0, h) == 1 { skip = 1; next } /^## / { skip = 0 } !skip'
}
swap() { # <text> <old> <new> -> <text> with its first <old> replaced by <new>
  # Not "${t/old/new}": bash 3.2 (macOS) keeps the quotes of a quoted replacement as literal
  # text, and a backtick in the replacement is a parse error there.
  case "$1" in *"$2"*) printf '%s' "${1%%"$2"*}$3${1#*"$2"}" ;; *) printf '%s' "$1" ;; esac
}
hv() { # <text> <phase> <dependents> -> validator output, then "rc=N"
  printf '%s\n' "$1" | run_fn conduct_handoff_validate "$2" "$3"
}
decide_of() { # <unit>; stdin: handoff -> conduct_entry_statuses | conduct_entry_decide, then "rc=N"
  # shellcheck source=../../bin/farm-conduct-lib.sh
  (source "$LIB" || exit 9; declare -F conduct_entry_statuses >/dev/null || exit 9
   declare -F conduct_entry_decide >/dev/null || exit 9
   conduct_entry_statuses "$1" | conduct_entry_decide); echo "rc=$?"
}
expect_eq "$(hv "$HO" two M2)" "rc=0" "handoff: fixture, two, M2"
NOSEC="$(printf '%s\n' "$HO" | drop '## 5a. Security review')"
expect_eq "$(hv "$NOSEC" one M2)" "rc=0" "handoff: security review removed, one"
expect_eq "$(hv "$NOSEC" two M2)" "HANDOFF: missing-section: security-review
rc=1" "handoff: security review removed, two"
expect_eq "$(hv "$(printf '%s\n' "$HO" | drop '## 5b. Lessons learned')" two M2)" "HANDOFF: missing-section: lessons-learned
rc=1" "handoff: lessons removed, two (phase one still holds)"
expect_eq "$(hv "$(printf '%s\n' "$HO" | drop '## 3. Verification evidence')" one M2)" "HANDOFF: missing-section: verification-evidence
rc=1" "handoff: verification removed, one"
for ph in one two; do
  expect_eq "$(hv "$HO" "$ph" 'M2,M3')" "HANDOFF: missing-entry-criteria: M3
rc=1" "handoff: dependents M2,M3, $ph"
done
expect_eq "$(hv "$(printf '%s\n' "$HO" | grep -v '^| [0-9]')" one M2)" "HANDOFF: empty-entry-criteria: M2
rc=1" "handoff: table reduced to header and separator"
expect_eq "$(hv "$(printf '%s\n' "$HO" | sed 's/| met (#12 merged) |/| mostly met |/')" one M2)" "HANDOFF: bad-status: M2: 1
rc=1" "handoff: status 'mostly met'"
expect_eq "$(hv "$(printf '%s\n' "$HO" | sed 's/| met (#12 merged) |/| Met (#12 merged) |/')" one M2)" "HANDOFF: bad-status: M2: 1
rc=1" "handoff: status 'Met' (exact, lower case)"
LAST="$(printf '%s\n' "$HO" | sed -e 's/^| # | Criterion | Status | Evidence |$/| # | Criterion | Status |/' \
  -e 's/^|---|---|---|---|$/|---|---|---|/' -e 's/^\(| [0-9] | [^|]* | [^|]* |\) [^|]* |$/\1/')"
expect_eq "$(printf '%s\n' "$LAST" | grep -c '^| [0-9#] | [^|]* | [^|]* |$')" 3 "handoff: mutation drops the Evidence column"
expect_eq "$(hv "$LAST" two M2)" "rc=0" "handoff: Status column last, no Evidence"
STATE="$(printf '%s\n' "$HO" | sed 's/^| # | Criterion | Status | Evidence |$/| # | Criterion | State | Evidence |/')"
expect_eq "$(hv "$STATE" one M2)" "HANDOFF: bad-status: M2: 1
HANDOFF: bad-status: M2: 2
rc=1" "handoff: no Status header -> the last column (Evidence) is the status"
FENCED="$(printf '%s\n' "$NOSEC" '```text' '## 5a. Security review (plan §0.5)' '```')"
expect_eq "$(hv "$FENCED" two M2)" "HANDOFF: missing-section: security-review
rc=1" "handoff: security review heading only inside a fence, two"
for ph in final ''; do
  expect_eq "$(hv "$HO" "$ph" M2)" "HANDOFF: bad-phase
rc=1" "handoff: phase '$ph'"
done
NOENTRY="$(printf '%s\n' "$HO" | drop '## 6. M2 entry criteria')"
for ph in one two; do
  expect_eq "$(hv "$NOENTRY" "$ph" '')" "rc=0" "handoff: dependents '' without an entry-criteria section, $ph"
done
expect_eq "$(printf '%s\n' "$HO" | run_fn conduct_entry_statuses M2)" "met
accepted
rc=0" "handoff: conduct_entry_statuses M2 on the fixture"
expect_eq "$(printf '%s\n' "$HO" | decide_of M2)" "ok
rc=0" "handoff: fixture -> ok"
NOTMET="$(printf '%s\n' "$HO" | sed 's/| met (#12 merged) |/| not met (#12 open) |/')"
expect_eq "$(hv "$NOTMET" one M2)" "rc=0" "handoff: a 'not met' row validates"
expect_eq "$(printf '%s\n' "$NOTMET" | decide_of M2)" "blocked
rc=0" "handoff: a 'not met' row -> blocked"
expect_eq "$(printf 'met\naccepted\n' | run_fn conduct_entry_decide)" "ok
rc=0" "handoff: decide met,accepted"
expect_eq "$(printf 'met\ninvalid\n' | run_fn conduct_entry_decide)" "invalid
rc=0" "handoff: decide met,invalid"
expect_eq "$(printf 'not met\ninvalid\n' | run_fn conduct_entry_decide)" "invalid
rc=0" "handoff: decide not met,invalid"
expect_eq "$(run_fn conduct_entry_decide </dev/null)" "none
rc=0" "handoff: decide, no tokens"
# CRLF: the fixture's fence must still close, so the sections after it stay visible.
HOCR="$(printf '%s\n' "$HO" | awk '{ printf "%s\r\n", $0 }')"
expect_eq "$(hv "$HOCR" two M2)" "rc=0" "handoff: CRLF fixture, two, M2"
expect_eq "$(printf '%s\n' "$HOCR" | run_fn conduct_entry_statuses M2)" "met
accepted
rc=0" "handoff: CRLF fixture, conduct_entry_statuses M2"
# An escaped \| stays inside its cell (GFM), so the row keeps the header's cell count and
# the status cell is the rendered one.
ROW1='| 1 | M1 pull request merged | met (#12 merged) | PR #12 |'
ESC="$(swap "$HO" "$ROW1" '| 1 | x \| y | not met | e |')"
expect_eq "$(hv "$ESC" one M2)" "rc=0" "handoff: escaped \\| row keeps its cells"
expect_eq "$(printf '%s\n' "$ESC" | decide_of M2)" "blocked
rc=0" "handoff: escaped \\| row reads 'not met' -> blocked"
# \\| is ambiguous (escaped backslash then a separator, or not): such a row fails closed.
for r in '| 1 | a\\| not met | e |' '| 1 | a\\| x | met | e |'; do
  expect_eq "$(printf '%s\n' "$(swap "$HO" "$ROW1" "$r")" | decide_of M2)" "invalid
rc=0" "handoff: row with \\\\| -> invalid ($r)"
done
# Every table in the section counts, each with its own header and Status column.
NEXT='## 7. Prompt for the next session'
T2="$(swap "$HO" "$NEXT" $'| Criterion | Status |\n|---|---|\n| Second gate | not met (open) |\n\n'"$NEXT")"
expect_eq "$(printf '%s\n' "$T2" | decide_of M2)" "blocked
rc=0" "handoff: a 'not met' row in a second table -> blocked"
T2BAD="$(swap "$HO" "$NEXT" $'| Criterion | Status |\n|---|---|\n| Second gate | mostly met |\n\n'"$NEXT")"
expect_eq "$(hv "$T2BAD" one M2)" "HANDOFF: bad-status: M2: 3
rc=1" "handoff: a bogus status in a second table -> bad-status"
expect_eq "$(hv "$(printf '%s\n' "$HO" | sed 's/^## 5b\./## 5B./')" two M2)" "rc=0" "handoff: '## 5B. Lessons learned' (prefix case)"
# A table without a separator row as its second row is not a table: every row of it fails closed.
NOSEP="$(swap "$HO" "$NEXT" $'Text\n| 1 | a | not met |\n| 2 | b | met |\n\n'"$NEXT")"
expect_eq "$(hv "$NOSEP" one M2)" "HANDOFF: bad-status: M2: 3
HANDOFF: bad-status: M2: 4
rc=1" "handoff: table without a separator row -> bad-status on every row"
expect_eq "$(printf '%s\n' "$NOSEP" | decide_of M2)" "invalid
rc=0" "handoff: table without a separator row -> invalid"
LONE="$(swap "$HO" "$NEXT" $'| 1 | a | not met |\n\n'"$NEXT")"
expect_eq "$(printf '%s\n' "$LONE" | decide_of M2)" "invalid
rc=0" "handoff: a lone table row -> invalid"
SEPN="$(swap "$HO" "$NEXT" $'| Criterion | Status |\n|---|\n| Second gate | met |\n\n'"$NEXT")"
expect_eq "$(printf '%s\n' "$SEPN" | decide_of M2)" "invalid
rc=0" "handoff: separator cell count differs from the header -> invalid"
# Security review M2: where the parser and the GFM renderer disagree, fail closed.
# Renders as Notes 'x | met' and an empty Status: one cell short, so it fails closed.
ESC2="$(swap "$HO" "$NEXT" $'| C | Notes | Status |\n|---|---|---|\n| a | x \\| met |\n\n'"$NEXT")"
expect_eq "$(hv "$ESC2" one M2)" "HANDOFF: bad-status: M2: 3
rc=1" "handoff: escaped \\| plus a missing cell -> bad-status"
# A backtick fence whose info string holds a backtick is no fence: the table after it renders.
BTF="$(swap "$HO" "$NEXT" $'```x`\n| C | Status |\n|---|---|\n| tests pass | not met |\n```\n\n'"$NEXT")"
expect_eq "$(printf '%s\n' "$BTF" | decide_of M2)" "blocked
rc=0" "handoff: \`\`\`x\` is not a fence -> the 'not met' table counts"
expect_eq "$(printf '## M1 — A\nDepends-on: none\n\n### Task M1.1: a\n\n```x`\n\n## M2 — B\n\n### Task M2.1: b\n' | run_fn conduct_plan_units | cut -f1 | tr '\n' ' ')" \
  "M1 M2 rc=0 " "conduct_plan_units: \`\`\`x\` is not a fence"
expect_eq "$(printf '## M1 — A\n\n### Task M1.1: a\n\n~~~x`\n## M9 — fake\n~~~\n' | run_fn conduct_plan_units | cut -f1 | tr '\n' ' ')" \
  "M1 rc=0 " "conduct_plan_units: a tilde fence may hold a backtick in its info string"
# HTML hides or reveals markup the parser cannot see: any HTML block or comment fails closed.
DIV="$(swap "$HO" "$NEXT" $'<div>\n## Notes\n</div>\n\n| C | Status |\n|---|---|\n| b | not met |\n\n'"$NEXT")"
expect_eq "$(hv "$DIV" one M2)" "HANDOFF: html: <div>
HANDOFF: html: </div>
rc=1" "handoff: an HTML block -> html lines"
expect_eq "$(printf '%s\n' "$DIV" | decide_of M2)" "invalid
rc=0" "handoff: an HTML block -> invalid"
CMT="$(printf '%s\n' "$HO" | awk '/^## 6\. M2 entry criteria$/ { print "<!--" } /^## 7\./ { print "-->"; print "" } 1')"
expect_eq "$(printf '%s\n' "$CMT" | grep -c -e '^<!--$' -e '^-->$')" 2 "handoff: mutation wraps the entry criteria in a comment"
expect_eq "$(hv "$CMT" two M2)" "HANDOFF: html: <!--
rc=1" "handoff: entry criteria inside an HTML comment -> html line"
expect_eq "$(hv "$(printf '%s\n' "$HO" | sed 's/^No findings\.$/No findings <!-- x --> here./')" two M2)" "HANDOFF: html: No findings <!-- x --> here.
rc=1" "handoff: an inline HTML comment -> html line"
expect_eq "$(hv "$(printf '%s\n' "$HO" '```' '<div>' '```')" two M2)" "rc=0" "handoff: HTML inside a fence is code"
for h in '<?x a ?>' '<!DOCTYPE html>' '  <![CDATA[ x ]]>'; do
  expect_eq "$(hv "$(printf '%s\n' "$HO" "$h")" two M2)" "HANDOFF: html: $h
rc=1" "handoff: HTML block start '$h' -> html line"
done
# A table indented 4+ spaces is a code block; an indented row after a table fails closed.
IND="$(printf '%s\n' "$HO" | sed 's/^|/    |/')"
expect_eq "$(hv "$IND" one M2)" "HANDOFF: empty-entry-criteria: M2
HANDOFF: bad-line: M2: 25
HANDOFF: bad-line: M2: 26
HANDOFF: bad-line: M2: 27
HANDOFF: bad-line: M2: 28
rc=1" "handoff: entry criteria table indented 4 spaces -> empty, bad lines"
IND3="$(printf '%s\n' "$HO" | sed 's/^|/   |/')"
expect_eq "$(hv "$IND3" two M2)" "rc=0" "handoff: a table indented 3 spaces still counts"
ROW2='| 2 | Slow nightly job | accepted 2026-11-12; re-confirm in M2 | run 7 |'
CONT="$(swap "$HO" "$ROW2" "$ROW2"$'\n    | 3 | x | met | e |')"
expect_eq "$(hv "$CONT" one M2)" "HANDOFF: bad-status: M2: 3
HANDOFF: bad-line: M2: 29
rc=1" "handoff: an indented line continuing a table -> bad-status, bad line"
# Entry-criteria sections allow only blank lines, top-level tables and plain text (an allowlist).
for l in '> | 1 | a | not met |' '- see | not met' '### Notes' '1. first' '* x' '#	x' '  > quoted'; do
  BL="$(swap "$HO" "$NEXT" "$l"$'\n\n'"$NEXT")"
  expect_eq "$(hv "$BL" one M2)" "HANDOFF: bad-line: M2: 30
rc=1" "handoff: entry criteria line '$l' -> bad-line"
  expect_eq "$(printf '%s\n' "$BL" | decide_of M2)" "invalid
rc=0" "handoff: entry criteria line '$l' -> invalid"
done
SETX="$(swap "$HO" "$NEXT" $'Notes\n---\n\n'"$NEXT")"
expect_eq "$(hv "$SETX" one M2)" "HANDOFF: bad-line: M2: 31
rc=1" "handoff: a setext underline in entry criteria -> bad-line"
PLAIN="$(swap "$HO" "$NEXT" $'M5 criterion owned here. Status: met (record, G1).\n    indented text\n\n'"$NEXT")"
expect_eq "$(hv "$PLAIN" two M2)" "rc=0" "handoff: plain text in entry criteria is allowed"
# A heading indented 1-3 spaces is a heading (GFM): the section ends there.
IB="$(printf '%s\n' "$HO" | sed -e 's/^## 7\./   &/' -e 's/^Start M2\.$/- start | x/')"
expect_eq "$(hv "$IB" two M2)" "rc=0" "handoff: '   ## 7.' ends the entry criteria section"
IS="$(printf '%s\n' "$HO" | sed 's/^## 6\./  &/')"
expect_eq "$(printf '%s\n' "$IS" | decide_of M2)" "ok
rc=0" "handoff: '  ## 6. M2 entry criteria' opens the section"
# More than one Status column: no row can be read.
DUP="$(swap "$HO" '| # | Criterion | Status | Evidence |' '| # | Criterion | Status | status |')"
expect_eq "$(hv "$DUP" one M2)" "HANDOFF: bad-status: M2: 1
HANDOFF: bad-status: M2: 2
rc=1" "handoff: two Status columns -> bad-status on every row"

# ---- status and adopt: conduct_unit_status, conduct_dir, farmctl conduct lint|status|adopt ----
for c in '1 1 0 none 1=shipped' '1 0 1 none 1=shipped' '1 0 0 none 1=shipped-unreviewed' \
         '1 0 0 doing 1=shipped-unreviewed' '0 0 0 escalated 1=escalated' '0 0 0 review 1=review' \
         '0 0 0 doing 1=doing' '0 0 0 none 1=ready' '0 0 0 none 0=backlog' '0 0 0 bogus 1=escalated'; do
  # shellcheck disable=SC2086  # the five arguments are word-split on purpose
  got="$(run_fn conduct_unit_status ${c%%=*} </dev/null)"
  expect_eq "$got" "${c#*=}
rc=0" "status: conduct_unit_status ${c%%=*}"
done
got="$(FARM_REPO_SLUG=own/repo XDG_STATE_HOME=/xs run_fn conduct_dir </dev/null)"
expect_eq "$got" "/xs/agent-farm/own__repo/conduct
rc=0" "status: conduct_dir"
got="$(FARM_REPO_SLUG='' run_fn conduct_dir </dev/null)"
expect_eq "$got" "rc=2" "status: conduct_dir without a repo slug"
# conduct_repo_slug <origin url> -> owner/repo (https, ssh, scp-like, local path; .git and a
# trailing / stripped); rc 1 when no owner/repo can be read.
for c in 'https://github.com/own/repo.git=own/repo' 'https://user@host.example/own/repo/=own/repo' \
         'ssh://git@host.example:22/own/repo.git=own/repo' 'git@github.com:own/repo.git=own/repo' \
         'git@github.com:own/repo=own/repo' '/tmp/x/repo.1/origin.git=repo.1/origin' 'file:///srv/git/own/repo=own/repo'; do
  expect_eq "$(run_fn conduct_repo_slug "${c%=*}" </dev/null)" "${c##*=}
rc=0" "conduct_repo_slug ${c%=*}"
done
for bad in '' 'repo' '/repo' 'https://host.example/repo' 'git@host:repo.git'; do
  expect_eq "$(run_fn conduct_repo_slug "$bad" </dev/null)" "rc=1" "conduct_repo_slug rejects '$bad'"
done
if [[ -f "$LIB" && ! -x "$LIB" ]] && ! head -1 "$LIB" | grep '^#!' >/dev/null; then ok
else nope "status: farm-conduct-lib.sh is not executable and has no shebang"; fi
if [[ -x "$FARM/bin/farm-conduct.sh" ]]; then ok; else nope "status: bin/farm-conduct.sh is executable"; fi

# Physical and normalized once: macOS TMPDIR ends in '/' (a '//' in every built path) and /var is
# a symlink to /private/var, while cd and pwd in the code under test yield the canonical form.
TROOT="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/conduct-test.XXXXXX")" && pwd -P)"
trap 'rm -rf "$TROOT"' EXIT
PP=docs/superpowers/plans/p.md
KEYS='["attempts","claimed_by","depends_on","handoff_path","id","owner_ref","plan","prs","status","stop_reason","title","unit","usage"]'
gitq() { git -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false "$@"; }
# stdout: a work tree with a local bare origin; the fixture plan as $PP on main.
mk_conduct_repo() {
  local d; d="$(mktemp -d "$TROOT/repo.XXXXXX")"
  git init -q --bare "$d/origin.git" && git -C "$d/origin.git" symbolic-ref HEAD refs/heads/main
  git init -q "$d/w" && git -C "$d/w" checkout -q -b main
  mkdir -p "$d/w/docs/superpowers/plans" "$d/w/.agent-farm"
  cp "$FARM/contract/fixtures/plan.md" "$d/w/$PP"
  mkdir -p "$d/w/docs/superpowers/specs"; printf '# spec\n' > "$d/w/docs/superpowers/specs/p-spec.md"
  printf 'FARM_VERIFY_CMD=./verify.sh\n' > "$d/w/.agent-farm/farm.env"
  printf '#!/bin/sh\nexit 0\n' > "$d/w/verify.sh"; chmod +x "$d/w/verify.sh"
  gitq -C "$d/w" add -A && gitq -C "$d/w" commit -qm init
  git -C "$d/w" remote add origin "$d/origin.git" && git -C "$d/w" push -q origin main 2>/dev/null
  printf '%s\n' "$d/w"
}
# <work tree> <relative path> <content>: commit and push to origin/main.
push_file() {
  mkdir -p "$1/$(dirname "$2")"; printf '%s\n' "$3" > "$1/$2"
  gitq -C "$1" add -- "$2" && gitq -C "$1" commit -qm "add $2" && git -C "$1" push -q origin main 2>/dev/null
}
# The conductor directory, computed here independently of the library.
cdir_of() { local o; o="$(dirname "$1")"; printf '%s/agent-farm/%s__origin/conduct\n' "$XS" "$(basename "$o")"; }
# <work tree> <args...>: farmctl conduct, stdout+stderr, then "rc=N". Runs from / with a
# foreign CLAUDE_PROJECT_DIR so only FARM_REPO_DIR names the repository.
fc() {
  local r="$1"; shift
  (cd / && env -u MAIN_BRANCH -u REPO_DIR FARM_REPO_DIR="$r" CLAUDE_PROJECT_DIR=/some/other/repo \
     XDG_STATE_HOME="$XS" FETCH_MAX_TRIES=1 "$BASH" "$FARM/bin/farmctl" conduct "$@" </dev/null 2>&1); echo "rc=$?"
}
rows_of() { printf '%s\n' "$1" | sed '$d'; }   # drop the trailing rc= line
XS="$TROOT/xdg"; mkdir -p "$XS"
R="$(mk_conduct_repo)"

# [smoke] lint prints both unit ids
got="$(fc "$R" lint "$PP")"
case "$got" in *"$PP#M1"*"$PP#M2"*"rc=0") ok ;; *) nope "lint: fixture plan -> exit 0 and both ids: got=[$got]" ;; esac
# [smoke] status --json on a fresh repository
got="$(fc "$R" status "$PP" --json)"
expect_eq "$(rows_of "$got" | jq -r '[.[] | .status] | join(",")' 2>/dev/null)" "ready,backlog" "status: fresh repo statuses"
expect_eq "$(rows_of "$got" | jq -c '[.[] | keys] | unique' 2>/dev/null)" "[$KEYS]" "status: row keys"
expect_eq "$(rows_of "$got" | jq -c '.[1] | [.id, .depends_on, .handoff_path, .prs, .claimed_by, .owner_ref, .attempts.sessions, .usage.sessions]' 2>/dev/null)" \
  "[\"$PP#M2\",[\"$PP#M1\"],\"docs/superpowers/handoffs/p-m2-handoff.md\",[],null,null,0,0]" "status: row 2 fields"
expect_eq "${got##*rc=}" 0 "status: fresh repo exit 0"
# [smoke] adopt a differently named, valid handoff on main
A="$(mk_conduct_repo)"
push_file "$A" docs/superpowers/handoffs/older-name.md "$HO"
got="$(fc "$A" adopt "$PP" M1 docs/superpowers/handoffs/older-name.md)"
expect_eq "${got##*rc=}" 0 "adopt: valid handoff -> exit 0"
expect_eq "$(jq -c '[.plan, .unit, .handoff_path, (.sha | test("^[0-9a-f]{40}$")), (.adopted_at | length > 0)]' "$(cdir_of "$A")/adopted.jsonl" 2>/dev/null)" \
  "[\"$PP\",\"M1\",\"docs/superpowers/handoffs/older-name.md\",true,true]" "adopt: adopted.jsonl has the record"
expect_eq "$(wc -l < "$(cdir_of "$A")/adopted.jsonl" 2>/dev/null | tr -d ' ')" 1 "adopt: one line"
got="$(fc "$A" status "$PP" --json)"
expect_eq "$(rows_of "$got" | jq -r '[.[] | .status, .handoff_path] | join(",")' 2>/dev/null)" \
  "shipped,docs/superpowers/handoffs/older-name.md,ready,docs/superpowers/handoffs/p-m2-handoff.md" "adopt: row 1 shipped"
# [smoke] lint refuses a plan no protected glob on origin/main covers; the work tree's list does not count
push_file "$A" notes/p.md "$(cat "$A/$PP")"
printf 'notes/*\n' > "$A/.agent-farm/protected-paths.txt"
got="$(fc "$A" lint notes/p.md)"
case "$got" in *"plan-unprotected"*notes/p.md*"docs/superpowers/plans/"*"rc=1") ok ;; *) nope "lint: unprotected plan -> exit 1, plan-unprotected naming the plan and the fix: got=[$got]" ;; esac
mkdir -p "$A/specs"; printf '# spec\n' > "$A/specs/p-spec.md"   # the fixture's ../specs/p-spec.md, seen from notes/
gitq -C "$A" add -A && gitq -C "$A" commit -qm protect && git -C "$A" push -q origin main 2>/dev/null
got="$(fc "$A" lint notes/p.md)"
case "$got" in *"notes/p.md#M1"*"rc=0") ok ;; *) nope "lint: plan covered by the project list on origin/main -> exit 0: got=[$got]" ;; esac
# [smoke] lint refuses a plan without a Spec line, and one whose spec is only in the work tree, not on origin/main
push_file "$A" docs/superpowers/plans/nospec.md "$(grep -v '^\*\*Spec:\*\*' "$A/$PP")"
got="$(fc "$A" lint docs/superpowers/plans/nospec.md)"
case "$got" in *"no-spec"*nospec.md*"rc=1") ok ;; *) nope "lint: a plan without a Spec line -> exit 1, no-spec: got=[$got]" ;; esac
push_file "$A" docs/superpowers/plans/wtspec.md "$(sed 's#p-spec.md#wt-spec.md#' "$A/$PP")"
printf '# only here\n' > "$A/docs/superpowers/specs/wt-spec.md"
got="$(fc "$A" lint docs/superpowers/plans/wtspec.md)"
case "$got" in *"spec-missing"*docs/superpowers/specs/wt-spec.md*"rc=1") ok ;; *) nope "lint: a spec only in the work tree -> exit 1, spec-missing naming it: got=[$got]" ;; esac
rm -f "$A/docs/superpowers/specs/wt-spec.md"

# [smoke] install.sh --conductor-only, then a plan with its spec: lint is clean (no
# protected-paths.txt, so the plugin default covers the plan) and the conductor reads
# FARM_VERIFY_CMD from farm.env on origin/main.
CO="$(mktemp -d "$TROOT/co.XXXXXX")"
git init -q --bare "$CO/origin.git" && git -C "$CO/origin.git" symbolic-ref HEAD refs/heads/main
git init -q "$CO/w" && git -C "$CO/w" checkout -q -b main
"$BASH" "$FARM/engine/install.sh" --init-project "$CO/w" --conductor-only --verify-cmd './verify.sh --all' </dev/null >/dev/null 2>&1
expect_eq "$?" 0 "conductor-only setup: install exits 0"
mkdir -p "$CO/w/docs/superpowers/plans" "$CO/w/docs/superpowers/specs"
cp "$FARM/contract/fixtures/plan.md" "$CO/w/$PP"; printf '# spec\n' > "$CO/w/docs/superpowers/specs/p-spec.md"
gitq -C "$CO/w" add -A && gitq -C "$CO/w" commit -qm init
git -C "$CO/w" remote add origin "$CO/origin.git" && git -C "$CO/w" push -q origin main 2>/dev/null
got="$(fc "$CO/w" lint "$PP")"
case "$got" in *"$PP#M1"*"rc=0") ok ;; *) nope "conductor-only setup: lint exit 0: got=[$got]" ;; esac
expect_eq "$(git -C "$CO/w" show origin/main:.agent-farm/farm.env | run_fn conduct_env_value FARM_VERIFY_CMD)" "./verify.sh --all"$'\n'"rc=0" \
  "conductor-only setup: verify command read from origin/main"

if is_full; then
  cp "$R/$PP" "$R/docs/superpowers/plans/local.md"
  got="$(fc "$R" lint docs/superpowers/plans/local.md)"
  case "$got" in *origin/main*"rc=1") ok ;; *) nope "lint: work-tree-only plan -> exit 1 naming origin/main: got=[$got]" ;; esac
  push_file "$R" docs/superpowers/handoffs/p-m1-handoff.md "$HO"
  got="$(fc "$R" status "$PP" --json)"
  expect_eq "$(rows_of "$got" | jq -r '[.[] | .status] | join(",")' 2>/dev/null)" "shipped-unreviewed,backlog" "status: handoff on main, no record"
  mkdir -p "$(cdir_of "$R")"
  printf '%s\n' 'not json' "{\"plan\":\"other.md\",\"unit\":\"M1\"}" \
    "{\"plan\":\"$PP\",\"unit\":\"M1\",\"start_sha\":\"a\",\"end_sha\":\"b\",\"review_session_id\":\"s\",\"verdict\":\"pass\",\"high\":0,\"medium\":0,\"low\":1,\"log_path\":\"l\",\"ts\":\"2026-11-16T00:00:00Z\"}" \
    > "$(cdir_of "$R")/reviews.jsonl"
  got="$(fc "$R" status "$PP" --json)"
  expect_eq "$(rows_of "$got" | jq -r '[.[] | .status] | join(",")' 2>/dev/null)" "shipped,ready" "status: review record for M1"
  # text output names every unit and its status
  got="$(fc "$R" status "$PP")"
  case "$got" in *M1*shipped*M2*ready*"rc=0") ok ;; *) nope "status: text output: got=[$got]" ;; esac
  # conductor state: a doing M2 with counters, prs, a stop reason; a bad counter reads 0
  U2="$(cdir_of "$R")/p/m2"; mkdir -p "$U2"
  echo doing > "$U2/state"; echo 3 > "$U2/attempts"; echo x1 > "$U2/rework"; echo 2 > "$U2/continuation"
  printf '41\nabc\n42\n' > "$U2/prs"; echo 'waiting for an operator merge' > "$U2/stop_reason"
  printf '%s\n' "{\"plan\":\"$PP\",\"unit\":\"M2\",\"in\":10,\"out\":5,\"cost_usd\":0.5,\"wall_s\":7}" \
    "{\"plan\":\"$PP\",\"unit\":\"M2\",\"in\":1,\"out\":\"x\"}" > "$(cdir_of "$R")/usage.jsonl"
  got="$(fc "$R" status "$PP" --json)"
  expect_eq "$(rows_of "$got" | jq -c '.[1] | [.status, .prs, .stop_reason, .attempts, .usage]' 2>/dev/null)" \
    '["doing",[41,42],"waiting for an operator merge",{"sessions":3,"rework":0,"continuation":2,"interruption":0},{"sessions":2,"in":11,"out":5,"cache_read":0,"cache_creation":0,"cost_usd":0.5,"wall_s":7}]' \
    "status: conductor state read into row 2"
  # Verify runs (role verify) are not sessions: status leaves them out of the usage sum.
  printf '%s\n' "{\"plan\":\"$PP\",\"unit\":\"M2\",\"role\":\"verify\",\"phase\":\"preflight\",\"outcome\":\"pass\",\"exit_code\":0,\"wall_s\":3}" >> "$(cdir_of "$R")/usage.jsonl"
  got="$(fc "$R" status "$PP" --json)"
  expect_eq "$(rows_of "$got" | jq -c '.[1].usage | [.sessions, .wall_s]' 2>/dev/null)" '[2,7]' "status: a verify usage line is not a session"
  rm -rf "$U2" "$(cdir_of "$R")/usage.jsonl"
  # adopt refusals: absent from origin/main, failing phase two
  B="$(mk_conduct_repo)"
  mkdir -p "$B/docs/superpowers/handoffs"; printf '%s\n' "$HO" > "$B/docs/superpowers/handoffs/local.md"
  got="$(fc "$B" adopt "$PP" M1 docs/superpowers/handoffs/local.md)"
  [[ ! -e "$(cdir_of "$B")/adopted.jsonl" ]] || got+=" WROTE adopted.jsonl"   # nothing written
  case "$got" in *origin/main*"rc=1") ok ;; *) nope "adopt: path absent from origin/main -> exit 1, nothing written: got=[$got]" ;; esac
  push_file "$B" docs/superpowers/handoffs/nosec.md "$NOSEC"
  got="$(fc "$B" adopt "$PP" M1 docs/superpowers/handoffs/nosec.md)"
  [[ ! -e "$(cdir_of "$B")/adopted.jsonl" ]] || got+=" WROTE adopted.jsonl"   # nothing written
  case "$got" in *"HANDOFF: missing-section: security-review"*"rc=1") ok ;; *) nope "adopt: phase two failure -> HANDOFF lines, exit 1, nothing written: got=[$got]" ;; esac
  # the contract fixture rows match the status --json row shape and vocabulary
  ROWS="$FARM/contract/fixtures/unit-rows.json"
  shape='[.[] | (keys) + (.attempts | keys | map("attempts." + .)) + (.usage | keys | map("usage." + .))] | unique'
  live="$(rows_of "$(fc "$R" status "$PP" --json)" | jq -c "$shape" 2>/dev/null)"
  [[ "$live" == '[['*']]' ]] || ROWS=/nonexistent   # no live rows: every fixture assertion fails
  expect_eq "$(jq -c "$shape" "$ROWS" 2>/dev/null)" "${live:-<no live rows>}" "status: fixture rows have the live key set"
  [[ "$live" == '[['*']]' ]] && ok || nope "status: live key set is one non-empty set: [$live]"
  expect_eq "$(jq -r '[.[] | .status] | join(",")' "$ROWS" 2>/dev/null)" "shipped,doing,escalated,backlog" "status: fixture row statuses"
  expect_eq "$(jq '[.[] | select(.status == "escalated") | .stop_reason | strings] | length' "$ROWS" 2>/dev/null)" 1 "status: fixture escalated row has a stop_reason"
  expect_eq "$(jq '[.[] | .status | select(IN("backlog","ready","doing","review","shipped","escalated","shipped-unreviewed") | not)] | length' "$ROWS" 2>/dev/null)" 0 "status: fixture statuses in the vocabulary"
  # no origin -> environment error
  N="$(mk_conduct_repo)"; git -C "$N" remote remove origin
  for cmd in lint status; do
    got="$(fc "$N" "$cmd" "$PP")"
    case "$got" in *"no origin"*"rc=2") ok ;; *) nope "status: no origin, $cmd -> exit 2: got=[$got]" ;; esac
  done
  # CONDUCT_LONG_WAIT: lint prints the not-eligible line only when it is 0
  got="$(CONDUCT_LONG_WAIT=0 fc "$R" lint "$PP")"
  expect_eq "$(printf '%s\n' "$got" | grep -c 'not eligible')${got##*rc=}" 10 "lint: CONDUCT_LONG_WAIT=0 -> one not-eligible line, exit 0"
  got="$(CONDUCT_LONG_WAIT=1 fc "$R" lint "$PP")"
  expect_eq "$(printf '%s\n' "$got" | grep -c 'not eligible')${got##*rc=}" 00 "lint: CONDUCT_LONG_WAIT=1 -> no such line"
  # usage errors
  got="$(fc "$R" status)"
  case "$got" in *"usage: farmctl conduct"*"rc=1") ok ;; *) nope "status: no plan argument -> usage, exit 1: got=[$got]" ;; esac
  got="$(fc "$R" status ../x.md)"
  case "$got" in *"bad plan path"*"rc=1") ok ;; *) nope "status: unsafe plan path -> exit 1: got=[$got]" ;; esac
  # jq missing -> environment error (PD26), not 127: PATH mirrors the current one without jq.
  NOJQ="$TROOT/nojq"; mkdir -p "$NOJQ"
  while IFS= read -r d; do
    [[ -d "$d" ]] || continue
    for f in "$d"/*; do
      b="${f##*/}"; [[ "$b" == jq || -e "$NOJQ/$b" || ! -x "$f" ]] || ln -s "$f" "$NOJQ/$b"
    done
  done < <(printf '%s\n' "$PATH" | tr ':' '\n')
  got="$(PATH="$NOJQ" fc "$R" status "$PP")"
  case "$got" in *"jq"*"rc=2") ok ;; *) nope "status: jq missing -> message naming jq, exit 2: got=[$got]" ;; esac
  # Security review M2 #5: an overlong pid or counter reads 0; no kill -0 -1.
  U1="$(cdir_of "$R")/p/m1"; mkdir -p "$U1"
  echo 18446744073709551615 > "$U1/pid"; echo 99999999999999999999 > "$U1/attempts"
  got="$(fc "$R" status "$PP" --json)"
  expect_eq "$(rows_of "$got" | jq -c '.[0] | [.claimed_by, .attempts.sessions]' 2>/dev/null)" '[null,0]' \
    "status: 20-digit pid and counter -> not claimed, 0"
  rm -rf "$U1"
  # #1: a local tag and branch named origin/main must not stand in for the remote-tracking ref.
  G="$(mk_conduct_repo)"; GH=docs/superpowers/handoffs/p-m1-handoff.md
  gitq -C "$G" checkout -q -b side && mkdir -p "$G/docs/superpowers/handoffs" && printf '%s\n' "$HO" > "$G/$GH"
  gitq -C "$G" add -- "$GH" && gitq -C "$G" commit -qm forged
  git -C "$G" tag origin/main && git -C "$G" branch origin/main && gitq -C "$G" checkout -q main
  got="$(fc "$G" adopt "$PP" M1 "$GH")"
  [[ ! -e "$(cdir_of "$G")/adopted.jsonl" ]] || got+=" WROTE adopted.jsonl"
  case "$got" in *WROTE*) nope "adopt: forged local origin/main -> exit 1, nothing written: got=[$got]" ;; *"rc=1") ok ;;
    *) nope "adopt: forged local origin/main -> exit 1, nothing written: got=[$got]" ;; esac
  got="$(fc "$G" status "$PP" --json)"
  expect_eq "$(rows_of "$got" | jq -r '[.[] | .status] | join(",")' 2>/dev/null)" "ready,backlog" "status: forged local origin/main ignored"
  # #2: a work-tree farm.env must not steer the main branch, the state dir, PATH or git.
  F="$(mk_conduct_repo)"
  gitq -C "$F" checkout -q -b forge && mkdir -p "$F/docs/superpowers/handoffs" && printf '%s\n' "$HO" > "$F/$GH"
  gitq -C "$F" add -- "$GH" && gitq -C "$F" commit -qm forged && git -C "$F" push -q origin forge 2>/dev/null
  gitq -C "$F" checkout -q main
  clean_s="$(fc "$F" status "$PP" --json)"; clean_a="$(fc "$F" adopt "$PP" M1 "$GH")"
  ATT="$TROOT/attacker"; FAKE="$TROOT/fakebin"; mkdir -p "$ATT" "$FAKE"
  printf '#!/bin/sh\n: > "%s/jq-ran"\nexec "%s" "$@"\n' "$ATT" "$(command -v jq)" > "$FAKE/jq"; chmod +x "$FAKE/jq"
  printf '%s\n' 'FARM_VERIFY_CMD=./verify.sh' 'MAIN_BRANCH=forge' "XDG_STATE_HOME=$ATT" "PATH=\"$FAKE:\$PATH\"" \
    'git() { case "$*" in *cat-file*) return 0 ;; *) command git "$@" ;; esac; }' > "$F/.agent-farm/farm.env"
  got="$(fc "$F" status "$PP" --json)"
  expect_eq "$got" "$clean_s" "status: hostile work-tree farm.env -> same rows as the clean run"
  got="$(fc "$F" adopt "$PP" M1 "$GH")"
  expect_eq "$got" "$clean_a" "adopt: hostile work-tree farm.env -> same refusal as the clean run"
  expect_eq "$(ls -A "$ATT")" "" "farm.env: nothing written to the attacker state dir, fake jq not run"
  # Re-review probes: farm.env is never executed, so none of these reaches the gate.
  FSHA="$(git -C "$F" rev-parse forge)"
  FORGED="$TROOT/forged.git"; git clone -q --bare "$(dirname "$F")/origin.git" "$FORGED" 2>/dev/null
  git -C "$F" push -q "$FORGED" forge:main --force 2>/dev/null
  probe() { # <name> <farm.env lines...>
    local n="$1"; shift; printf '%s\n' 'FARM_VERIFY_CMD=./verify.sh' "$@" > "$F/.agent-farm/farm.env"
    expect_eq "$(fc "$F" status "$PP" --json)" "$clean_s" "status: farm.env probe $n -> clean rows"
    expect_eq "$(fc "$F" adopt "$PP" M1 "$GH")" "$clean_a" "adopt: farm.env probe $n -> clean refusal"
  }
  probe farm_timeout "farm_timeout() { shift; case \"\$*\" in *ls-remote*) printf 'ref: refs/heads/main\\tHEAD\\n$FSHA\\tHEAD\\n' ;; *) \"\$@\" ;; esac; }"
  probe unset-builtin 'unset() { :; }' 'builtin() { :; }' \
    'git() { case "$*" in *cat-file*) return 0 ;; *) command git "$@" ;; esac; }'
  probe git-config 'export GIT_CONFIG_COUNT=1' "export GIT_CONFIG_KEY_0=url.$FORGED.insteadOf" \
    "export GIT_CONFIG_VALUE_0=$(dirname "$F")/origin.git"
  # A local origin/HEAD moved to another pushed branch is not the main branch: origin's own HEAD is.
  gitq -C "$F" checkout -q -- .agent-farm/farm.env && git -C "$F" remote set-head origin forge >/dev/null
  expect_eq "$(fc "$F" status "$PP" --json)" "$clean_s" "status: local origin/HEAD -> forge ignored"
  expect_eq "$(fc "$F" adopt "$PP" M1 "$GH")" "$clean_a" "adopt: local origin/HEAD -> forge ignored"
  # A moved refs/remotes/origin/main (fetch refspec no longer heals it) is not origin's main either.
  git -C "$F" config remote.origin.fetch '+refs/heads/forge:refs/remotes/origin/forge'
  git -C "$F" update-ref refs/remotes/origin/main refs/remotes/origin/forge
  expect_eq "$(fc "$F" status "$PP" --json)" "$clean_s" "status: forged refs/remotes/origin/main ignored"
  expect_eq "$(fc "$F" adopt "$PP" M1 "$GH")" "$clean_a" "adopt: forged refs/remotes/origin/main ignored"
  # origin's main tip not fetched (the refspec skips main) -> exit 2.
  C2="$TROOT/c2"; git clone -q "$(dirname "$F")/origin.git" "$C2" 2>/dev/null
  gitq -C "$C2" commit -q --allow-empty -m newer && git -C "$C2" push -q origin main 2>/dev/null
  got="$(fc "$F" status "$PP")"
  case "$got" in *"not fetched"*"rc=2") ok ;; *) nope "status: origin main tip missing locally -> exit 2: got=[$got]" ;; esac
  # The main branch is origin's own HEAD (git ls-remote); no fallback to local refs.
  T="$(mk_conduct_repo)"; TO="$(dirname "$T")/origin.git"
  git -C "$T" push -q origin main:trunk 2>/dev/null && git -C "$TO" symbolic-ref HEAD refs/heads/trunk
  git -C "$T" push -q origin --delete main 2>/dev/null
  got="$(fc "$T" status "$PP" --json)"
  expect_eq "$(rows_of "$got" | jq -r '[.[] | .status] | join(",")' 2>/dev/null)${got##*rc=}" "ready,backlog0" "status: origin HEAD -> trunk"
  git -C "$TO" symbolic-ref HEAD refs/heads/gone
  got="$(fc "$T" status "$PP")"
  case "$got" in *"rc=2") ok ;; *) nope "status: origin HEAD -> an unborn branch -> exit 2: got=[$got]" ;; esac
  git -C "$TO" update-ref refs/heads/-x refs/heads/trunk && git -C "$TO" symbolic-ref HEAD refs/heads/-x
  got="$(fc "$T" status "$PP")"
  case "$got" in *"no valid branch"*"rc=2") ok ;; *) nope "status: origin HEAD -> an invalid branch name -> exit 2: got=[$got]" ;; esac
  git -C "$TO" symbolic-ref HEAD refs/heads/trunk && git -C "$T" remote set-url origin "$TROOT/missing.git"
  got="$(fc "$T" status "$PP")"
  case "$got" in *"ls-remote"*"rc=2") ok ;; *) nope "status: origin unreachable -> exit 2 naming ls-remote: got=[$got]" ;; esac
  # A hanging ls-remote is bounded by the conductor's own watchdog (no timeout binary needed).
  HANG="$TROOT/hangbin"; mkdir -p "$HANG"
  printf '#!/bin/sh\ncase "$*" in *ls-remote*) exec sleep 300 ;; esac\nexec "%s" "$@"\n' "$(command -v git)" > "$HANG/git"
  chmod +x "$HANG/git"
  t0=$SECONDS; got="$(PATH="$HANG:$PATH" fc "$R" status "$PP")"; dt=$((SECONDS - t0))
  case "$got" in *"ls-remote"*"rc=2") ok ;; *) nope "status: hanging ls-remote -> exit 2 naming ls-remote: got=[$got]" ;; esac
  [[ "$dt" -lt 120 ]] && ok || nope "status: hanging ls-remote bounded under 120s: took ${dt}s"
fi

# The conductor never sources farm-lib.sh, so a work tree's farm.env is never executed.
if grep -v '^[[:space:]]*#' "$FARM/bin/farm-conduct.sh" \
   | grep -E '(^|[;&|({[:space:]])(source|\.)[[:space:]]+[^#]*farm-lib\.sh' >/dev/null; then
  nope "farm-conduct.sh sources farm-lib.sh"
else ok; fi
[[ -f "$FARM/bin/farm-conduct.sh" ]] && ok || nope "farm-conduct.sh exists"

# ---- the hermetic gh and claude fakes (section "fakes") ----
STUBS="$HERE/stubs/conduct"
# Builds a repository and the whole fake environment in the CURRENT shell: globals
# CS (scratch), CSR (work tree), CSO (bare origin), CDIR (conductor dir), CSU (unit 1 state dir).
cs_setup() {
  CS="$(mktemp -d "$TROOT/cs.XXXXXX")"
  CSR="$(mk_conduct_repo)"; CSO="$(dirname "$CSR")/origin.git"
  CDIR="$CS/xdg/agent-farm/$(basename "$(dirname "$CSR")")__origin/conduct"
  CSU="$CDIR/p/m1"
  mkdir -p "$CSU" "$CSR/.agent-farm/state" "$CS/bin" "$CS/gh" "$CS/claude"
  # A wrapper, not a symlink: with the stub missing it fails (127) instead of letting PATH fall through to a real gh.
  printf '#!/bin/sh\nexec "%s/gh" "$@"\n' "$STUBS" > "$CS/bin/gh"; chmod +x "$CS/bin/gh"
  printf '#!/bin/sh\nprintf "%%s %%s %%s\\n" "$1" "$2" "$3" >> "%s/notify.log"\ncat >> "%s/notify.stdin"\n(wc -l < "%s/reviews.jsonl" 2>/dev/null || echo 0) | tr -d " " >> "%s/notify.records"\n' \
    "$CS" "$CS" "$CDIR" "$CS" > "$CS/notify.sh"
  chmod +x "$CS/notify.sh"
  export PATH="$CS/bin:$PATH" GH_FAKE_DIR="$CS/gh" GH_FAKE_ORIGIN="$CSO" CLAUDE_FAKE_DIR="$CS/claude" \
    CLAUDE_BIN="$STUBS/claude" XDG_STATE_HOME="$CS/xdg" FARM_REPO_DIR="$CSR" CLAUDE_PLUGIN_ROOT="$FARM" \
    CLAUDE_FAKE_SNAPSHOT="$CSU" INFRA_BACKOFF_SECONDS=1 CONDUCT_GATE_POLL_SECONDS=1 CONDUCT_CHECKS_POLL_SECONDS=1 \
    CONDUCT_CHECKS_TIMEOUT_SECONDS=3 CONDUCT_INIT_TIMEOUT_SECONDS=5 CONDUCT_VERIFY_TIMEOUT_SECONDS=120 \
    CONDUCT_GUARD_MODE=settings CONDUCT_PIN_FLAGS=--strict-mcp-config FARM_NOTIFY_CMD="$CS/notify.sh"
  if [[ -x "$STUBS/gh" && -x "$STUBS/claude" && "$(command -v gh)" == "$CS/bin/gh" ]]; then return 0; fi
  echo "cs_setup: fake stubs missing or gh does not resolve to the fake" >&2; return 1
}
# Background: wait for the limit-gate file, copy it to $CS/gate.seen, remove it.
cs_open_gate() {
  local g="$CSR/.agent-farm/state/limit-until" seen="$CS/gate.seen"
  ( i=0; while [ "$i" -lt 600 ]; do
      if [ -f "$g" ]; then cat "$g" > "$seen"; rm -f "$g"; exit 0; fi
      sleep 0.2; i=$((i+1))
    done ) </dev/null >/dev/null 2>&1 &
}
# <handoff out> <branch>: a context block like the conductor's.
ctx_prompt() {
  printf 'Lead prompt.\n<conduct_context>\nPLAN: %s\nUNIT: M1\nHANDOFF_OUT: %s\nHANDOFF_BRANCH: %s\nVERIFY_CMD: ./verify.sh\n</conduct_context>\n' "$PP" "$1" "$2"
}
fk_hit_limit() { (FARM_REPO_DIR="$CSR"; source "$FARM/bin/farm-lib.sh" && output_hit_limit "$(cat "$1")") >/dev/null 2>&1; }
fk_transient() { (FARM_REPO_DIR="$CSR"; source "$FARM/bin/farm-lib.sh" && output_transient_infra_error "$(cat "$1")" 1) >/dev/null 2>&1; }

if cs_setup; then ok; else nope "fakes: cs_setup: both stubs exist and gh resolves to the fake"; fi
HOUT=docs/superpowers/handoffs/p-m1-handoff.md; HBR=conduct/p/m1/handoff
printf 'handoff\nlimit\ntransient\nhandoff-quote\nnothing\n' > "$CS/claude/script"
printf '# the handoff\n' > "$CS/claude/handoff.md"
printf '{"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"/p/guard-bash.sh"}]}]}}\n' > "$CS/settings.json"
echo "cached" > "$CSU/state"
fk() { (cd "$CSR" && "$CLAUDE_BIN" -p "$(ctx_prompt "$HOUT" "$HBR")" "$@" </dev/null > "$CS/out.$FKN" 2>/dev/null); }
FKN=1; fk --plugin-dir "$FARM"
if git -C "$CSO" rev-parse --verify -q "refs/heads/$HBR" >/dev/null; then ok; else nope "fakes: handoff -> origin has the handoff branch"; fi
expect_eq "$(jq -c '[.[] | [.state, [.files[].path]]]' "$CS/gh/prs.json" 2>/dev/null)" "[[\"OPEN\",[\"$HOUT\"]]]" "fakes: handoff -> one OPEN pull request with exactly HANDOFF_OUT"
expect_eq "$(head -1 "$CS/out.1" | jq -c '[.session_id, .plugins[0].name, .plugins[0].path, (.tools|length>0), .apiKeySource, .hooks]' 2>/dev/null)" \
  "[\"00000000-0000-0000-0000-000000000001\",\"agent-farm\",\"$FARM\",true,\"none\",[]]" "fakes: init event"
expect_eq "$(jq -c '[.message.content[] | .name, (.input.model // .input.command)]' <<<"$(sed -n 2p "$CS/out.1")" 2>/dev/null)" '["Agent","haiku","Bash","./verify.sh"]' "fakes: assistant event"
grep 'FARM-GUARD BLOCKED' "$CS/out.1" >/dev/null && ok || nope "fakes: tool result holds FARM-GUARD BLOCKED"
expect_eq "$(tail -1 "$CS/out.1" | jq -c '[.is_error, (.modelUsage|length)]' 2>/dev/null)" "[false,2]" "fakes: success result with two models"
[[ -f "$CS/claude/argv.1" && -f "$CS/claude/prompt.1" && -f "$CS/claude/env.1" && -f "$CS/claude/cwd.1" && -f "$CS/claude/pid.1" && -f "$CS/claude/snap.1/state" ]] && ok || nope "fakes: argv/prompt/env/cwd/pid/snap saved"
FKN=2; fk; expect_eq "$(tail -1 "$CS/out.2" | jq -c '.is_error' 2>/dev/null)" true "fakes: limit -> error result"
if [[ -f "$CS/out.2" ]] && fk_hit_limit "$CS/out.2"; then ok; else nope "fakes: limit log: output_hit_limit -> 0"; fi
FKN=3; fk
if [[ -f "$CS/out.3" ]] && fk_transient "$CS/out.3"; then ok; else nope "fakes: transient log: output_transient_infra_error ... 1 -> 0"; fi
FKN=4; fk
if [[ -f "$CS/out.4" ]] && fk_hit_limit "$CS/out.4"; then ok; else nope "fakes: handoff-quote log: output_hit_limit -> 0"; fi
expect_eq "$(jq 'length' "$CS/gh/prs.json")" 1 "fakes: second handoff opens no second pull request"
expect_eq "$(git -C "$CSO" rev-list --count "main..$HBR" 2>/dev/null)" 2 "fakes: second handoff adds a commit"
FKN=5; fk --settings "$CS/settings.json"
expect_eq "$(head -1 "$CS/out.5" | jq -c '.hooks' 2>/dev/null)" '["/p/guard-bash.sh"]' "fakes: --settings hook commands in init .hooks"
# Invocation 10 still gets a 36-character session id.
mkdir -p "$CS/fk10"; for i in 1 2 3 4 5 6 7 8 9; do : > "$CS/fk10/argv.$i"; done
got="$(cd "$CSR" && CLAUDE_FAKE_DIR="$CS/fk10" CLAUDE_FAKE_SNAPSHOT='' "$CLAUDE_BIN" -p x </dev/null 2>/dev/null | head -1 | jq -r .session_id 2>/dev/null)"
expect_eq "$got" 00000000-0000-0000-0000-000000000010 "fakes: invocation 10 -> session id ...000000000010"
# apikey: the init event names an API key source other than none.
printf 'nothing\nnothing\nnothing\nnothing\nnothing\nnothing\nnothing\nnothing\nnothing\nnothing\napikey\n' > "$CS/fk10/script"
got="$(cd "$CSR" && CLAUDE_FAKE_DIR="$CS/fk10" CLAUDE_FAKE_SNAPSHOT='' "$CLAUDE_BIN" -p x --plugin-dir /p </dev/null 2>/dev/null | head -1 | jq -c '[.apiKeySource, .plugins[0].path]' 2>/dev/null)"
expect_eq "$got" '["ANTHROPIC_API_KEY","/p"]' "fakes: apikey -> init with apiKeySource ANTHROPIC_API_KEY, guard listed"
# gh
HEAD1="$(jq -r '.[0].headRefOid' "$CS/gh/prs.json")"
gh pr merge 1 >/dev/null 2>&1; expect_eq "$?" 1 "fakes: flagless gh pr merge -> exit 1"
expect_eq "$(wc -l < "$CS/gh/unknown.log" 2>/dev/null | tr -d ' ')" 1 "fakes: flagless merge lands in unknown.log"
expect_eq "$(jq -r '.[0].state' "$CS/gh/prs.json" 2>/dev/null)" OPEN "fakes: flagless merge leaves the pull request OPEN"
gh pr checks 1 >/dev/null 2>&1; expect_eq "$?" 1 "fakes: flagless gh pr checks -> exit 1"
gh pr list >/dev/null 2>&1; expect_eq "$?" 1 "fakes: flagless gh pr list -> exit 1"
gh pr merge 1 --squash --match-head-commit 0000000000000000000000000000000000000000 >/dev/null 2>&1; expect_eq "$?" 1 "fakes: merge with a wrong head -> exit 1"
expect_eq "$(jq -r '.[0].state' "$CS/gh/prs.json")" OPEN "fakes: wrong-head merge leaves the pull request OPEN"
gh pr merge 1 --squash --match-head-commit "$HEAD1" >/dev/null 2>&1; expect_eq "$?" 0 "fakes: merge with the head -> exit 0"
git -C "$CSO" cat-file -e "main:$HOUT" 2>/dev/null && ok || nope "fakes: origin/main has HANDOFF_OUT after the merge"
expect_eq "$(jq -r '.[0].state' "$CS/gh/prs.json")" MERGED "fakes: merged pull request state"
gh pr edit 1 >/dev/null 2>&1; expect_eq "$?" 1 "fakes: unknown gh call -> exit 1"
expect_eq "$(wc -l < "$CS/gh/unknown.log" | tr -d ' ')" 4 "fakes: unknown.log has one line per unknown call (3 flagless + edit)"
expect_eq "$(gh api repos/x/y/rules/branches/main | jq -c 'map(.type) | sort' 2>/dev/null)" '["pull_request","required_status_checks"]' "fakes: default rules"
gh api repos/x/y/branches/main/protection >/dev/null 2>&1; expect_eq "$?" 1 "fakes: no branch protection -> exit 1"
expect_eq "$(gh api repos/x/y/rulesets/1 | jq -c . 2>/dev/null)" '{"current_user_can_bypass":"never"}' "fakes: default ruleset"
expect_eq "$(gh pr list --state all --search "head:conduct/p/" --limit 200 --json number,headRefName,state,files,headRefOid | jq -c '[.[] | keys]' 2>/dev/null)" '[["files","headRefName","headRefOid","number","state"]]' "fakes: pr list fields"
expect_eq "$(gh pr checks 1 --required --json name,bucket | jq -c . 2>/dev/null)" '[{"name":"ci","bucket":"pass"}]' "fakes: default checks"
# the gate helper
mkdir -p "$CSR/.agent-farm/state"; cs_open_gate; echo 123 > "$CSR/.agent-farm/state/limit-until"
for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -f "$CS/gate.seen" ]] && break; sleep 0.5; done
expect_eq "$(cat "$CS/gate.seen" 2>/dev/null)" 123 "fakes: cs_open_gate copies the gate file"
[[ -f "$CSR/.agent-farm/state/limit-until" ]] && nope "fakes: cs_open_gate removes the gate file" || ok

# ---- preflight: deciders, the lock, the origin pin and conduct_preflight (section "preflight") ----
ev() { printf '%s\n' "$1" | run_fn conduct_env_value FARM_VERIFY_CMD; }
expect_eq "$(ev 'FARM_VERIFY_CMD="make check"')" "make check
rc=0" "preflight: env value in double quotes"
expect_eq "$(ev "FARM_VERIFY_CMD='x y'")" "x y
rc=0" "preflight: env value in single quotes"
expect_eq "$(ev 'export FARM_VERIFY_CMD=./v.sh')" "./v.sh
rc=0" "preflight: env value after export"
expect_eq "$(ev '# FARM_VERIFY_CMD=x')" "rc=0" "preflight: commented env value -> empty"
expect_eq "$(ev 'FARM_VERIFY_CMD=""')" "rc=0" "preflight: empty env value"
expect_eq "$(ev "$(printf 'FARM_VERIFY_CMD=a\nOTHER=z\nFARM_VERIFY_CMD=b')")" "b
rc=0" "preflight: two assignments -> the last"
mkdir -p "$TROOT/pw"
# shellcheck disable=SC2016  # the literal text is the point
got="$(cd "$TROOT/pw" && ev 'FARM_VERIFY_CMD=$(touch PWNED)')"
# shellcheck disable=SC2016
expect_eq "$got" '$(touch PWNED)
rc=0' "preflight: env value is not evaluated"
[[ ! -e "$TROOT/pw/PWNED" ]] && ok || nope "preflight: env value: no file PWNED"

BR_FULL='[{"type":"pull_request","ruleset_id":1,"parameters":{}},{"type":"required_status_checks","ruleset_id":1,"parameters":{"required_status_checks":[{"context":"ci"}]}}]'
BR_CHK='[{"type":"required_status_checks","ruleset_id":1,"parameters":{"required_status_checks":[{"context":"ci"}]}}]'
BR_PR='[{"type":"pull_request","ruleset_id":1,"parameters":{}}]'
BR_NOCTX='[{"type":"pull_request","ruleset_id":1},{"type":"required_status_checks","ruleset_id":1,"parameters":{"required_status_checks":[]}}]'
BP_T='{"required_pull_request_reviews":{},"required_status_checks":{"contexts":["ci"]},"enforce_admins":{"enabled":true}}'
BP_F='{"required_pull_request_reviews":{},"required_status_checks":{"contexts":["ci"]},"enforce_admins":{"enabled":false}}'
BP_N='{"required_pull_request_reviews":{},"required_status_checks":{"contexts":["ci"]}}'
br() { run_fn conduct_branch_rules_decide "$@" </dev/null; }
expect_eq "$(br "$BR_FULL" '' never)" "ok
rc=0" "preflight: rules with pull_request and required checks -> ok"
expect_eq "$(br "$BR_CHK" '' never)" "no-pull-request-rule
rc=0" "preflight: rules with only required checks"
expect_eq "$(br "$BR_PR" '' never)" "no-required-check
rc=0" "preflight: rules with only pull_request"
expect_eq "$(br "$BR_NOCTX" '' never)" "no-required-check
rc=0" "preflight: required_status_checks rule without a context"
expect_eq "$(br '[]' '' never)" "no-pull-request-rule
rc=0" "preflight: no rules"
expect_eq "$(br '' '' never)" "undetermined
rc=0" "preflight: neither call answered"
expect_eq "$(br 'not json' 'not json' never)" "undetermined
rc=0" "preflight: neither answer is JSON"
expect_eq "$(br "$BR_FULL" '' possible)" "admin-bypass
rc=0" "preflight: full rules, bypass possible"
expect_eq "$(br "$BR_FULL" '' unknown)" "undetermined
rc=0" "preflight: full rules, bypass unknown"
expect_eq "$(br '' "$BP_T" never)" "ok
rc=0" "preflight: classic protection enforced for admins -> ok"
expect_eq "$(br '' "$BP_F" never)" "admin-bypass
rc=0" "preflight: classic protection, enforce_admins false"
expect_eq "$(br '' "$BP_N" never)" "admin-bypass
rc=0" "preflight: classic protection, enforce_admins absent"

for c in '0 5 60=pass' '1 5 60=fail' '124 3 60=timeout' '143 61 60=timeout' '137 60 60=timeout' '143 5 60=fail' 'x 5 60=fail'; do
  # shellcheck disable=SC2086  # the three arguments are word-split on purpose
  expect_eq "$(run_fn conduct_verify_decide ${c%%=*} </dev/null)" "${c#*=}
rc=0" "preflight: conduct_verify_decide ${c%%=*}"
done

for c in '1 1 ok 1 ok 1 1 2 0=ok' '0 1 ok 1 ok 1 1 2 0=refuse:lint' '1 0 ok 1 ok 1 1 2 0=refuse:dependency-not-shipped' \
         '1 1 blocked 1 ok 1 1 2 0=refuse:entry-criteria-blocked' '1 1 invalid 1 ok 1 1 2 0=refuse:entry-criteria-invalid' \
         '1 1 none 1 ok 1 1 2 0=refuse:entry-criteria-invalid' '1 1 ok 0 ok 1 1 2 0=refuse:verify-cmd-unset' \
         '1 1 ok 1 undetermined 1 1 2 0=refuse:branch-rules-undetermined' '1 1 ok 1 bogus 1 1 2 0=refuse:branch-rules-undetermined' \
         '1 1 ok 1 no-pull-request-rule 1 1 2 0=refuse:no-pull-request-rule' '1 1 ok 1 no-required-check 1 1 2 0=refuse:no-required-check' \
         '1 1 ok 1 admin-bypass 1 1 2 0=refuse:admin-bypass' '1 1 ok 1 ok 0 1 2 0=refuse:main-branch-mismatch' \
         '1 1 ok 1 ok 1 0 2 0=refuse:conductor-active' '1 1 ok 1 ok 1 1 0 0=refuse:guard-self-test' \
         '1 1 ok 1 ok 1 1 x 0=refuse:guard-self-test' '1 1 ok 1 ok 1 1 2 1=refuse:session-alive' \
         '0 0 blocked 0 admin-bypass 0 0 0 1=refuse:lint' '1 1 ok 1 ok 1 0 0 1=refuse:conductor-active'; do
  # shellcheck disable=SC2086  # the nine arguments are word-split on purpose
  expect_eq "$(run_fn conduct_preflight_decide ${c%%=*} </dev/null)" "${c#*=}
rc=0" "preflight: conduct_preflight_decide ${c%%=*}"
done

od() { run_fn conduct_origin_decide "$@" </dev/null; }
expect_eq "$(od /o.git /o.git /o.git '')" "ok
rc=0" "preflight: origin unchanged, no pin"
expect_eq "$(od /o.git /o.git /o.git /o.git)" "ok
rc=0" "preflight: origin matches the pin"
expect_eq "$(od /o.git /x.git /o.git '')" "origin-rewritten
rc=0" "preflight: insteadOf rewrites the fetch url"
expect_eq "$(od /o.git /o.git /x.git '')" "origin-rewritten
rc=0" "preflight: pushInsteadOf or pushurl rewrites the push url"
expect_eq "$(od '' '' '' '')" "origin-rewritten
rc=0" "preflight: no configured origin url"
expect_eq "$(od /o.git /o.git /o.git /p.git)" "origin-changed
rc=0" "preflight: origin differs from the pin"
# Security review M3a F1/F2: local and worktree git config keys on an allowlist; global and system are the operator's.
gcd() { printf '%b' "$1" | run_fn conduct_git_config_decide; }
expect_eq "$(gcd 'local\tcore.repositoryformatversion\nlocal\tcore.bare\nlocal\tremote.origin.url\nlocal\tremote.origin.fetch\nlocal\tbranch.Feat.x.merge\nworktree\tuser.email\nglobal\tcore.sshcommand\nsystem\tfilter.lfs.smudge\n')" "ok
rc=0" "git config: allowlisted local keys, foreign global/system keys -> ok"
expect_eq "$(gcd 'local\tcore.bare\nlocal\tremote.origin.uploadpack\nlocal\tcore.fsmonitor\n')" "git-local-config:remote.origin.uploadpack
rc=0" "git config: local remote.origin.uploadpack -> the first bad key"
expect_eq "$(gcd 'worktree\tCore.SSHCommand\n')" "git-local-config:core.sshcommand
rc=0" "git config: worktree core.sshCommand, case-insensitive"
expect_eq "$(gcd 'local\tremote.upstream.url\n')" "git-local-config:remote.upstream.url
rc=0" "git config: a remote other than origin -> refused"
expect_eq "$(gcd 'local\tinclude.path\n')" "git-local-config:include.path
rc=0" "git config: include.path -> refused"

# farm-conduct.sh functions, sourced in a subshell up to the CONDUCT_DEFINE_ONLY seam
# (FARM_REPO_DIR from cs_setup above). Output, then "rc=N"; rc 9 without the function.
fcs() {
  (export CONDUCT_DEFINE_ONLY=1; source "$FARM/bin/farm-conduct.sh" >/dev/null 2>&1 || exit 9
   declare -F "$1" >/dev/null || exit 9; "$@") </dev/null; echo "rc=$?"
}
LK="$TROOT/lk/lock"; mkdir -p "$TROOT/lk"
expect_eq "$(fcs conduct_lock "$LK") $(fcs conduct_lock "$LK")" "rc=0 rc=1" "preflight: lock, then again -> rc 0, rc 1"
expect_eq "$(cat "$LK/pid" 2>/dev/null)" "$$" "preflight: lock pid file names the holder"
expect_eq "$(fcs conduct_unlock "$LK") $(fcs conduct_lock "$LK")" "rc=0 rc=0" "preflight: unlock, lock -> rc 0"
sh -c 'exit 0' & dpid=$!; wait "$dpid"
echo "$dpid" > "$LK/pid"
expect_eq "$(fcs conduct_lock "$LK")" "rc=0" "preflight: lock held by a finished pid is taken over"
# shellcheck disable=SC2016  # the literal text is the point
printf '%s\n' 'HOME[$(touch PWNED)]' > "$LK/pid"
expect_eq "$(cd "$TROOT/lk" && fcs conduct_lock "$LK")" "rc=0" "preflight: lock with a non-integer pid is taken over"
[[ ! -e "$TROOT/lk/PWNED" ]] && ok || nope "preflight: lock pid file is not evaluated"
fcs conduct_unlock "$LK" >/dev/null

# <description> <function>: cs_setup and the function in one subshell; its ok/nope are tallied here.
scenario() {
  local out l
  out="$(ok() { echo "@@ok"; }; nope() { echo "@@FAIL [$1]"; }
         cs_setup >/dev/null 2>&1 || nope "$1: cs_setup"; "$2" </dev/null 2>&1; echo "@@end")"
  while IFS= read -r l; do
    case "$l" in "@@ok") ok ;; "@@FAIL ["*) l="${l#@@FAIL [}"; nope "${l%]}" ;; esac
  done <<<"$out"
  case "$out" in *"@@end"*) ok ;; *) nope "$1: scenario did not finish" ;; esac
}
# <unit>: setup + conduct_preflight on $PP, from /; output, then "rc=N".
pf() {
  (cd / && export CONDUCT_DEFINE_ONLY=1 && source "$FARM/bin/farm-conduct.sh" || exit 9
   declare -F conduct_preflight >/dev/null || exit 9
   setup "$PP"
   conduct_preflight "$PP" "$1") </dev/null 2>&1; echo "rc=$?"
}
push_exec() { # <work tree> <path> <content>: like push_file, executable
  printf '%s\n' "$3" > "$1/$2"; chmod +x "$1/$2"
  gitq -C "$1" add -- "$2" && gitq -C "$1" commit -qm "add $2" && git -C "$1" push -q origin main 2>/dev/null
}
# <got> <code> <description>: exit 1 naming the code, the lock released, no notification.
refused() {
  case "$1" in *"$2"*"rc=1") ok ;; *) nope "$3: exit 1 naming $2: got=[$1]" ;; esac
  [[ ! -e "$CDIR/lock" ]] && ok || nope "$3: lock released"
  [[ ! -s "$CS/notify.log" ]] && ok || nope "$3: notify.log empty"
}
no_claude() { [[ ! -e "$CS/claude/argv.1" ]] && ok || nope "$1: no claude invocation"; }

# [smoke] unit 1, verify passes
sc_pass() {
  push_exec "$CSR" verify.sh "$(printf '#!/bin/sh\npwd > "%s/verify.cwd"' "$CS")"
  local got wt; got="$(pf M1)"
  expect_eq "${got##*rc=}" 0 "preflight: unit 1, verify passes -> exit 0 [$got]"
  expect_eq "$(jq -sc '[length, .[0].role, .[0].phase, .[0].outcome, .[0].exit_code, .[0].plan, .[0].unit, (.[0].wall_s | type), (.[0].ts | type)]' "$CDIR/usage.jsonl" 2>/dev/null)" \
    "[1,\"verify\",\"preflight\",\"pass\",0,\"$PP\",\"M1\",\"number\",\"string\"]" "preflight: one usage line, role verify, outcome pass"
  wt="$(cat "$CS/verify.cwd" 2>/dev/null)"
  case "$wt" in "$CSR/.farm-worktrees/"*verify*) ok ;; *) nope "preflight: verify ran in a .farm-worktrees verify tree: [$wt]" ;; esac
  [[ -n "$wt" && ! -e "$wt" ]] && ok || nope "preflight: the verify work tree is gone"
  git -C "$CSR" worktree list | grep -F -- "$CSR/.farm-worktrees/" >/dev/null && nope "preflight: verify work tree pruned" || ok
  expect_eq "$(cat "$CDIR/lock/pid" 2>/dev/null | grep -c '^[0-9][0-9]*$')" 1 "preflight: lock held after success"
  expect_eq "$(cat "$CDIR/origin_url" 2>/dev/null)" "$CSO" "preflight: origin url pinned"
  local rk; rk="$(printf '%s' "$(cd "$CSR" && pwd -P)" | cksum | awk '{ print $1 }')"
  expect_eq "$(cat "$CS/xdg/agent-farm/repos/$rk/origin_url" 2>/dev/null)" "$CSO" "preflight: origin url pinned per repository directory"
  ls "$CDIR/logs/conduct-m1-verify-"*.log >/dev/null 2>&1 && ok || nope "preflight: verify log in CDIR/logs"
  [[ ! -s "$CS/notify.log" ]] && ok || nope "preflight: success sends no notification"
}
scenario "preflight: verify passes" sc_pass
# [smoke] verify fails on origin/main
sc_boom() {
  push_exec "$CSR" verify.sh "$(printf '#!/bin/sh\necho BOOM\nexit 1')"
  local got; got="$(pf M1)"
  refused "$got" verify-failed "preflight: verify fails"
  case "$got" in *BOOM*) ok ;; *) nope "preflight: verify fails -> output has BOOM: [$got]" ;; esac
  expect_eq "$(jq -sc '[length, .[0].outcome, .[0].exit_code]' "$CDIR/usage.jsonl" 2>/dev/null)" '[1,"fail",1]' "preflight: verify fails -> usage outcome fail"
  no_claude "preflight: verify fails"
}
scenario "preflight: verify fails" sc_boom

if is_full; then
  sc_timeout() {
    export CONDUCT_VERIFY_TIMEOUT_SECONDS=1
    push_exec "$CSR" verify.sh "$(printf '#!/bin/sh\nsleep 300')"
    local got t0 dt; t0=$SECONDS; got="$(pf M1)"; dt=$((SECONDS - t0))
    refused "$got" verify-timeout "preflight: verify hangs"
    [[ "$dt" -lt 120 ]] && ok || nope "preflight: verify hang bounded under 120s: took ${dt}s"
    expect_eq "$(jq -sc '[length, .[0].outcome]' "$CDIR/usage.jsonl" 2>/dev/null)" '[1,"timeout"]' "preflight: verify hangs -> usage outcome timeout"
  }
  scenario "preflight: verify hangs" sc_timeout
  sc_noverify() {
    push_file "$CSR" .agent-farm/farm.env 'OTHER=1'
    printf 'FARM_VERIFY_CMD=./verify.sh\n' > "$CSR/.agent-farm/farm.env"
    local got; got="$(pf M1)"
    refused "$got" verify-cmd-unset "preflight: farm.env on origin/main lacks FARM_VERIFY_CMD"
    [[ ! -e "$CDIR/usage.jsonl" ]] && ok || nope "preflight: verify-cmd-unset -> nothing ran"
  }
  scenario "preflight: verify-cmd-unset" sc_noverify
  sc_local_copy() {
    printf '#!/bin/sh\nexit 1\n' > "$CSR/verify.sh"
    local got; got="$(pf M1)"
    expect_eq "${got##*rc=}" 0 "preflight: origin/main verify.sh runs, not the uncommitted copy [$got]"
  }
  scenario "preflight: uncommitted verify.sh" sc_local_copy
  sc_rules_empty() {
    echo '[]' > "$CS/gh/rules.json"
    refused "$(pf M1)" no-pull-request-rule "preflight: rules []"
  }
  scenario "preflight: rules []" sc_rules_empty
  sc_rules_pr() {
    echo '[{"type":"pull_request","ruleset_id":1,"parameters":{}}]' > "$CS/gh/rules.json"
    refused "$(pf M1)" no-required-check "preflight: only a pull_request rule"
  }
  scenario "preflight: only a pull_request rule" sc_rules_pr
  sc_bypass() {
    echo '{"current_user_can_bypass":"always"}' > "$CS/gh/ruleset.json"
    refused "$(pf M1)" admin-bypass "preflight: ruleset bypass always"
  }
  scenario "preflight: ruleset bypass always" sc_bypass
  sc_api_down() {
    printf '#!/bin/sh\ncase "$1" in api) exit 1 ;; esac\nexec "%s/gh" "$@"\n' "$STUBS" > "$CS/bin/gh"
    refused "$(pf M1)" branch-rules-undetermined "preflight: both API calls fail"
  }
  scenario "preflight: both API calls fail" sc_api_down
  sc_trunk() {
    git -C "$CSR" push -q origin main:trunk 2>/dev/null && git -C "$CSO" symbolic-ref HEAD refs/heads/trunk
    git -C "$CSR" fetch -q origin && git -C "$CSR" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
    refused "$(pf M1)" main-branch-mismatch "preflight: origin HEAD trunk, local origin/HEAD main"
  }
  scenario "preflight: main branch mismatch" sc_trunk
  sc_locked() {
    local lp got; sleep 300 & lp=$!
    mkdir -p "$CDIR/lock"; echo "$lp" > "$CDIR/lock/pid"
    got="$(pf M1)"
    case "$got" in *conductor-active*"rc=1") ok ;; *) nope "preflight: lock held by a live pid -> conductor-active: [$got]" ;; esac
    expect_eq "$(cat "$CDIR/lock/pid" 2>/dev/null)" "$lp" "preflight: another conductor's lock is left alone"
    [[ ! -s "$CS/notify.log" ]] && ok || nope "preflight: conductor-active -> notify.log empty"
    kill "$lp" 2>/dev/null
  }
  scenario "preflight: conductor active" sc_locked
  sc_alive() {
    local sp; sleep 300 & sp=$!
    echo "$sp" > "$CSU/pid"
    refused "$(pf M1)" session-alive "preflight: unit pid alive"
    no_claude "preflight: session-alive"
    kill "$sp" 2>/dev/null
  }
  scenario "preflight: session alive" sc_alive
  sc_dep_unreviewed() {
    push_file "$CSR" docs/superpowers/handoffs/p-m1-handoff.md "$HO"
    refused "$(pf M2)" dependency-not-shipped "preflight: unit 2, unit 1 shipped-unreviewed"
  }
  scenario "preflight: dependency not shipped" sc_dep_unreviewed
  sc_dep_blocked() {
    push_file "$CSR" docs/superpowers/handoffs/p-m1-handoff.md "$NOTMET"
    printf '{"plan":"%s","unit":"M1"}\n' "$PP" > "$CDIR/reviews.jsonl"
    refused "$(pf M2)" entry-criteria-blocked "preflight: unit 2, a not met row"
  }
  scenario "preflight: entry criteria blocked" sc_dep_blocked
  sc_long_wait() {
    export CONDUCT_LONG_WAIT=0
    local got; got="$(pf M1)"
    expect_eq "${got##*rc=}" 0 "preflight: CONDUCT_LONG_WAIT=0 -> same exit code"
    case "$got" in *"not eligible"*) ok ;; *) nope "preflight: CONDUCT_LONG_WAIT=0 -> not-eligible line: [$got]" ;; esac
  }
  scenario "preflight: CONDUCT_LONG_WAIT=0" sc_long_wait
  # Security review M3a F5: the verify command runs without the operator's API credentials.
  sc_verify_env() {
    export ANTHROPIC_API_KEY=not-a-key ANTHROPIC_AUTH_TOKEN=not-a-token
    push_exec "$CSR" verify.sh "$(printf '#!/bin/sh\nenv > "%s/verify.env"' "$CS")"
    local got; got="$(pf M1)"
    expect_eq "${got##*rc=}" 0 "preflight: verify env -> exit 0 [$got]"
    [[ -s "$CS/verify.env" ]] && ! grep -E '^ANTHROPIC_(API_KEY|AUTH_TOKEN)=' "$CS/verify.env" >/dev/null && ok \
      || nope "preflight: the verify run has no ANTHROPIC_API_KEY or ANTHROPIC_AUTH_TOKEN"
  }
  scenario "preflight: verify environment" sc_verify_env

  # PD17 local .git state: refs/replace, insteadOf, a changed origin url.
  RP="$(mk_conduct_repo)"; tip="$(git -C "$RP" rev-parse HEAD)"
  gitq -C "$RP" checkout -q -b forge
  mkdir -p "$RP/docs/superpowers/handoffs" && printf '%s\n' "$HO" > "$RP/$GH"
  gitq -C "$RP" add -- "$GH" && gitq -C "$RP" commit -qm forged && gitq -C "$RP" checkout -q main
  git -C "$RP" replace "$tip" "$(git -C "$RP" rev-parse forge)"
  got="$(fc "$RP" status "$PP" --json)"
  expect_eq "$(rows_of "$got" | jq -r '[.[] | .status] | join(",")' 2>/dev/null)${got##*rc=}" "ready,backlog0" "preflight: refs/replace of origin's tip ignored"
  OR="$(mk_conduct_repo)"; ORO="$(dirname "$OR")/origin.git"
  git -C "$OR" config "url.$TROOT/elsewhere.git.insteadOf" "$ORO"
  got="$(fc "$OR" status "$PP")"
  case "$got" in *origin-rewritten*"rc=2") ok ;; *) nope "preflight: insteadOf on origin -> exit 2 origin-rewritten: got=[$got]" ;; esac
  git -C "$OR" config --unset "url.$TROOT/elsewhere.git.insteadOf"
  push_file "$OR" docs/superpowers/handoffs/p-m1-handoff.md "$HO"
  got="$(fc "$OR" adopt "$PP" M1 "$GH")"
  expect_eq "${got##*rc=}$(cat "$(cdir_of "$OR")/origin_url" 2>/dev/null)" "0$ORO" "preflight: adopt pins the origin url"
  # Same owner/repo path (so the same conductor dir and pin), another location.
  OTHER="$TROOT/evil/$(basename "$(dirname "$OR")")/origin.git"; git clone -q --bare "$ORO" "$OTHER" 2>/dev/null
  git -C "$OR" remote set-url origin "$OTHER"
  got="$(fc "$OR" status "$PP")"
  case "$got" in *origin-changed*origin_url*"rc=2") ok ;; *) nope "preflight: origin url changed after the pin -> exit 2 origin-changed naming the pin: got=[$got]" ;; esac
  NP="$(mk_conduct_repo)"; NPO="$TROOT/evil2/np/origin.git"
  git clone -q --bare "$(dirname "$NP")/origin.git" "$NPO" 2>/dev/null && git -C "$NP" remote set-url origin "$NPO"
  got="$(fc "$NP" status "$PP")"
  expect_eq "${got##*rc=}" 0 "preflight: changed origin url without a pin -> exit 0"
  # Security review M3a F3: the pin is also kept per repository directory, so a set-url to
  # another owner/repo (a new conductor dir without a pin) is still origin-changed.
  EVR="$TROOT/evil3/other/evilrepo.git"; git clone -q --bare "$ORO" "$EVR" 2>/dev/null
  git -C "$OR" remote set-url origin "$EVR"
  got="$(fc "$OR" status "$PP")"
  case "$got" in *origin-changed*"rc=2") ok ;; *) nope "preflight: set-url to another owner/repo after the pin -> exit 2 origin-changed: got=[$got]" ;; esac
  [[ ! -e "$XS/agent-farm/other__evilrepo/conduct/origin_url" ]] && ok || nope "preflight: the other owner/repo gets no pin"

  # Security review M3a F1/F2: repo-local git config off the allowlist and a non-empty
  # info/attributes -> exit 2 naming the code, before any fetch; repository hooks never run.
  LC="$(mk_conduct_repo)"; LCX="$TROOT/lcx.sh"
  printf '#!/bin/sh\n: > "%s/lc-ran"\nexec git-upload-pack "$@"\n' "$TROOT" > "$LCX"; chmod +x "$LCX"
  lc() { # <description> <code> <key> <value>: set the key, expect exit 2 naming the code, unset it
    git -C "$LC" config "$3" "$4"
    got="$(fc "$LC" status "$PP")"
    case "$got" in *"$2"*"rc=2") ok ;; *) nope "git config: $1 -> exit 2 $2: got=[$got]" ;; esac
    git -C "$LC" config --unset "$3"
  }
  lc uploadpack git-local-config:remote.origin.uploadpack remote.origin.uploadpack "$LCX"
  [[ ! -e "$TROOT/lc-ran" ]] && ok || nope "git config: the uploadpack program never ran"
  lc sshCommand git-local-config:core.sshcommand core.sshCommand "$LCX"
  lc fsmonitor git-local-config:core.fsmonitor core.fsmonitor "$LCX"
  lc filter git-local-config:filter.x.smudge filter.x.smudge "$LCX"
  lc unknown git-local-config:foo.bar foo.bar 1
  mkdir -p "$LC/.git/info"; printf '* filter=x\n' > "$LC/.git/info/attributes"
  got="$(fc "$LC" status "$PP")"
  case "$got" in *git-info-attributes*"rc=2") ok ;; *) nope "git config: info/attributes non-empty -> exit 2 git-info-attributes: got=[$got]" ;; esac
  : > "$LC/.git/info/attributes"
  # A reference-transaction hook would run on the fetch's ref update.
  C3="$TROOT/c3"; git clone -q "$(dirname "$LC")/origin.git" "$C3" 2>/dev/null
  gitq -C "$C3" commit -q --allow-empty -m newer && git -C "$C3" push -q origin main 2>/dev/null
  printf '#!/bin/sh\n: > "%s/rt-ran"\n' "$TROOT" > "$LC/.git/hooks/reference-transaction"; chmod +x "$LC/.git/hooks/reference-transaction"
  got="$(fc "$LC" status "$PP")"
  expect_eq "${got##*rc=}" 0 "git config: clean config, empty info/attributes -> exit 0"
  [[ "$(git -C "$LC" rev-parse refs/remotes/origin/main)" == "$(git -C "$C3" rev-parse HEAD)" ]] && ok || nope "git config: the fetch ran"
  [[ ! -e "$TROOT/rt-ran" ]] && ok || nope "git config: the reference-transaction hook did not run during the fetch"
fi
# [smoke] a repo-local core.sshCommand -> exit 2 (BSD/macOS run of the allowlist)
LS="$(mk_conduct_repo)"; git -C "$LS" config core.sshCommand /bin/false
got="$(fc "$LS" lint "$PP")"
case "$got" in *git-local-config:core.sshcommand*"rc=2") ok ;; *) nope "git config: smoke core.sshCommand -> exit 2: got=[$got]" ;; esac

# ---- counters: conduct_next_decide, conduct_launch_mode, conduct_counter_bump (section "counters") ----
for c in "handoff 0 0 0=review -" "merged 0 0 0=done -" \
  "limit 0 0 0=resume interruption" "transient 0 0 2=resume interruption" "restart 0 0 3=stop cap-interruption" \
  "progress 0 0 0=continue continuation" "progress 0 1 0=continue continuation" "progress 0 2 0=stop cap-continuation" \
  "no-progress 0 0 0=rework rework" "review-reject 0 0 0=rework rework" "handoff-invalid 0 0 0=rework rework" \
  "review-reject 1 0 0=stop cap-rework" "no-progress 1 2 3=stop cap-rework" \
  "awaiting-merge 0 0 0=wait awaiting-operator-merge" "awaiting-merge 1 2 3=wait awaiting-operator-merge" \
  "review-noverdict 0 0 0=stop review-no-verdict" "guard-not-loaded 0 0 0=stop guard-not-loaded" \
  "shipped-unreviewed 0 0 0=stop shipped-unreviewed" "merge-failed 0 0 0=stop handoff-merge-failed" \
  "checks-timeout 0 0 0=stop required-checks-not-reported" "bogus 0 0 0=stop invalid-state" \
  "settings-tampered 0 0 0=stop settings-tampered" \
  "limit x 0 0=stop invalid-state"; do
  # shellcheck disable=SC2086  # the outcome and counters are word-split on purpose
  expect_eq "$(run_fn conduct_next_decide ${c%%=*} </dev/null)" "${c#*=}
rc=0" "next: ${c%%=*}"
done
expect_eq "$(run_fn conduct_next_decide limit 0 0 '' </dev/null)" "stop invalid-state
rc=0" "next: limit 0 0 '' (empty counter)"
# Pilot finding 3: a guard-forced stop is a stop, never a rework, whatever the counters say.
for c in "guard-blocked 0 0 0" "guard-blocked 1 2 3"; do
  # shellcheck disable=SC2086  # the outcome and counters are word-split on purpose
  expect_eq "$(run_fn conduct_next_decide $c </dev/null)" "stop guard-blocked
rc=0" "next: $c"
done
SID=00000000-0000-0000-0000-000000000001
expect_eq "$(run_fn conduct_launch_mode resume 1 "$SID" </dev/null)" "resume
rc=0" "next: launch mode resume, enabled, valid id -> resume"
expect_eq "$(run_fn conduct_launch_mode resume 0 "$SID" </dev/null)" "fresh
rc=0" "next: launch mode resume, disabled -> fresh"
expect_eq "$(run_fn conduct_launch_mode resume 1 '' </dev/null)" "fresh
rc=0" "next: launch mode resume, no id -> fresh"
expect_eq "$(run_fn conduct_launch_mode resume 1 '--model x' </dev/null)" "fresh
rc=0" "next: launch mode resume, id '--model x' -> fresh"
expect_eq "$(run_fn conduct_launch_mode continue 1 "$SID" </dev/null)" "fresh
rc=0" "next: launch mode continue -> fresh"
# conduct_counter_bump (farm-conduct.sh wrapper), each scenario in its own fcs subshell
mkdir -p "$TROOT/ctr/a" "$TROOT/ctr/b"
# shellcheck disable=SC2016  # the literal text is the point
printf '%s\n' 'HOME[$(touch PWNED)]' > "$TROOT/ctr/a/rework"
got="$(cd "$TROOT/ctr/a" && fcs conduct_counter_bump "$TROOT/ctr/a" rework)"
# shellcheck disable=SC2016  # the literal text is the point
expect_eq "$got $(cat "$TROOT/ctr/a/rework")" 'rc=1 HOME[$(touch PWNED)]' "next: counter bump on a non-integer file -> rc 1, file unchanged"
[[ "$got" == rc=1 && ! -e "$TROOT/ctr/a/PWNED" && ! -e "$TROOT/ctr/PWNED" ]] && ok || nope "next: counter file is not evaluated"
expect_eq "$(fcs conduct_counter_bump "$TROOT/ctr/b" continuation) $(fcs conduct_counter_bump "$TROOT/ctr/b" continuation)" "rc=0 rc=0" "next: counter bump twice on an absent file -> rc 0, rc 0"
expect_eq "$(cat "$TROOT/ctr/b/continuation" 2>/dev/null)" 2 "next: counter bump twice on an absent file -> 2"
expect_eq "$(find "$TROOT/ctr/b" -type f | wc -l | tr -d ' ')" 1 "next: counter bump leaves no temp file"
expect_eq "$(fcs conduct_counter_bump "$TROOT/ctr/b" attempts) $(cat "$TROOT/ctr/b/attempts" 2>/dev/null)" "rc=0 1" "next: counter bump accepts attempts"

# ---- lead session: gate keep, conduct_run_lead, conduct_wait_gate, conduct_notify (section "lead") ----
gk() { run_fn conduct_gate_keep_decide "$@" </dev/null; }
expect_eq "$(gk '' 2000 1000)" "2000
rc=0" "lead: gate keep '' 2000 1000"
expect_eq "$(gk 3000 2000 1000)" "3000
rc=0" "lead: gate keep, a longer existing gate is kept"
expect_eq "$(gk 1500 2000 1000)" "2000
rc=0" "lead: gate keep 1500 2000 1000"
expect_eq "$(gk 900 2000 1000)" "2000
rc=0" "lead: gate keep, an expired gate is not kept"
mkdir -p "$TROOT/gk"
# shellcheck disable=SC2016  # the literal text is the point
got="$(cd "$TROOT/gk" && gk 'HOME[$(touch PWNED)]' 2000 1000)"
expect_eq "$got" "2000
rc=0" "lead: gate keep, a non-integer before is absent"
[[ ! -e "$TROOT/gk/PWNED" ]] && ok || nope "lead: gate keep does not evaluate its input"
expect_eq "$(gk $((1000+8*86400)) 2000 1000)" "692200
rc=0" "lead: gate keep, exactly eight days ahead is kept"
expect_eq "$(gk $((1000+8*86400+1)) 2000 1000)" "2000
rc=0" "lead: gate keep, more than eight days ahead is not kept"

UM="$FARM/defaults/prompts/unit.md"
for ph in "never bypass" "required check" "edit a test" "credentials" "money" "not eligible" "do not open the handoff pull request" \
  "reads every \`not met\` row as blocking" "never as an entry-criteria row" \
  "## Verification evidence" "## Lessons learned" "## Operator actions pending"; do
  grep -F -- "$ph" "$UM" >/dev/null 2>&1 && ok || nope "lead: unit.md contains '$ph'"
done
[[ -f "$UM" && "$(wc -l < "$UM" | tr -d ' ')" -le 70 ]] && ok || nope "lead: unit.md exists, at most 70 lines"
# Pilot step one repeat, token candidate 2 and finding 4: fewer lead turns, squash merges.
for ph in "One git action per Bash command" "git push -u origin <branch>" \
  "once after your change and once before you open a pull request" "gh pr merge <n> --squash"; do
  grep -F -- "$ph" "$UM" >/dev/null 2>&1 && ok || nope "lead: unit.md contains '$ph'"
done

GATE_REL=.agent-farm/state/limit-until
WT1=".farm-worktrees/conduct-p-m1"
# <mode>: conduct_run_lead $PP M1 <mode> from /; stdout (the outcome), then "rc=N"; rc 9 without the function.
rl() {
  (cd / && export CONDUCT_DEFINE_ONLY=1 && source "$FARM/bin/farm-conduct.sh" >/dev/null 2>&1 || exit 9
   declare -F conduct_run_lead >/dev/null || exit 9
   conduct_run_lead "$PP" M1 "$1") </dev/null 2>>"$CS/lead.err"; echo "rc=$?"
}
# Two launches: start, then through conduct_next_decide (bumping its counter) a resume.
rl_twice() {
  (cd / && export CONDUCT_DEFINE_ONLY=1 && source "$FARM/bin/farm-conduct.sh" >/dev/null 2>&1 || exit 9
   declare -F conduct_run_lead >/dev/null || exit 9
   local o ud a c; setup "$PP"; o="$(conduct_run_lead "$PP" M1 start)"; ud="$CDIR/$KEY/m1"
   read -r a c < <(conduct_next_decide "$o" "$(int_of "$ud/rework")" "$(int_of "$ud/continuation")" "$(int_of "$ud/interruption")")
   [[ "$a" == resume ]] || exit 8
   conduct_counter_bump "$ud" "$c"
   conduct_run_lead "$PP" M1 resume) </dev/null 2>>"$CS/lead.err"; echo "rc=$?"
}
# <file> <flag> <value>: rc 0 when the argv file has <flag> immediately followed by <value>.
argv_pair() { awk -v f="$2" -v v="$3" 'p == f && $0 == v { x = 1 } { p = $0 } END { exit !x }' "$1" 2>/dev/null; }
ctx_of() { sed -n '/^<conduct_context>$/,/^<\/conduct_context>$/p' "$1" 2>/dev/null; }

# [smoke] script "handoff", mode start
sc_lead_handoff() {
  echo handoff > "$CS/claude/script"
  expect_eq "$(rl start)" "ended
rc=0" "lead: handoff -> outcome ended"
  git -C "$CSO" rev-parse --verify -q refs/heads/conduct/p/m1/handoff >/dev/null && ok || nope "lead: origin has HANDOFF_BRANCH"
  local f a="$CS/claude/argv.1"
  for f in -p --output-format stream-json --verbose --dangerously-skip-permissions --strict-mcp-config; do
    grep -Fx -- "$f" "$a" >/dev/null 2>&1 && ok || nope "lead: argv.1 has $f"
  done
  argv_pair "$a" --model opus && ok || nope "lead: argv.1 has --model opus"
  argv_pair "$a" --effort high && ok || nope "lead: argv.1 has --effort high"
  argv_pair "$a" --output-format stream-json && ok || nope "lead: argv.1 has --output-format stream-json"
  grep -Fx -- --append-system-prompt-file "$a" >/dev/null 2>&1 && nope "lead: argv.1 has no --append-system-prompt-file" || ok
  grep -Fx -- --resume "$a" >/dev/null 2>&1 && nope "lead: argv.1 has no --resume" || ok
  expect_eq "$(ctx_of "$CS/claude/prompt.1")" "<conduct_context>
PLAN: $PP
UNIT: M1
UNIT_TITLE: Greeting
MAIN_BRANCH: main
WORKTREE: $CSR/$WT1
BRANCH_PREFIX: conduct/p/m1/
HANDOFF_OUT: docs/superpowers/handoffs/p-m1-handoff.md
HANDOFF_BRANCH: conduct/p/m1/handoff
DEPENDENCY_HANDOFFS: none
DEPENDENT_UNITS: M2
VERIFY_CMD: ./verify.sh
LONG_WAIT: yes
MODE: start
FINDINGS_FILE: none
OPERATOR_ANSWER_FILE: none
</conduct_context>" "lead: prompt.1 context block"
  head -1 "$CS/claude/prompt.1" 2>/dev/null | grep -F -- "$(head -1 "$UM")" >/dev/null && ok || nope "lead: prompt.1 starts with unit.md"
  expect_eq "$(cat "$CS/claude/cwd.1" 2>/dev/null)" "$CSR/$WT1" "lead: the session runs in the unit work tree"
  expect_eq "$(cat "$CSU/attempts" 2>/dev/null)" 1 "lead: attempts 1"
  expect_eq "$(cat "$CSU/state" 2>/dev/null)" doing "lead: state doing"
  expect_eq "$(cat "$CSU/start_sha" 2>/dev/null)" "$(git -C "$CSO" rev-parse main)" "lead: start_sha = origin/main"
  expect_eq "$(cat "$CSU/session_id" 2>/dev/null)" 00000000-0000-0000-0000-000000000001 "lead: session_id from the init event"
  # Whole-unit review minor 2 (fix wave S6): the pid file is removed once the session ended.
  [[ ! -e "$CSU/pid" ]] && ok || nope "lead: the unit pid file is removed after the session"
  expect_eq "$(cat "$CS/claude/snap.1/attempts" 2>/dev/null)" 1 "lead: attempts written before the launch"
  ls "$CDIR/logs/conduct-m1-lead-"*.log >/dev/null 2>&1 && ok || nope "lead: run log in CDIR/logs"
}
scenario "lead: handoff" sc_lead_handoff

# [smoke] conduct_wait_gate after a limit, the gate opened by cs_open_gate
sc_lead_wait_limit() {
  echo limit > "$CS/claude/script"
  cs_open_gate
  expect_eq "$(rl start)" "limit
rc=0" "lead: limit -> outcome limit"
  expect_eq "$(fcs conduct_wait_gate "$PP" M1 limit)" "rc=0" "lead: conduct_wait_gate limit returns"
  expect_eq "$(cat "$CS/notify.log" 2>/dev/null)" "limit $PP M1" "lead: notify.log gains exactly one limit event"
  expect_eq "$(sed 's/^[^ ]* //' "$CDIR/notifications.log" 2>/dev/null)" "limit $PP M1" "lead: notifications.log gains the limit event"
  grep -x '[0-9][0-9]*' "$CS/gate.seen" >/dev/null 2>&1 && ok || nope "lead: the limit set an integer gate"
}
scenario "lead: wait after a limit" sc_lead_wait_limit

if is_full; then
  sc_lead_transient_keep() {
    local now; now=$(date +%s); echo $((now + 7200)) > "$CSR/$GATE_REL"
    echo transient > "$CS/claude/script"
    expect_eq "$(rl start)" "transient
rc=0" "lead: transient -> outcome transient"
    expect_eq "$(cat "$CSR/$GATE_REL" 2>/dev/null)" "$((now + 7200))" "lead: a transient backoff never shortens a longer gate"
  }
  scenario "lead: transient keeps a longer gate" sc_lead_transient_keep
  sc_lead_limit_keep() {
    local now; now=$(date +%s); echo $((now + 7200)) > "$CSR/$GATE_REL"
    echo limit > "$CS/claude/script"
    expect_eq "$(rl start)" "limit
rc=0" "lead: limit with a gate -> outcome limit"
    expect_eq "$(cat "$CSR/$GATE_REL" 2>/dev/null)" "$((now + 7200))" "lead: a limit never shortens a longer gate"
  }
  scenario "lead: limit keeps a longer gate" sc_lead_limit_keep
  sc_lead_limit_new() {
    local now; now=$(date +%s)
    echo limit > "$CS/claude/script"
    expect_eq "$(rl start)" "limit
rc=0" "lead: limit without a gate -> outcome limit"
    local g; g="$(cat "$CSR/$GATE_REL" 2>/dev/null)"
    [[ "$g" =~ ^[0-9]+$ ]] && (( g > now )) && ok || nope "lead: the limit sets a later gate: [$g]"
  }
  scenario "lead: limit sets the gate" sc_lead_limit_new
  sc_lead_lw0() {
    export CONDUCT_LONG_WAIT=0; echo nothing > "$CS/claude/script"; rl start >/dev/null
    grep -Fx 'LONG_WAIT: no' "$CS/claude/prompt.1" >/dev/null 2>&1 && ok || nope "lead: CONDUCT_LONG_WAIT=0 -> LONG_WAIT: no"
  }
  scenario "lead: CONDUCT_LONG_WAIT=0" sc_lead_lw0
  sc_lead_lw1() {
    export CONDUCT_LONG_WAIT=1; echo nothing > "$CS/claude/script"; rl start >/dev/null
    grep -Fx 'LONG_WAIT: yes' "$CS/claude/prompt.1" >/dev/null 2>&1 && ok || nope "lead: CONDUCT_LONG_WAIT=1 -> LONG_WAIT: yes"
  }
  scenario "lead: CONDUCT_LONG_WAIT=1" sc_lead_lw1
  sc_lead_quote() {
    echo handoff-quote > "$CS/claude/script"
    expect_eq "$(rl start)" "ended
rc=0" "lead: an open handoff pull request is never a limit"
    [[ ! -e "$CSR/$GATE_REL" ]] && ok || nope "lead: handoff-quote -> no gate file"
    [[ ! -s "$CS/notify.log" ]] && ok || nope "lead: handoff-quote -> notify.log empty"
  }
  scenario "lead: handoff quoting a limit" sc_lead_quote
  sc_lead_notify_unset() {
    unset FARM_NOTIFY_CMD
    expect_eq "$(fcs conduct_notify stop "$PP" M1 r)" "rc=0" "lead: conduct_notify with FARM_NOTIFY_CMD unset -> rc 0"
    grep -E "^[0-9TZ:-]+ stop $PP M1\$" "$CDIR/notifications.log" >/dev/null 2>&1 && ok || nope "lead: notifications.log gains the line"
  }
  scenario "lead: notify without a command" sc_lead_notify_unset
  sc_lead_transient_wait() {
    echo transient > "$CS/claude/script"
    expect_eq "$(rl start)" "transient
rc=0" "lead: transient -> outcome transient"
    expect_eq "$(fcs conduct_wait_gate "$PP" M1 transient)" "rc=0" "lead: conduct_wait_gate transient returns after the backoff"
    [[ ! -s "$CS/notify.log" ]] && ok || nope "lead: a transient backoff is no event"
  }
  scenario "lead: transient backoff" sc_lead_transient_wait
  sc_lead_pause() {
    touch "$CSR/.agent-farm/state/paused"
    ( sleep 2; rm -f "$CSR/.agent-farm/state/paused" ) </dev/null >/dev/null 2>&1 &
    local t0=$SECONDS
    expect_eq "$(fcs conduct_wait_gate "$PP" M1 ended)" "rc=0" "lead: conduct_wait_gate returns after the pause"
    (( SECONDS - t0 >= 1 )) && ok || nope "lead: conduct_wait_gate waits while paused"
    [[ ! -s "$CS/notify.log" ]] && ok || nope "lead: a pause is no event"
  }
  scenario "lead: pause file" sc_lead_pause
  sc_lead_far_gate() {
    local g; g=$(( $(date +%s) + 9 * 86400 )); echo "$g" > "$CSR/$GATE_REL"
    local t0=$SECONDS
    expect_eq "$(fcs conduct_wait_gate "$PP" M1 ended)" "rc=0" "lead: a gate nine days ahead -> returns"
    (( SECONDS - t0 < 30 )) && ok || nope "lead: a gate nine days ahead -> returns at once"
    expect_eq "$(cat "$CSR/$GATE_REL" 2>/dev/null)" "$g" "lead: a gate nine days ahead is left alone"
  }
  scenario "lead: gate nine days ahead" sc_lead_far_gate
  sc_lead_resume() {
    export CONDUCT_RESUME_SESSIONS=1; printf 'limit\nhandoff\n' > "$CS/claude/script"
    expect_eq "$(rl_twice)" "ended
rc=0" "lead: limit then resume -> ended"
    argv_pair "$CS/claude/argv.2" --resume 00000000-0000-0000-0000-000000000001 && ok || nope "lead: argv.2 has --resume <the first session id>"
    argv_pair "$CS/claude/argv.2" --model opus && ok || nope "lead: argv.2 passes --model again"
    expect_eq "$(cat "$CS/claude/snap.2/interruption" 2>/dev/null)" 1 "lead: interruption written before the second launch"
    expect_eq "$(cat "$CSU/attempts" 2>/dev/null)" 2 "lead: attempts 2"
  }
  scenario "lead: limit, resume" sc_lead_resume
  sc_lead_noresume() {
    export CONDUCT_RESUME_SESSIONS=0; printf 'limit\nhandoff\n' > "$CS/claude/script"
    expect_eq "$(rl_twice)" "ended
rc=0" "lead: limit then fresh -> ended"
    grep -Fx -- --resume "$CS/claude/argv.2" >/dev/null 2>&1 && nope "lead: RESUME_SESSIONS=0 -> argv.2 has no --resume" || ok
    grep -Fx 'MODE: resume' "$CS/claude/prompt.2" >/dev/null 2>&1 && ok || nope "lead: prompt.2 has MODE: resume"
    local w1 w2; w1="$(grep '^WORKTREE: ' "$CS/claude/prompt.1" 2>/dev/null)"; w2="$(grep '^WORKTREE: ' "$CS/claude/prompt.2" 2>/dev/null)"
    [[ -n "$w1" && "$w1" == "$w2" ]] && ok || nope "lead: the same WORKTREE in both prompts: [$w1] [$w2]"
  }
  scenario "lead: limit, fresh" sc_lead_noresume
  sc_lead_hang() {
    export CONDUCT_MAX_SESSION_SECONDS=2; echo hang > "$CS/claude/script"
    local t0=$SECONDS dt p
    expect_eq "$(rl start)" "ended
rc=0" "lead: hang -> outcome ended"
    dt=$((SECONDS - t0))
    [[ "$dt" -lt 120 ]] && ok || nope "lead: a hanging session is ended under 120s: took ${dt}s"
    p="$(cat "$CS/claude/pid.1" 2>/dev/null)"
    [[ -n "$p" ]] && ! kill -0 "$p" 2>/dev/null && ok || nope "lead: the fake's pid is gone"
  }
  scenario "lead: session watchdog" sc_lead_hang
  sc_lead_env() {
    export FARM_STATE_DIR="$CS/fsd" ANTHROPIC_API_KEY=not-a-key ANTHROPIC_AUTH_TOKEN=not-a-token
    echo nothing > "$CS/claude/script"; rl start >/dev/null
    local e="$CS/claude/env.1"
    grep -Fx 'FARM_AGENT=1' "$e" >/dev/null 2>&1 && ok || nope "lead: env.1 has FARM_AGENT=1"
    grep -Fx "FARM_WORKTREE=$CSR/$WT1" "$e" >/dev/null 2>&1 && ok || nope "lead: env.1 has FARM_WORKTREE=<the unit work tree>"
    grep -Fx 'AGENT_NAME=farm-conduct' "$e" >/dev/null 2>&1 && ok || nope "lead: env.1 has AGENT_NAME=farm-conduct"
    [[ -f "$e" ]] && ! grep -E '^(FARM_STATE_DIR|GIT_CONFIG_COUNT|ANTHROPIC_API_KEY|ANTHROPIC_AUTH_TOKEN)=' "$e" >/dev/null && ok \
      || nope "lead: env.1 has no FARM_STATE_DIR, GIT_CONFIG_COUNT, ANTHROPIC_API_KEY or ANTHROPIC_AUTH_TOKEN"
  }
  scenario "lead: session environment" sc_lead_env
  sc_lead_bad_attempts() {
    mkdir -p "$CSR/$WT1"; echo keep > "$CSR/$WT1/marker"; echo sha0 > "$CSU/start_sha"
    # shellcheck disable=SC2016  # the literal text is the point
    printf '%s\n' 'HOME[$(touch PWNED)]' > "$CSU/attempts"
    case "$(rl start)" in *"rc=0") nope "lead: a non-integer attempts file -> conduct_run_lead fails" ;; *rc=9) nope "lead: bad attempts: conduct_run_lead missing" ;; *) ok ;; esac
    expect_eq "$(cat "$CSR/$WT1/marker" 2>/dev/null)" keep "lead: bad attempts -> the work tree is kept"
    expect_eq "$(cat "$CSU/start_sha" 2>/dev/null)" sha0 "lead: bad attempts -> start_sha unchanged"
    [[ -z "$(find "$CS" "$CSR" -name PWNED 2>/dev/null)" ]] && ok || nope "lead: bad attempts is not evaluated"
    no_claude "lead: bad attempts"
  }
  scenario "lead: bad attempts file" sc_lead_bad_attempts
  kill_tree() { local c; for c in $(pgrep -P "$1"); do kill_tree "$c"; done; kill -TERM "$1" 2>/dev/null; }
  sc_lead_reap() {
    export CONDUCT_MAX_SESSION_SECONDS=7771; echo nothing > "$CS/claude/script"
    expect_eq "$(rl start)" "ended
rc=0" "lead: reap -> outcome ended"
    pgrep -f 'sleep 7771' >/dev/null && nope "lead: no watchdog after a normal end" || ok
    export CONDUCT_MAX_SESSION_SECONDS=7772; echo hang > "$CS/claude/script"; rm -f "$CS/claude/"*.1
    rm -rf "$CS/claude/snap.1"
    (cd / && export CONDUCT_DEFINE_ONLY=1 && source "$FARM/bin/farm-conduct.sh" >/dev/null 2>&1 \
      && conduct_run_lead "$PP" M1 start) </dev/null >/dev/null 2>&1 &
    local dp=$! i=0 p
    while (( i < 100 )) && [[ ! -s "$CS/claude/pid.1" ]]; do sleep 0.2; i=$((i + 1)); done
    sleep 1; p="$(cat "$CS/claude/pid.1" 2>/dev/null)"
    kill -TERM "$dp" 2>/dev/null; wait "$dp" 2>/dev/null
    [[ -n "$p" ]] && ! kill -0 "$p" 2>/dev/null && ok || nope "lead: TERM to the conductor ends the session"
    pgrep -f 'sleep 7772' >/dev/null && nope "lead: no watchdog after a TERM to the conductor" || ok
    [[ ! -e "$CSU/pid" ]] && ok || nope "lead: TERM to the conductor removes the unit pid file"
  }
  scenario "lead: watchdog reaped" sc_lead_reap
  # Security review M3a F6: a SIGKILLed conductor leaves no watchdog behind.
  sc_lead_orphan_watchdog() {
    export CONDUCT_MAX_SESSION_SECONDS=7773; echo hang > "$CS/claude/script"
    (cd / && export CONDUCT_DEFINE_ONLY=1 && source "$FARM/bin/farm-conduct.sh" >/dev/null 2>&1 \
      && conduct_run_lead "$PP" M1 start) </dev/null >/dev/null 2>&1 &
    local dp=$! i=0 p s w=""
    while (( i < 100 )) && [[ ! -s "$CS/claude/pid.1" ]]; do sleep 0.2; i=$((i + 1)); done
    sleep 1; p="$(cat "$CS/claude/pid.1" 2>/dev/null)"
    s="$(pgrep -f 'sleep 7773' | head -1)"; [[ -n "$s" ]] && w="$(ps -o ppid= -p "$s" 2>/dev/null | tr -d ' ')"
    [[ "$w" =~ ^[0-9]+$ ]] && ok || nope "lead: the watchdog is running before the kill: [$w]"
    kill -KILL "$dp" 2>/dev/null; wait "$dp" 2>/dev/null
    i=0
    while (( i < 120 )) && { pgrep -f 'sleep 7773' >/dev/null || { [[ -n "$w" ]] && kill -0 "$w" 2>/dev/null; } \
        || { [[ -n "$p" ]] && kill -0 "$p" 2>/dev/null; }; }; do sleep 1; i=$((i + 1)); done
    pgrep -f 'sleep 7773' >/dev/null && nope "lead: no watchdog sleep 120s after a SIGKILL to the conductor" || ok
    [[ -n "$w" ]] && kill -0 "$w" 2>/dev/null && nope "lead: the watchdog exits within 120s of a SIGKILL to the conductor" || ok
    # Re-review N1: the orphaned watchdog ends the session first (no session without a time cap).
    [[ "$p" =~ ^[0-9]+$ ]] && ! kill -0 "$p" 2>/dev/null && ok || nope "lead: SIGKILLed conductor -> the fake's pid is gone within 120s"
    [[ ! -e "$CSU/pid" ]] && ok || nope "lead: SIGKILLed conductor -> the watchdog removes the unit pid file"
    pkill -f 'sleep 7773' 2>/dev/null; [[ -z "$p" ]] || kill "$p" 2>/dev/null
  }
  scenario "lead: watchdog after a SIGKILL" sc_lead_orphan_watchdog
  # Whole-unit review minor 4 (fix wave S6): the classification's pr list names the repository.
  sc_lead_pr_list_repo() {
    printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/gh.args"\nexec "%s/gh" "$@"\n' "$CS" "$STUBS" > "$CS/bin/gh"
    echo handoff > "$CS/claude/script"
    expect_eq "$(rl start)" "ended
rc=0" "lead: gh -R -> outcome ended"
    local slug; slug="$(basename "$(dirname "$CSR")")/origin"
    grep -Fx -- "pr list -R $slug --state all --search head:conduct/p/m1/ --limit 200 --json number,headRefName,state,files,headRefOid" "$CS/gh.args" >/dev/null \
      && ok || nope "lead: gh pr list gets -R $slug: [$(grep 'pr list' "$CS/gh.args" 2>/dev/null)]"
  }
  scenario "lead: gh pr list -R" sc_lead_pr_list_repo
  sc_lead_wait_unread() {
    printf 'exit 1\n' > "$CSR/.agent-farm/farm.env"   # every farm-lib child now fails
    (fcs conduct_wait_gate "$PP" M1 ended >/dev/null 2>&1) &
    local p=$!; sleep 3
    kill -0 "$p" 2>/dev/null && ok || nope "lead: an unreadable pause/gate state keeps conduct_wait_gate waiting"
    kill_tree "$p"; wait "$p" 2>/dev/null
  }
  scenario "lead: pause read fails closed" sc_lead_wait_unread
fi

# ---- guard proof: conduct_guard_settings, conduct_guard_listed_decide, the init check (section "guard proof") ----
# shellcheck source=../../bin/farm-conduct-lib.sh
gs() { (source "$LIB" || exit 9; declare -F conduct_guard_settings >/dev/null || exit 9; conduct_guard_settings "$@") </dev/null 2>/dev/null; }
expect_eq "$(gs /p | jq -c '[.hooks.PreToolUse[].matcher] | sort' 2>/dev/null)" '["Bash","Write|Edit|MultiEdit|NotebookEdit","mcp__.*"]' \
  "guard-proof: settings matchers"
got="$(gs /p | jq -r '[.hooks.PreToolUse[].hooks[].command] | unique | .[]' 2>/dev/null)"
[[ -n "$got" && "$(printf '%s\n' "$got" | wc -l | tr -d ' ')" == 1 && "$got" == *"/p/hooks/guard-bash.sh"* ]] && ok \
  || nope "guard-proof: one hook command naming /p/hooks/guard-bash.sh: got=[$got]"
expect_eq "$(gs /p | jq -c '[.hooks.PreToolUse[].hooks[].timeout] | unique' 2>/dev/null)" "[120]" "guard-proof: settings hook timeout 120"
expect_eq "$(jq -c '[.hooks.PreToolUse[].hooks[].timeout] | unique' "$FARM/hooks/hooks.json" 2>/dev/null)" "[120]" "guard-proof: hooks.json timeout 120"
gld() { run_fn conduct_guard_listed_decide "$@"; }
GI_S="$(jq -nc --arg c "'/p/hooks/guard-bash.sh'" '{type:"system",subtype:"init",session_id:"s",hooks:[$c]}')"
GI_P="$(jq -nc '{type:"system",subtype:"init",session_id:"s",plugins:[{name:"agent-farm",path:"/p"}]}')"
GI_O="$(jq -nc '{type:"system",subtype:"init",session_id:"s",plugins:[{name:"agent-farm",path:"/other/cache/path"}]}')"
expect_eq "$(printf '%s\n' "$GI_S" | gld settings /p)" "listed
rc=0" "guard-proof: settings, a string naming the guard -> listed"
expect_eq "$(printf '%s\n' "$GI_P" | gld settings /p)" "not-listed
rc=0" "guard-proof: settings, only a plugin at /p -> not-listed"
expect_eq "$(printf '%s\n' "$GI_P" | gld plugin-dir /p)" "listed
rc=0" "guard-proof: plugin-dir, plugins[].path == /p -> listed"
expect_eq "$(printf '%s\n' "$GI_O" | gld plugin-dir /p)" "not-listed
rc=0" "guard-proof: plugin-dir, the operator's installed copy -> not-listed"
expect_eq "$(printf '%s\n' "$GI_S" | gld plugin-dir /p)" "not-listed
rc=0" "guard-proof: plugin-dir, only a settings hook -> not-listed"
expect_eq "$(printf '' | gld settings /p)" "not-listed
rc=0" "guard-proof: empty input -> not-listed"
expect_eq "$(printf 'not json\n' | gld settings /p)" "not-listed
rc=0" "guard-proof: 'not json' -> not-listed"
expect_eq "$(printf '%s\n' "$GI_P" | gld bogus /p)" "not-listed
rc=0" "guard-proof: unknown mode -> not-listed"
expect_eq "$(printf '%s\n' "$GI_S" | gld settings '')" "not-listed
rc=0" "guard-proof: empty farm dir -> not-listed"
gi_hook() { jq -nc --arg c "$1" '{type:"system",subtype:"init",session_id:"s",hooks:[$c]}'; }
expect_eq "$(gi_hook /p/hooks/guard-bash.sh | gld settings /p)" "listed
rc=0" "guard-proof: settings, the raw guard path -> listed"
expect_eq "$(gi_hook /x/p/hooks/guard-bash.sh | gld settings /p)" "not-listed
rc=0" "guard-proof: settings, /x/p/hooks/guard-bash.sh -> not-listed"
expect_eq "$(gi_hook /p/hooks/guard-bash.sh.disabled | gld settings /p)" "not-listed
rc=0" "guard-proof: settings, /p/hooks/guard-bash.sh.disabled -> not-listed"
# A symlinked farm dir: its own path and its physical form are listed, nothing else.
mkdir -p "$TROOT/gpl/real" && ln -s "$TROOT/gpl/real" "$TROOT/gpl/link"
GPR="$(cd "$TROOT/gpl/real" && pwd -P)"
gi_plug() { jq -nc --arg p "$1" '{type:"system",subtype:"init",session_id:"s",plugins:[{name:"agent-farm",path:$p}]}'; }
expect_eq "$(gi_plug "$GPR" | gld plugin-dir "$TROOT/gpl/link")" "listed
rc=0" "guard-proof: plugin-dir, the physical form of a symlinked farm dir -> listed"
expect_eq "$(gi_plug "$TROOT/gpl/link" | gld plugin-dir "$TROOT/gpl/link")" "listed
rc=0" "guard-proof: plugin-dir, the symlinked farm dir itself -> listed"
expect_eq "$(gi_plug "$TROOT/gpl" | gld plugin-dir "$TROOT/gpl/link")" "not-listed
rc=0" "guard-proof: plugin-dir, the symlink's parent -> not-listed"

# <argv file> <flag>: the value after the flag.
argv_val() { awk -v f="$2" 'p == f { print; exit } { p = $0 }' "$1" 2>/dev/null; }
no_prefix_branch() { [[ -z "$(git -C "$CSO" for-each-ref refs/heads/conduct/p/m1/ 2>/dev/null)" ]] && ok || nope "$1: origin has no branch under BRANCH_PREFIX"; }
# <description>: every pid the fake recorded is gone (its sleep 300 is exec'd, so the same pid)
# and has no child left.
fake_gone() {
  local f p n=0
  for f in "$CS/claude/pid."*; do
    [[ -f "$f" ]] || continue; p="$(cat "$f")"; n=$((n + 1))
    [[ "$p" =~ ^[0-9]+$ ]] && ! kill -0 "$p" 2>/dev/null && ok || nope "$1: the fake's pid ${f##*/} is gone"
    [[ "$p" =~ ^[0-9]+$ ]] && pgrep -P "$p" >/dev/null && nope "$1: no child of ${f##*/} left" || ok
  done
  [[ "$n" -gt 0 ]] && ok || nope "$1: the fake recorded a pid"
}
# [smoke] script "handoff", mode settings: the settings file is the guard's and the session continues
sc_guard_handoff() {
  echo handoff > "$CS/claude/script"
  expect_eq "$(rl start)" "ended
rc=0" "guard-proof: handoff, guard listed -> outcome ended"
  local f; f="$(argv_val "$CS/claude/argv.1" --settings)"
  [[ -n "$f" && -f "$f" ]] && ok || nope "guard-proof: argv.1 has --settings <file>: [$f]"
  expect_eq "$(cat "$f" 2>/dev/null)" "$(gs "$FARM")" "guard-proof: the settings file equals conduct_guard_settings FARM"
  grep -Fx -- --plugin-dir "$CS/claude/argv.1" >/dev/null 2>&1 && nope "guard-proof: settings mode -> no --plugin-dir" || ok
}
scenario "guard-proof: handoff" sc_guard_handoff
# [smoke] script "noguard": the session is ended at once
sc_guard_noguard() {
  echo noguard > "$CS/claude/script"
  local t0=$SECONDS dt
  expect_eq "$(rl start)" "guard-not-loaded
rc=0" "guard-proof: noguard -> outcome guard-not-loaded"
  dt=$((SECONDS - t0)); [[ "$dt" -lt 120 ]] && ok || nope "guard-proof: noguard ended under 120s: took ${dt}s"
  fake_gone "guard-proof: noguard"
  no_prefix_branch "guard-proof: noguard"
}
scenario "guard-proof: noguard" sc_guard_noguard
if is_full; then
  sc_guard_noinit() {
    echo noinit > "$CS/claude/script"
    echo 11111111-1111-1111-1111-111111111111 > "$CSU/session_id"
    local t0=$SECONDS dt
    expect_eq "$(rl start)" "guard-not-loaded
rc=0" "guard-proof: noinit -> outcome guard-not-loaded"
    dt=$((SECONDS - t0)); [[ "$dt" -ge 5 && "$dt" -lt 120 ]] && ok || nope "guard-proof: noinit ended after CONDUCT_INIT_TIMEOUT_SECONDS, under 120s: took ${dt}s"
    fake_gone "guard-proof: noinit"
    no_prefix_branch "guard-proof: noinit"
    [[ ! -e "$CSU/session_id" ]] && ok || nope "guard-proof: noinit leaves no previous session_id behind"
  }
  scenario "guard-proof: noinit" sc_guard_noinit
  sc_guard_plugin_dir() {
    export CONDUCT_GUARD_MODE=plugin-dir; echo handoff > "$CS/claude/script"
    expect_eq "$(rl start)" "ended
rc=0" "guard-proof: plugin-dir, handoff -> outcome ended"
    argv_pair "$CS/claude/argv.1" --plugin-dir "$FARM" && ok || nope "guard-proof: argv.1 has --plugin-dir FARM"
    grep -Fx -- --settings "$CS/claude/argv.1" >/dev/null 2>&1 && nope "guard-proof: plugin-dir -> no --settings" || ok
  }
  scenario "guard-proof: plugin-dir" sc_guard_plugin_dir
  sc_guard_default() {
    unset CONDUCT_GUARD_MODE; echo nothing > "$CS/claude/script"; rl start >/dev/null
    argv_pair "$CS/claude/argv.1" --plugin-dir "$FARM" && ok || nope "guard-proof: the default mode is plugin-dir"
  }
  scenario "guard-proof: default mode" sc_guard_default
  sc_guard_bad_mode() {
    export CONDUCT_GUARD_MODE=bogus; echo handoff > "$CS/claude/script"
    expect_eq "$(rl start)" "guard-not-loaded
rc=0" "guard-proof: an unknown mode -> guard-not-loaded"
    no_claude "guard-proof: unknown mode"
  }
  scenario "guard-proof: unknown mode" sc_guard_bad_mode
  sc_guard_resume() {
    export CONDUCT_RESUME_SESSIONS=1; printf 'limit\nnoguard\n' > "$CS/claude/script"
    expect_eq "$(rl_twice)" "guard-not-loaded
rc=0" "guard-proof: a resumed session's init event is checked again"
    argv_pair "$CS/claude/argv.2" --resume 00000000-0000-0000-0000-000000000001 && ok || nope "guard-proof: argv.2 resumes"
    [[ -n "$(argv_val "$CS/claude/argv.2" --settings)" ]] && ok || nope "guard-proof: argv.2 carries --settings again"
  }
  scenario "guard-proof: resumed session" sc_guard_resume
  # conduct_launch itself proves the guard, for the review role too.
  sc_guard_launch_review() {
    echo noguard > "$CS/claude/script"
    local got
    got="$( (cd / && export CONDUCT_DEFINE_ONLY=1 && source "$FARM/bin/farm-conduct.sh" >/dev/null 2>&1 || exit 9
      declare -F conduct_launch >/dev/null || exit 9
      # shellcheck disable=SC2034  # read by conduct_launch
      CONDUCT_UNIT_DIR="$CSU"
      conduct_launch review "$CSR" "review prompt" "$CS/review.log" || exit 8
      wait "$CONDUCT_SESSION_PID" || true; _conduct_stop_watchdog; trap - EXIT INT TERM
      echo "$CONDUCT_GUARD_PROOF") </dev/null 2>>"$CS/lead.err"; echo "rc=$?")"
    expect_eq "$got" "stop
rc=0" "guard-proof: conduct_launch review, noguard -> session ended (CONDUCT_GUARD_PROOF stop)"
    argv_pair "$CS/claude/argv.1" --settings "$CSU/guard-settings.json" && ok || nope "guard-proof: the review session has --settings"
    fake_gone "guard-proof: conduct_launch review"
  }
  scenario "guard-proof: conduct_launch review" sc_guard_launch_review
  # Security review M3a F4: a session must not change the next session's .claude settings in
  # the reused work tree. <description> <how to tamper (a function)>: one clean launch, the
  # tamper, then a continue -> settings-tampered and no second claude invocation.
  tamper_case() {
    echo nothing > "$CS/claude/script"
    expect_eq "$(rl start)" "ended
rc=0" "$1: the first, clean launch runs"
    "$2"
    expect_eq "$(rl continue)" "settings-tampered
rc=0" "$1 -> outcome settings-tampered"
    [[ -e "$CS/claude/argv.1" && ! -e "$CS/claude/argv.2" ]] && ok || nope "$1: no second claude invocation"
    [[ ! -e "$CSU/pid" ]] && ok || nope "$1: no pid file"
  }
  t_untracked() { mkdir -p "$CSR/$WT1/.claude" && echo '{"disableAllHooks":true}' > "$CSR/$WT1/.claude/settings.json"; }
  t_modified() { echo '{"disableAllHooks":true}' > "$CSR/$WT1/.claude/settings.json"; }
  t_symlink() { mkdir -p "$CS/elsewhere" && ln -s "$CS/elsewhere" "$CSR/$WT1/.claude"; }
  sc_tamper_untracked() { tamper_case "settings: planted untracked .claude/settings.json" t_untracked; }
  scenario "settings: untracked" sc_tamper_untracked
  sc_tamper_modified() {
    push_file "$CSR" .claude/settings.json '{}'
    tamper_case "settings: modified tracked .claude/settings.json" t_modified
  }
  scenario "settings: modified" sc_tamper_modified
  sc_tamper_symlink() { tamper_case "settings: .claude a symlink" t_symlink; }
  scenario "settings: symlink" sc_tamper_symlink
  # Re-review probe: index flags the session sets hide the change from git status and git diff.
  t_assume() {
    git -C "$CSR/$WT1" update-index --assume-unchanged .claude/settings.json
    echo '{"disableAllHooks":true}' > "$CSR/$WT1/.claude/settings.json"
  }
  t_skip_link() {
    git -C "$CSR/$WT1" update-index --skip-worktree .claude/settings.json
    echo '{"disableAllHooks":true}' > "$CSR/$WT1/s.json" && ln -sf ../s.json "$CSR/$WT1/.claude/settings.json"
  }
  sc_tamper_assume() {
    push_file "$CSR" .claude/settings.json '{}'
    tamper_case "settings: assume-unchanged, then a replaced file" t_assume
  }
  scenario "settings: assume-unchanged" sc_tamper_assume
  sc_tamper_skip_link() {
    push_file "$CSR" .claude/settings.json '{}'
    tamper_case "settings: skip-worktree, then a symlink" t_skip_link
  }
  scenario "settings: skip-worktree symlink" sc_tamper_skip_link
  sc_claude_untouched() {
    push_file "$CSR" .claude/settings.json '{}'
    push_exec "$CSR" .claude/hook.sh '#!/bin/sh'
    echo nothing > "$CS/claude/script"
    expect_eq "$(rl start) $(rl continue)" "ended
rc=0 ended
rc=0" "settings: an untouched tracked .claude (with an executable file) -> both launches run"
    [[ -e "$CS/claude/argv.2" ]] && ok || nope "settings: untouched .claude -> a second claude invocation"
  }
  scenario "settings: untouched" sc_claude_untouched
  sc_guard_apikey() {
    export CONDUCT_GUARD_MODE=plugin-dir; echo apikey > "$CS/claude/script"
    expect_eq "$(rl start)" "guard-not-loaded
rc=0" "guard-proof: init apiKeySource ANTHROPIC_API_KEY -> guard-not-loaded"
    fake_gone "guard-proof: apikey"
  }
  scenario "guard-proof: apiKeySource" sc_guard_apikey
  # Whole-unit review minor 1 (fix wave S6): an early rc 1 leaves no stale proof behind.
  sc_guard_proof_reset() {
    local got
    got="$( (cd / && export CONDUCT_DEFINE_ONLY=1 && source "$FARM/bin/farm-conduct.sh" >/dev/null 2>&1 || exit 9
      declare -F conduct_launch >/dev/null || exit 9
      CONDUCT_GUARD_PROOF=listed
      conduct_launch bogus "$CSR" p "$CS/x.log" && exit 8
      echo "[$CONDUCT_GUARD_PROOF]") </dev/null 2>>"$CS/lead.err"; echo "rc=$?")"
    expect_eq "$got" "[]
rc=0" "guard-proof: conduct_launch with a bad role resets CONDUCT_GUARD_PROOF"
  }
  scenario "guard-proof: proof reset" sc_guard_proof_reset
fi

# ---- progress evidence: conduct_progress_decide, conduct_find_prs, conduct_other_open, conduct_refine_ended (section "evidence") ----
pd() { run_fn conduct_progress_decide "$@" </dev/null; }
expect_eq "$(pd 0 1 '' '')" "progress
rc=0" "evidence: progress 0 1 '' '' -> progress"
expect_eq "$(pd 2 2 abc abc)" "no-progress
rc=0" "evidence: progress 2 2 abc abc -> no-progress"
expect_eq "$(pd 1 1 '' abc)" "progress
rc=0" "evidence: progress 1 1 '' abc -> progress"
expect_eq "$(pd 1 1 abc def)" "progress
rc=0" "evidence: progress 1 1 abc def -> progress"
expect_eq "$(pd x 1 '' '')" "no-progress
rc=0" "evidence: progress x 1 '' '' -> no-progress (a non-integer count is not evidence)"
# Pilot finding 3: the fifth argument is the run log's guard denial count; it only turns no-progress into guard-blocked.
expect_eq "$(pd 2 2 abc abc 1)" "guard-blocked
rc=0" "evidence: progress 2 2 abc abc 1 -> guard-blocked"
expect_eq "$(pd 2 2 abc abc 0) $(pd 2 2 abc abc x) $(pd 2 2 abc abc '')" "no-progress
rc=0 no-progress
rc=0 no-progress
rc=0" "evidence: progress 2 2 abc abc with 0, x or '' denials -> no-progress"
expect_eq "$(pd 0 1 '' '' 3) $(pd 1 1 abc def 1)" "progress
rc=0 progress
rc=0" "evidence: a session with progress and denials -> progress"

# <fake action>: conduct_run_lead start with that action, then conduct_refine_ended; stdout: the
# refined outcome, then "rc=N"; rc 9 without the function.
ev_run() {
  echo "$1" > "$CS/claude/script"
  (cd / && export CONDUCT_DEFINE_ONLY=1 && source "$FARM/bin/farm-conduct.sh" >/dev/null 2>&1 || exit 9
   declare -F conduct_refine_ended >/dev/null || exit 9
   conduct_run_lead "$PP" M1 start >/dev/null
   conduct_refine_ended "$PP" M1) </dev/null 2>>"$CS/lead.err"; echo "rc=$?"
}
# <branch> <file count> <directory>: a commit adding that many files under <directory> on
# <branch> (from origin/main), pushed to the fake origin, and a pull request opened for it.
ev_pr() {
  local c="$CS/pc" i=0
  [[ -d "$c" ]] || git clone -q "$CSO" "$c" 2>/dev/null
  git -C "$c" fetch -q origin && git -C "$c" checkout -q -B "$1" origin/main
  mkdir -p "$c/$3"
  while (( i < $2 )); do echo "$i" > "$c/$3/f$i"; i=$((i + 1)); done
  gitq -C "$c" add -A && gitq -C "$c" commit -qm "$1" && git -C "$c" push -q origin "$1" 2>/dev/null
  gh pr create --head "$1" --title t --body b >/dev/null
}

# [smoke] after fake "handoff" -> handoff
sc_ev_handoff() {
  expect_eq "$(ev_run handoff)" "handoff
rc=0" "evidence: after fake handoff -> handoff"
}
scenario "evidence: handoff" sc_ev_handoff

if is_full; then
  sc_ev_code_pr() {
    expect_eq "$(ev_run code-pr)" "progress
rc=0" "evidence: after fake code-pr -> progress"
    expect_eq "$(grep -c . "$CSU/prs" 2>/dev/null) $(grep -cx '[0-9][0-9]*' "$CSU/prs" 2>/dev/null)" "1 1" "evidence: code-pr -> the prs file has one number"
    expect_eq "$(cat "$CSU/merged_before" 2>/dev/null)" 0 "evidence: merged count recorded at session start"
  }
  scenario "evidence: code-pr" sc_ev_code_pr
  sc_ev_nothing() {
    expect_eq "$(ev_run nothing)" "no-progress
rc=0" "evidence: after fake nothing -> no-progress"
  }
  scenario "evidence: nothing" sc_ev_nothing
  sc_ev_protected() {
    expect_eq "$(ev_run protected-pr)" "awaiting-merge
rc=0" "evidence: after fake protected-pr -> awaiting-merge"
  }
  scenario "evidence: protected-pr" sc_ev_protected
  sc_ev_protected_handoff() {
    expect_eq "$(ev_run protected-and-handoff)" "awaiting-merge
rc=0" "evidence: after fake protected-and-handoff -> awaiting-merge (a protected pull request outranks an open handoff)"
  }
  scenario "evidence: protected-and-handoff" sc_ev_protected_handoff
  sc_ev_open_handoff() {
    expect_eq "$(ev_run open-pr-and-handoff)" "handoff
rc=0" "evidence: after fake open-pr-and-handoff -> handoff"
    expect_eq "$(fcs conduct_other_open "$PP" M1)" "open 1
rc=0" "evidence: open-pr-and-handoff -> conduct_other_open prints open 1"
  }
  scenario "evidence: open-pr-and-handoff" sc_ev_open_handoff
  sc_ev_direct_push() {
    expect_eq "$(ev_run direct-push)" "shipped-unreviewed
rc=0" "evidence: after fake direct-push -> shipped-unreviewed"
  }
  scenario "evidence: direct-push" sc_ev_direct_push
  sc_ev_prefix() {
    ev_pr conduct/p/m1/a 1 src
    ev_pr conduct/p/m1-old 1 src
    # The fake's head: search, like GitHub's, is no exact prefix match: both come back.
    expect_eq "$(gh pr list --state all --search head:conduct/p/m1/ --limit 200 --json number,headRefName | jq length 2>/dev/null)" 2 "evidence: the fake search returns the unprefixed pull request too"
    local got; got="$(fcs conduct_find_prs "$PP" M1)"
    expect_eq "$(printf '%s\n' "$got" | sed '$d' | jq -c '[.[].headRefName]' 2>/dev/null)" '["conduct/p/m1/a"]' "evidence: conduct_find_prs keeps only the prefixed pull request"
    expect_eq "$(cat "$CSU/prs" 2>/dev/null)" 1 "evidence: a pull request whose branch lacks the unit prefix is not in the prs file"
  }
  scenario "evidence: prefix filter" sc_ev_prefix
  sc_ev_hundred() {
    ev_pr conduct/p/m1/big 100 src
    expect_eq "$(fcs conduct_other_open "$PP" M1)" "protected 1
rc=0" "evidence: an open prefixed pull request with 100 files counts as protected"
  }
  scenario "evidence: 100 files" sc_ev_hundred
  sc_ev_no_globs() {
    local nd="$CS/nodefaults"
    mkdir -p "$nd/hooks"; cp "$FARM/hooks/guard-bash.sh" "$nd/hooks/"
    ev_pr conduct/p/m1/code 1 src
    expect_eq "$(fcs conduct_other_open "$PP" M1)" "open 1
rc=0" "evidence: an unprotected open pull request -> open 1"
    expect_eq "$( (export CONDUCT_DEFINE_ONLY=1; source "$FARM/bin/farm-conduct.sh" >/dev/null 2>&1 || exit 9
      declare -F conduct_other_open >/dev/null || exit 9
      # shellcheck disable=SC2034  # read by conduct_other_open (farm-conduct.sh)
      FARM_DIR="$nd"; conduct_other_open "$PP" M1) </dev/null 2>/dev/null; echo "rc=$?")" "protected 1
rc=0" "evidence: no defaults and no project list -> every open prefixed pull request counts as protected"
  }
  scenario "evidence: globs cannot be built" sc_ev_no_globs
  # Ruling R4: a fork's pull request whose branch carries the unit prefix is not the unit's.
  sc_ev_cross_repo() {
    ev_pr conduct/p/m1/a 1 src
    ev_pr conduct/p/m1/fork 1 lib
    jq 'map(if .number == 2 then .isCrossRepository = true else . end)' "$CS/gh/prs.json" > "$CS/gh/prs.json.t" \
      && mv "$CS/gh/prs.json.t" "$CS/gh/prs.json"
    expect_eq "$(fcs conduct_find_prs "$PP" M1 | sed '$d' | jq -c '[.[].number]' 2>/dev/null) $(cat "$CSU/prs" 2>/dev/null)" "[1] 1" \
      "evidence: a cross-repository pull request with a prefixed branch is not in the prs file"
  }
  scenario "evidence: cross-repository pull request" sc_ev_cross_repo
  # Fix wave F3: a page of exactly --limit (200) results may hide more; the list is unknown.
  sc_ev_full_page() {
    echo 7 > "$CSU/prs"
    jq -nc '[range(1; 201) | {number: ., headRefName: "conduct/p/m1/c\(.)", baseRefName: "main", isCrossRepository: false,
      state: "CLOSED", files: [], headRefOid: ""}]' > "$CS/gh/prs.json"
    expect_eq "$(fcs conduct_find_prs "$PP" M1 | tail -1) $(cat "$CSU/prs" 2>/dev/null)" "rc=1 7" \
      "evidence: gh answers a full page of 200 pull requests -> rc 1, prs file unchanged"
    jq -c '.[1:]' "$CS/gh/prs.json" > "$CS/gh/prs.json.t" && mv "$CS/gh/prs.json.t" "$CS/gh/prs.json"
    expect_eq "$(fcs conduct_find_prs "$PP" M1 | tail -1) $(wc -l < "$CSU/prs" 2>/dev/null | tr -d ' ')" "rc=0 199" \
      "evidence: 199 pull requests (less than a page) -> rc 0, all in the prs file"
    [[ ! -e "$CS/gh/unknown.log" ]] && ok || nope "evidence: full page -> no unknown gh call: $(cat "$CS/gh/unknown.log" 2>/dev/null)"
  }
  scenario "evidence: full page of pull requests" sc_ev_full_page
fi

# ---- the handoff pull request: conduct_check_handoff_pr (section "handoff-pr") ----
# <fake action> [handoff text]: the fake's handoff content, then conduct_run_lead start with that action.
hp_lead() {
  printf '%s\n' "${2:-$HO}" > "$CS/claude/handoff.md"
  echo "$1" > "$CS/claude/script"
  (cd / && export CONDUCT_DEFINE_ONLY=1 && source "$FARM/bin/farm-conduct.sh" >/dev/null 2>&1 || exit 9
   conduct_run_lead "$PP" M1 start >/dev/null) </dev/null 2>>"$CS/lead.err"
}
hp_check() { (cd / && fcs conduct_check_handoff_pr "$PP" M1 "$1") 2>>"$CS/lead.err"; }
hp_pr1() { # <jq update of pull request 1>; frozen: the fake no longer refreshes it from the origin
  jq "map(if .number == 1 then $1 | .frozen = true else . end)" "$CS/gh/prs.json" > "$CS/gh/prs.json.t" \
    && mv "$CS/gh/prs.json.t" "$CS/gh/prs.json"
}
HPH=conduct/p/m1/handoff
# Probe p1 (security review F1): a protected file on main, then the handoff branch renames it.
HPCI=.github/workflows/ci.yml
hp_ci_main() { push_file "$CSR" "$HPCI" "$(awk 'BEGIN { for (i = 1; i <= 300; i++) printf "      - run: step %d of the protected workflow\n", i }')"; }
# The next commit on origin's handoff branch: HANDOFF_OUT replaced by $HPCI moved there, the
# handoff text first and the old file as an appendix (so git pairs them as a rename).
hp_rename() {
  local c="$CS/rn"
  git clone -q "$CSO" "$c" 2>/dev/null && git -C "$c" checkout -q -B "$HPH" "origin/$HPH" \
    && { cat "$c/$HOUT"; printf '\n## Appendix\n\n'; cat "$c/$HPCI"; } > "$c/ho.t" \
    && gitq -C "$c" rm -q -- "$HOUT" && mkdir -p "$c/$(dirname "$HOUT")" \
    && gitq -C "$c" mv -- "$HPCI" "$HOUT" && mv "$c/ho.t" "$c/$HOUT" \
    && gitq -C "$c" add -- "$HOUT" && gitq -C "$c" commit -qm rename && git -C "$c" push -q origin "$HPH" 2>/dev/null
}
# R6: a --no-ff merge of a side branch that only edits HANDOFF_OUT, pushed onto the handoff branch.
hp_merge_commit() {
  local c="$CS/mc"
  git clone -q "$CSO" "$c" 2>/dev/null && git -C "$c" checkout -q -B side "origin/$HPH" \
    && echo side >> "$c/$HOUT" && gitq -C "$c" commit -qam side && git -C "$c" checkout -q -B "$HPH" "origin/$HPH" \
    && gitq -C "$c" merge -q --no-ff -m merge side && git -C "$c" push -q origin "$HPH" 2>/dev/null
}
# R6: criss-cross. X1 and Y1 from main; main := merge(X1, Y1); the handoff branch := merge(Y1, X1)
# plus the handoff commit (force-pushed), so main and the head have two merge bases.
hp_crisscross() {
  local c="$CS/cc" m
  git clone -q "$CSO" "$c" 2>/dev/null && m="$(git -C "$c" rev-parse origin/main)" \
    && git -C "$c" checkout -q -B x "$m" && echo x > "$c/x.txt" && gitq -C "$c" add x.txt && gitq -C "$c" commit -qm x \
    && git -C "$c" checkout -q -B y "$m" && echo y > "$c/y.txt" && gitq -C "$c" add y.txt && gitq -C "$c" commit -qm y \
    && git -C "$c" checkout -q -B main x && gitq -C "$c" merge -q --no-ff -m mx y && git -C "$c" push -q origin main 2>/dev/null \
    && git -C "$c" checkout -q -B "$HPH" y && gitq -C "$c" merge -q --no-ff -m my x \
    && git -C "$c" checkout -q "origin/$HPH" -- "$HOUT" && gitq -C "$c" commit -qm handoff \
    && git -C "$c" push -q -f origin "$HPH" 2>/dev/null
}

# [smoke] fake "handoff", phase one -> "ok 1 <sha>" and <sha> equals the branch head on origin
sc_hp_ok() {
  hp_lead handoff
  local tip; tip="$(git -C "$CSO" rev-parse "refs/heads/$HPH" 2>/dev/null)"
  expect_eq "$(hp_check one) $([[ -e "$CSU/findings-1.md" ]] && echo findings || echo no-findings)" "ok 1 $tip
rc=0 no-findings" "handoff-pr: fake handoff, phase one -> ok 1 <origin's head of the handoff branch>, no findings file"
}
scenario "handoff-pr: ok" sc_hp_ok

if is_full; then
  sc_hp_files() {
    hp_lead bad-handoff
    expect_eq "$(hp_check one)" "invalid files
rc=0" "handoff-pr: fake bad-handoff -> invalid files"
    grep -F README.md "$CSU/findings-1.md" >/dev/null 2>&1 && ok || nope "handoff-pr: bad-handoff -> the findings file names README.md"
  }
  scenario "handoff-pr: files" sc_hp_files
  sc_hp_lessons() {
    hp_lead handoff "$(printf '%s\n' "$HO" | drop '## 5b. Lessons learned')"
    expect_eq "$(hp_check one)" "invalid missing-section: lessons-learned
rc=0" "handoff-pr: handoff lacking the Lessons section -> invalid missing-section: lessons-learned"
    grep -F 'missing-section: lessons-learned' "$CSU/findings-1.md" >/dev/null 2>&1 && ok || nope "handoff-pr: lessons -> the findings file names the missing section"
  }
  scenario "handoff-pr: lessons" sc_hp_lessons
  sc_hp_entry() {
    hp_lead handoff "$(printf '%s\n' "$HO" | drop '## 6. M2 entry criteria')"
    expect_eq "$(hp_check one)" "invalid missing-entry-criteria: M2
rc=0" "handoff-pr: unit with a dependent, handoff lacking its entry-criteria section -> invalid missing-entry-criteria: M2"
  }
  scenario "handoff-pr: entry criteria" sc_hp_entry
  sc_hp_other_open() {
    hp_lead open-pr-and-handoff
    expect_eq "$(hp_check one)" "invalid other-pr-open
rc=0" "handoff-pr: fake open-pr-and-handoff, phase one -> invalid other-pr-open"
    grep -F '#1' "$CSU/findings-1.md" >/dev/null 2>&1 && ok || nope "handoff-pr: other-pr-open -> the findings file names pull request #1"
  }
  scenario "handoff-pr: other pull request open" sc_hp_other_open
  sc_hp_phase_two() {
    hp_lead handoff "$(printf '%s\n' "$HO" | drop '## 5a. Security review')"
    expect_eq "$(hp_check one)" "ok 1 $(git -C "$CSO" rev-parse "refs/heads/$HPH" 2>/dev/null)
rc=0" "handoff-pr: no Security review, phase one -> ok"
    expect_eq "$(hp_check two)" "invalid missing-section: security-review
rc=0" "handoff-pr: fake handoff, phase two (no Security review yet) -> invalid missing-section: security-review"
    [[ -f "$CSU/findings-1.md" && ! -e "$CSU/findings-2.md" ]] && ok || nope "handoff-pr: the first invalid result writes findings-1.md"
    hp_check two >/dev/null
    [[ -f "$CSU/findings-2.md" ]] && ok || nope "handoff-pr: the next invalid result writes the next findings file"
  }
  scenario "handoff-pr: phase two" sc_hp_phase_two
  sc_hp_pushed() {
    hp_lead handoff "$(printf '%s\n' "$HO" | drop '## 5b. Lessons learned')"
    printf '%s\n' "$HO" > "$CSR/.farm-worktrees/conduct-p-m1/docs/superpowers/handoffs/p-m1-handoff.md"
    expect_eq "$(hp_check one)" "invalid missing-section: lessons-learned
rc=0" "handoff-pr: handoff file differs between the work tree and the pushed head -> the pushed content is validated"
  }
  scenario "handoff-pr: pushed content" sc_hp_pushed
  sc_hp_head_mismatch() {
    hp_lead handoff
    hp_pr1 .
    local c="$CS/pc"
    git clone -q "$CSO" "$c" 2>/dev/null && git -C "$c" checkout -q -B "$HPH" "origin/$HPH" \
      && echo more >> "$c/docs/superpowers/handoffs/p-m1-handoff.md" \
      && gitq -C "$c" commit -qam more && git -C "$c" push -q origin "$HPH" 2>/dev/null
    expect_eq "$(hp_check one)" "invalid head-mismatch
rc=0" "handoff-pr: headRefOid is not origin's tip of the handoff branch -> invalid head-mismatch"
  }
  scenario "handoff-pr: head mismatch" sc_hp_head_mismatch
  sc_hp_cross_repo() {
    hp_lead handoff
    hp_pr1 '.isCrossRepository = true'
    expect_eq "$(hp_check one)" "invalid no-handoff-pr
rc=0" "handoff-pr: a cross-repository pull request on the handoff branch name is not accepted"
  }
  scenario "handoff-pr: cross-repository" sc_hp_cross_repo
  sc_hp_base() {
    hp_lead handoff
    hp_pr1 '.baseRefName = "other"'
    expect_eq "$(hp_check one)" "invalid base
rc=0" "handoff-pr: a handoff pull request into another branch than main -> invalid base"
  }
  scenario "handoff-pr: base branch" sc_hp_base
  # Fix round 1: a validator that fails without a HANDOFF: line is not a pass.
  sc_hp_unvalidated() {
    hp_lead handoff
    expect_eq "$( (cd / && export CONDUCT_DEFINE_ONLY=1 && source "$FARM/bin/farm-conduct.sh" >/dev/null 2>&1 || exit 9
      declare -F conduct_check_handoff_pr >/dev/null || exit 9
      conduct_handoff_validate() { cat >/dev/null; return 1; }
      conduct_check_handoff_pr "$PP" M1 one) </dev/null 2>>"$CS/lead.err"; echo "rc=$?")" "invalid handoff-unvalidated
rc=0" "handoff-pr: the validator fails without a reason -> invalid handoff-unvalidated"
    grep -F handoff-unvalidated "$CSU/findings-1.md" >/dev/null 2>&1 && ok || nope "handoff-pr: handoff-unvalidated -> the findings file names it"
  }
  scenario "handoff-pr: validator fails silently" sc_hp_unvalidated
  # Fix wave F1 (security review probe p1): gh lists a renamed file under its new name only.
  sc_hp_rename() {
    hp_ci_main
    hp_lead handoff
    hp_rename && ok || nope "probe p1: the rename commit is pushed to the handoff branch"
    expect_eq "$(git -C "$CSO" diff -M --name-status "main...$HPH" 2>/dev/null | cut -c1) $(jq -c --arg b "$HPH" '[.[] | select(.headRefName == $b) | .files[].path]' "$CS/gh/prs.json" 2>/dev/null)" \
      "R [\"$HOUT\"]" "handoff-pr: probe p1 setup -> git sees a rename, gh's files list names only HANDOFF_OUT"
    expect_eq "$(hp_check one)" "invalid files
rc=0" "handoff-pr: a protected file renamed into HANDOFF_OUT -> invalid files"
    grep -F "$HPCI" "$CSU/findings-1.md" >/dev/null 2>&1 && ok || nope "handoff-pr: rename -> the findings file names $HPCI"
  }
  scenario "handoff-pr: rename into the handoff (F1)" sc_hp_rename
  sc_hp_delete() {
    hp_lead handoff
    local c="$CS/dl"
    git clone -q "$CSO" "$c" 2>/dev/null && git -C "$c" checkout -q -B "$HPH" "origin/$HPH" \
      && gitq -C "$c" rm -q -- verify.sh && gitq -C "$c" commit -qm del && git -C "$c" push -q origin "$HPH" 2>/dev/null
    gh pr list --state all --search "head:$HPH" --limit 200 --json number >/dev/null   # refresh the fake's head
    hp_pr1 ".files = [{path: $(jq -nc --arg h "$HOUT" '$h')}]"
    expect_eq "$(hp_check one)" "invalid files
rc=0" "handoff-pr: the pull request also deletes verify.sh (gh lists only HANDOFF_OUT) -> invalid files"
    grep -F verify.sh "$CSU/findings-1.md" >/dev/null 2>&1 && ok || nope "handoff-pr: delete -> the findings file names verify.sh"
  }
  scenario "handoff-pr: a deletion beside the handoff" sc_hp_delete
  # Lead ruling R6: one merge base, no merge commits on the handoff branch.
  sc_hp_merge_commit() {
    hp_lead handoff
    hp_merge_commit && ok || nope "R6: the merge commit is pushed to the handoff branch"
    expect_eq "$(git -C "$CSO" rev-list --merges "main..$HPH" 2>/dev/null | wc -l | tr -d ' ') $(git -C "$CSO" diff --no-renames --name-only "main...$HPH" 2>/dev/null)" \
      "1 $HOUT" "handoff-pr: R6 setup -> one merge commit, the diff is still only HANDOFF_OUT"
    expect_eq "$(hp_check one)" "invalid history
rc=0" "handoff-pr: a merge commit on the handoff branch -> invalid history"
    grep -F 'merge commit' "$CSU/findings-1.md" >/dev/null 2>&1 && ok || nope "handoff-pr: merge commit -> the findings file says so"
  }
  scenario "handoff-pr: merge commit on the handoff branch (R6)" sc_hp_merge_commit
  sc_hp_crisscross() {
    hp_lead handoff
    hp_crisscross && ok || nope "R6: the criss-cross history is pushed"
    expect_eq "$(git -C "$CSO" merge-base --all main "$HPH" 2>/dev/null | wc -l | tr -d ' ')" 2 "handoff-pr: R6 setup -> two merge bases"
    expect_eq "$(hp_check one)" "invalid history
rc=0" "handoff-pr: a criss-cross history with two merge bases -> invalid history"
    grep -F 'merge bases' "$CSU/findings-1.md" >/dev/null 2>&1 && ok || nope "handoff-pr: criss-cross -> the findings file names the merge bases"
  }
  scenario "handoff-pr: criss-cross merge bases (R6)" sc_hp_crisscross
fi

# ---- the review session: conduct_verdict_parse, conduct_run_review (section "review") ----
RVA=0123456789abcdef0123456789abcdef01234567
# <jq update> -> a verdict object (unit M1, nonce N, accept, head RVA, counts 0 0 2) with it applied.
rv_json() { jq -cn --arg h "$RVA" '{unit: "M1", nonce: "N", verdict: "accept", head: $h, high: 0, medium: 0, low: 2}' | jq -c "$1"; }
vp() { printf '%s' "$1" | run_fn conduct_verdict_parse N M1; }
expect_eq "$(vp "$(rv_json .)")" "accept 0 0 2 $RVA
rc=0" "review: verdict parse, valid accept with low 2"
expect_eq "$(vp "$(rv_json '.verdict = "reject" | .high = 1 | .low = 0')")" "reject 1 0 0 $RVA
rc=0" "review: verdict parse, reject with high 1"
expect_eq "$(vp "$(rv_json '.nonce = "X"')")" "rc=1" "review: verdict parse, nonce X -> rc 1"
expect_eq "$(vp "$(rv_json '.unit = "M2"')")" "rc=1" "review: verdict parse, unit M2 -> rc 1"
expect_eq "$(vp "$(rv_json '.verdict = "ok"')")" "rc=1" "review: verdict parse, verdict ok -> rc 1"
mkdir -p "$TROOT/vp"
got="$(cd "$TROOT/vp" && vp "$(rv_json '.high = "1; touch PWNED"')")"
expect_eq "$got $([[ -e "$TROOT/vp/PWNED" ]] && echo PWNED || echo clean)" "rc=1 clean" "review: verdict parse, high '1; touch PWNED' -> rc 1, no file PWNED"
expect_eq "$(vp "$(rv_json 'del(.high)')")" "rc=1" "review: verdict parse, high missing -> rc 1"
expect_eq "$(vp "$(rv_json 'del(.head)')")" "rc=1" "review: verdict parse, head missing -> rc 1"
expect_eq "$(vp "$(rv_json '.head = "abc"')")" "rc=1" "review: verdict parse, head abc -> rc 1"
expect_eq "$(vp '')" "rc=1" "review: verdict parse, empty input -> rc 1"
expect_eq "$(vp "[$(rv_json .)]")" "rc=1" "review: verdict parse, an array -> rc 1"
expect_eq "$(vp "$(rv_json .)$(rv_json .)")" "rc=1" "review: verdict parse, two verdicts -> rc 1"
expect_eq "$(vp "$(rv_json '.low = -1')")" "rc=1" "review: verdict parse, a negative count -> rc 1"
expect_eq "$(vp "$(rv_json '.medium = 1.5')")" "rc=1" "review: verdict parse, a fractional count -> rc 1"
expect_eq "$(vp "$(rv_json '.low = 1e11')")" "rc=1" "review: verdict parse, a count of 1e11 -> rc 1"
expect_eq "$(vp "$(rv_json '.high = 1234567890')")" "rc=1" "review: verdict parse, a 10-digit count -> rc 1"
expect_eq "$(vp "$(rv_json '.medium = 123456789')")" "accept 0 123456789 2 $RVA
rc=0" "review: verdict parse, a 9-digit count is accepted"
expect_eq "$(printf '%s' "$(rv_json '.nonce = ""')" | run_fn conduct_verdict_parse '' M1)" "rc=1" "review: verdict parse, an empty nonce never matches"

UR="$FARM/defaults/prompts/unit-review.md"
grep -F -- "already merged" "$UR" >/dev/null 2>&1 && ok || nope "review: unit-review.md contains 'already merged'"
[[ -f "$UR" ]] && ! grep -F -- "/security-review" "$UR" >/dev/null 2>&1 && ok || nope "review: unit-review.md does not contain '/security-review'"
[[ -f "$UR" && "$(wc -l < "$UR" | tr -d ' ')" -le 60 ]] && ok || nope "review: unit-review.md exists, at most 60 lines"
grep -F -- "reject when any High or Medium finding remains" "$UR" >/dev/null 2>&1 && ok \
  || nope "review: unit-review.md says reject when any High or Medium finding remains"
grep -F -- "calls informational" "$UR" >/dev/null 2>&1 && ok \
  || nope "review: unit-review.md makes an informational not-met entry-criteria row a Medium finding"
grep -F -- "level-2 heading \`## Security review\`" "$UR" >/dev/null 2>&1 && ok \
  || nope "review: unit-review.md names the Security review heading level the validator reads"

RVH="$(printf '%s\n' "$HO" | drop '## 5a. Security review')"
# <review action>: the fake's script is "handoff" then that action; runs the lead (start).
rv_lead() {
  printf '%s\n' "$RVH" > "$CS/claude/handoff.md"
  printf 'handoff\n%s\n' "$1" > "$CS/claude/script"
  (cd / && export CONDUCT_DEFINE_ONLY=1 && source "$FARM/bin/farm-conduct.sh" >/dev/null 2>&1 || exit 9
   conduct_run_lead "$PP" M1 start >/dev/null) </dev/null 2>>"$CS/lead.err"
}
# conduct_run_review on pull request 1 at origin's head of the handoff branch; output, then "rc=N".
rv_review() { (cd / && fcs conduct_run_review "$PP" M1 1 "$(git -C "$CSO" rev-parse "refs/heads/$HPH" 2>/dev/null)") 2>>"$CS/lead.err"; }
# <description>: VERDICT_FILE of prompt.2 lies in a /tmp/farm-verdict.* directory that is not in
# $RV_BEFORE (did not exist before the launch) and is gone now.
rv_vdir_fresh_gone() {
  local vf d
  vf="$(ctx_of "$CS/claude/prompt.2" | sed -n 's/^VERDICT_FILE: //p')"; d="${vf%/*}"
  case "$vf" in /tmp/farm-verdict.?*/?*) ;; *) nope "$1: VERDICT_FILE under /tmp/farm-verdict.*: got=[$vf]"; return ;; esac
  printf '%s\n' "$RV_BEFORE" | grep -Fx -- "$d" >/dev/null && { nope "$1: the verdict directory existed before the launch"; return; }
  [[ ! -e "$d" ]] && ok || nope "$1: the verdict directory is removed after the parse"
}

# [smoke] fake "review-accept" -> "accept 0 0 1 <head>"
sc_rv_accept() {
  local got h k ctx sb
  RV_BEFORE="$(ls -d /tmp/farm-verdict.* 2>/dev/null)"
  rv_lead review-accept
  push_file "$CSR" moved.txt moved   # origin's main moves after the lead: RANGE ends at the new tip
  got="$(rv_review)"
  h="$(git -C "$CSO" rev-parse "refs/heads/$HPH" 2>/dev/null)"
  expect_eq "$got" "accept 0 0 1 $h
rc=0" "review: fake review-accept -> accept 0 0 1 <the head the reviewer pushed>"
  ctx="$(ctx_of "$CS/claude/prompt.2")"
  for k in PLAN UNIT UNIT_TITLE MAIN_BRANCH WORKTREE RANGE HANDOFF_PR HANDOFF_HEAD HANDOFF_OUT HANDOFF_BRANCH FINDINGS_FILE VERDICT_FILE NONCE; do
    printf '%s\n' "$ctx" | grep "^$k: ." >/dev/null && ok || nope "review: the review prompt has $k"
  done
  printf '%s\n' "$ctx" | grep -x 'NONCE: [0-9a-f]\{32\}' >/dev/null && ok || nope "review: NONCE is 32 hex characters"
  sb="$(cat "$CSU/start_sha" 2>/dev/null)"
  expect_eq "$(printf '%s\n' "$ctx" | sed -n 's/^RANGE: //p') $([[ "$sb" != "$(git -C "$CSO" rev-parse main)" ]] && echo moved)" \
    "$sb..$(git -C "$CSO" rev-parse main) moved" "review: RANGE is <start_sha>..<origin's main tip after the lead>"
  rv_vdir_fresh_gone "review: accept"
  git -C "$CSO" show "$h:$HOUT" 2>/dev/null | grep '^## .*Security review' >/dev/null && ok \
    || nope "review: the handoff on the branch now has a Security review section"
  expect_eq "$(cat "$CS/claude/cwd.2" 2>/dev/null) $(cat "$CS/claude/head.2" 2>/dev/null)" \
    "$CSR/.farm-worktrees/conduct-review-p-m1 $(git -C "$CSO" rev-parse main)" "review: the review ran in its own work tree, fresh at origin's main tip"
  [[ -f "$CS/claude/cwd.2" && ! -e "$CSR/.farm-worktrees/conduct-review-p-m1" ]] && ok || nope "review: the review work tree is removed afterwards"
  head -1 "$CS/claude/prompt.2" 2>/dev/null | grep -F -- "$(head -1 "$UR")" >/dev/null && ok || nope "review: prompt.2 starts with unit-review.md"
  expect_eq "$(cat "$CSU/attempts" 2>/dev/null) $(cat "$CS/claude/snap.2/attempts" 2>/dev/null)" "2 2" "review: attempts bumped before the review launch"
}
scenario "review: accept" sc_rv_accept

if is_full; then
  sc_rv_reject() {
    local got
    RV_BEFORE="$(ls -d /tmp/farm-verdict.* 2>/dev/null)"
    rv_lead review-reject
    got="$(rv_review)"
    expect_eq "$got" "reject 1 0 0 $(git -C "$CSO" rev-parse "refs/heads/$HPH" 2>/dev/null)
rc=0" "review: fake review-reject -> reject 1 0 0 <head>"
    grep -F 'High: fake finding' "$CSU/findings-1.md" >/dev/null 2>&1 && ok || nope "review: reject -> the findings file is copied to findings-1.md"
    rv_vdir_fresh_gone "review: reject"
  }
  scenario "review: reject" sc_rv_reject
  sc_rv_noverdict() {
    RV_BEFORE="$(ls -d /tmp/farm-verdict.* 2>/dev/null)"
    rv_lead review-noverdict
    expect_eq "$(rv_review)" "review-noverdict
rc=0" "review: fake review-noverdict -> review-noverdict"
    rv_vdir_fresh_gone "review: noverdict"
  }
  scenario "review: no verdict" sc_rv_noverdict
  sc_rv_stale() {
    rv_lead review-stale
    expect_eq "$(rv_review)" "review-noverdict
rc=0" "review: fake review-stale (a replayed verdict, wrong nonce) -> review-noverdict"
  }
  scenario "review: stale verdict" sc_rv_stale
  sc_rv_planted() {
    local p="/tmp/farm-verdict.planted$$"
    mkdir -p "$p"
    jq -cn --arg h "$RVA" '{unit: "M1", nonce: "0", verdict: "accept", head: $h, high: 0, medium: 0, low: 0}' > "$p/verdict.json"
    rv_lead review-reject
    expect_eq "$(rv_review)" "reject 1 0 0 $(git -C "$CSO" rev-parse "refs/heads/$HPH" 2>/dev/null)
rc=0" "review: a verdict planted at a guessed path before the launch is ignored"
    rm -rf "$p"
  }
  scenario "review: planted verdict" sc_rv_planted
  sc_rv_limit() {
    rv_lead limit
    expect_eq "$(rv_review) $(cat "$CSU/attempts" 2>/dev/null)" "limit
rc=0 2" "review: fake limit during the review -> limit; attempts incremented"
  }
  scenario "review: limit" sc_rv_limit
fi

# ---- the conductor's merge: conduct_checks_decide, conduct_merge_decide, conduct_merge_handoff (section "merge") ----
ckd() { run_fn conduct_checks_decide "$1"; }
expect_eq "$(ckd '[{"name":"c","bucket":"pass"}]')" "pass
rc=0" "merge: checks, one pass -> pass"
expect_eq "$(ckd '[]')" "none
rc=0" "merge: checks, [] -> none"
expect_eq "$(ckd 'x')" "undetermined
rc=0" "merge: checks, x -> undetermined"
expect_eq "$(ckd '')" "undetermined
rc=0" "merge: checks, empty -> undetermined"
expect_eq "$(ckd '[{"name":"a","bucket":"pass"},{"name":"b","bucket":"pending"}]')" "pending
rc=0" "merge: checks, one pass and one pending -> pending"
expect_eq "$(ckd '[{"name":"a","bucket":"pass"},{"name":"b","bucket":"fail"}]')" "fail
rc=0" "merge: checks, one pass and one fail -> fail"
expect_eq "$(ckd '[{"name":"a","bucket":"skipping"}]')" "fail
rc=0" "merge: checks, one skipping -> fail"
expect_eq "$(ckd '[{"name":"a","bucket":"cancel"}]')" "fail
rc=0" "merge: checks, one cancel -> fail"
expect_eq "$(ckd '[{"name":"a","bucket":"pass"},{"name":"b","bucket":"weird"}]')" "undetermined
rc=0" "merge: checks, an unknown bucket -> undetermined"
expect_eq "$(ckd '[{"name":"a"}]')" "undetermined
rc=0" "merge: checks, no bucket -> undetermined"
mgd() { run_fn conduct_merge_decide "$@"; }
expect_eq "$(mgd accept 0 0 ok none pass pass)" "merge
rc=0" "merge: decide accept 0 0 ok none pass pass -> merge"
expect_eq "$(mgd accept 0 1 ok none pass pass)" "rework
rc=0" "merge: decide accept with a medium finding -> rework"
expect_eq "$(mgd accept 1 0 ok none pass pass)" "rework
rc=0" "merge: decide accept with a high finding -> rework"
expect_eq "$(mgd reject 0 0 ok none pass pass)" "rework
rc=0" "merge: decide reject -> rework"
expect_eq "$(mgd accept 0 0 invalid none pass pass)" "rework
rc=0" "merge: decide handoff invalid -> rework"
expect_eq "$(mgd accept 0 0 ok open pass pass)" "rework
rc=0" "merge: decide others open -> rework"
expect_eq "$(mgd accept 0 0 ok protected pass pass)" "await-merge
rc=0" "merge: decide others protected -> await-merge"
expect_eq "$(mgd reject 1 1 invalid protected fail fail)" "await-merge
rc=0" "merge: decide others protected outranks a reject"
expect_eq "$(mgd accept 0 0 ok none fail pass)" "rework
rc=0" "merge: decide verify fail -> rework"
expect_eq "$(mgd accept 0 0 ok none timeout pass)" "rework
rc=0" "merge: decide verify timeout -> rework"
expect_eq "$(mgd accept 0 0 ok none pass fail)" "rework
rc=0" "merge: decide checks fail -> rework"
for c in pending none undetermined; do
  expect_eq "$(mgd accept 0 0 ok none pass "$c")" "wait
rc=0" "merge: decide checks $c -> wait"
done
expect_eq "$(mgd accept x 0 ok none pass pass)" "stop:invalid-state
rc=0" "merge: decide high x -> stop:invalid-state"
expect_eq "$(mgd ok 0 0 ok none pass pass)" "stop:invalid-state
rc=0" "merge: decide verdict ok -> stop:invalid-state"
expect_eq "$(mgd accept 0 0 maybe none pass pass)" "stop:invalid-state
rc=0" "merge: decide an unknown handoff word -> stop:invalid-state"
expect_eq "$(mgd accept 0 0 ok some pass pass)" "stop:invalid-state
rc=0" "merge: decide an unknown others word -> stop:invalid-state"
expect_eq "$(mgd accept 0 0 ok none passed pass)" "stop:invalid-state
rc=0" "merge: decide an unknown verify word -> stop:invalid-state"
expect_eq "$(mgd accept 0 0 ok none pass green)" "stop:invalid-state
rc=0" "merge: decide an unknown checks word -> stop:invalid-state"
expect_eq "$(mgd accept 0 0 ok protected pass)" "stop:invalid-state
rc=0" "merge: decide a missing checks word -> stop:invalid-state"

# Ruling R3 / fix round 1: the poll knob is ^[1-9][0-9]{0,8}$, else 30; the timeout knob ^[0-9]{1,9}$, else 2700.
kn() { (export CONDUCT_DEFINE_ONLY=1 CONDUCT_CHECKS_POLL_SECONDS="$1" CONDUCT_CHECKS_TIMEOUT_SECONDS="$1"
  source "$FARM/bin/farm-conduct.sh" >/dev/null 2>&1 || exit 9
  echo "$CONDUCT_CHECKS_POLL_SECONDS/$CONDUCT_CHECKS_TIMEOUT_SECONDS") </dev/null; }
expect_eq "$(kn 0) $(kn x) $(kn 5) $(kn 1234567890)" "30/0 30/2700 5/5 30/2700" "merge: knobs, poll 0 or junk -> 30; timeout junk or 10 digits -> 2700"

MGH="$RVH

## 5. Operator actions pending

- Rotate the fake token."
# <script words...>: the fake's script; every word but the last runs as one lead session (start,
# then continue), the last as the review. The review's verdict line goes to $CS/verdict.
mg_prep() {
  local i=1 mode=start
  printf '%s\n' "$MGH" > "$CS/claude/handoff.md"
  printf '%s\n' "$@" > "$CS/claude/script"
  while (( i < $# )); do
    (cd / && export CONDUCT_DEFINE_ONLY=1 && source "$FARM/bin/farm-conduct.sh" >/dev/null 2>&1 || exit 9
     conduct_run_lead "$PP" M1 "$mode" >/dev/null) </dev/null 2>>"$CS/lead.err"
    mode="continue"; i=$((i + 1))
  done
  (cd / && fcs conduct_run_review "$PP" M1 "$(mg_pr)" "$(git -C "$CSO" rev-parse "refs/heads/$HPH" 2>/dev/null)") 2>>"$CS/lead.err" \
    | sed '$d' > "$CS/verdict"
}
mg_pr() { jq -r --arg b "$HPH" '[.[] | select(.headRefName == $b) | .number][0] // empty' "$CS/gh/prs.json" 2>/dev/null; }
# Output, then "rc=N"; the output's first line is also kept in $CS/merge.out for mg_not_merged.
mg_merge() {
  (cd / && fcs conduct_merge_handoff "$PP" M1 "$(mg_pr)" "$(cat "$CS/verdict" 2>/dev/null)") 2>>"$CS/lead.err" | tee "$CS/merge.out"
}
# stdout: "outcome" when $CS/merge.out starts with an outcome other than merged, else what it holds
# (so no assertion built on it passes with conduct_merge_handoff missing: lesson 34).
mg_outcome() {
  local o; o="$(head -1 "$CS/merge.out" 2>/dev/null)"
  case "$o" in review-reject|handoff-invalid|awaiting-merge|checks-timeout|merge-failed) echo outcome ;; *) echo "no-outcome:$o" ;; esac
}
# <description>: an outcome was printed, the handoff is not on origin's main, the pull request is
# still open, no unit-shipped event and no review record; one assertion.
mg_not_merged() {
  expect_eq "$(mg_outcome) $(git -C "$CSO" cat-file -e "main:$HOUT" 2>/dev/null && echo on-main || echo not-on-main) $(jq -r --arg b "$HPH" '.[] | select(.headRefName == $b) | .state' "$CS/gh/prs.json" 2>/dev/null) $(grep unit-shipped "$CS/notify.log" >/dev/null 2>&1 && echo shipped || echo no-event) $([[ -s "$CDIR/reviews.jsonl" ]] && echo record || echo no-record)" \
    "outcome not-on-main OPEN no-event no-record" "$1: not merged (handoff not on main, pull request open, no unit-shipped, no review record)"
}
# stdout: the unit's newest findings file's text.
mg_findings() {
  local f n=0 k
  for f in "$CSU"/findings-*.md; do k="${f##*/findings-}"; k="${k%.md}"; [[ "$k" =~ ^[0-9]+$ ]] && (( k > n )) && n=$k; done
  cat "$CSU/findings-$n.md" 2>/dev/null
}
# <work tree path>: push one commit changing <file> to the handoff branch on origin.
mg_push_branch() {
  local c="$CS/pb"
  [[ -d "$c" ]] || git clone -q "$CSO" "$c" 2>/dev/null
  git -C "$c" fetch -q origin && git -C "$c" checkout -q -B "$HPH" "origin/$HPH" \
    && echo more >> "$c/$1" && gitq -C "$c" add -- "$1" && gitq -C "$c" commit -qm more && git -C "$c" push -q origin "$HPH" 2>/dev/null
}

# [smoke] happy path after "handoff" and "review-accept" -> merged
sc_mg_happy() {
  local vh got
  mg_prep handoff review-accept
  vh="$(awk '{ print $5 }' "$CS/verdict")"
  got="$(mg_merge)"
  expect_eq "$got" "merged
rc=0" "merge: happy path -> merged"
  git -C "$CSO" cat-file -e "main:$HOUT" 2>/dev/null && ok || nope "merge: happy path -> the handoff is on origin's main"
  expect_eq "$(wc -l < "$CDIR/reviews.jsonl" 2>/dev/null | tr -d ' ')" 1 "merge: reviews.jsonl has one line"
  expect_eq "$(jq -c 'keys' "$CDIR/reviews.jsonl" 2>/dev/null)" \
    '["end_sha","high","log_path","low","medium","plan","review_session_id","start_sha","ts","unit","verdict"]' "merge: the review record has the eleven fields"
  expect_eq "$(jq -r '[.plan, .unit, .start_sha, .end_sha, .review_session_id, .verdict, .high, .medium, .low] | map(tostring) | join(" ")' "$CDIR/reviews.jsonl" 2>/dev/null)" \
    "$PP M1 $(cat "$CSU/start_sha" 2>/dev/null) $(git -C "$CSO" rev-parse main) 00000000-0000-0000-0000-000000000002 accept 0 0 1" "merge: the review record's values"
  [[ -f "$(jq -r '.log_path' "$CDIR/reviews.jsonl" 2>/dev/null)" ]] && ok || nope "merge: the review record's log_path is a file"
  expect_eq "$(cat "$CS/notify.log" 2>/dev/null)" "unit-shipped $PP M1" "merge: notify.log has exactly one line, unit-shipped"
  grep "unit-shipped $PP M1\$" "$CDIR/notifications.log" >/dev/null 2>&1 && ok || nope "merge: notifications.log has the unit-shipped event"
  expect_eq "$(cat "$CS/notify.records" 2>/dev/null)" 1 "merge: the review record was written before the unit-shipped event"
  grep -F 'Rotate the fake token.' "$CS/notify.stdin" >/dev/null 2>&1 && ok || nope "merge: notify.stdin held the Operator actions pending text"
  expect_eq "$(jq -s -c '[.[] | select(.role == "verify" and .phase == "pre-merge") | .outcome]' "$CDIR/usage.jsonl" 2>/dev/null)" '["pass"]' \
    "merge: usage.jsonl has one pre-merge verify line, outcome pass"
  [[ -e "$CS/claude/cwd.1" && ! -e "$CSR/.farm-worktrees/conduct-p-m1" && ! -e "$CSR/.farm-worktrees/conduct-review-p-m1" ]] && ok \
    || nope "merge: both work trees are removed"
  grep -x -- --squash "$CS/gh/merge.argv" >/dev/null 2>&1 && ok || nope "merge: gh pr merge argv has --squash"
  expect_eq "$(awk 'p { print; exit } $0 == "--match-head-commit" { p = 1 }' "$CS/gh/merge.argv" 2>/dev/null)" "$vh" \
    "merge: gh pr merge argv has --match-head-commit <the verdict's head>"
  [[ -f "$CS/gh/merge.argv" ]] && ! grep -x -e --admin -e --auto "$CS/gh/merge.argv" >/dev/null 2>&1 && ok || nope "merge: gh pr merge argv has no --admin, no --auto"
  [[ ! -e "$CS/gh/unknown.log" ]] && ok || nope "merge: no unknown gh call: $(cat "$CS/gh/unknown.log" 2>/dev/null)"
}
scenario "merge: happy path" sc_mg_happy

if is_full; then
  sc_mg_reject() {
    mg_prep handoff review-reject
    expect_eq "$(mg_merge)" "review-reject
rc=0" "merge: fake review-reject -> review-reject"
    expect_eq "$(jq -s -c '[.[] | select(.role == "verify" and .phase == "pre-merge")] | length' "$CDIR/usage.jsonl" 2>/dev/null)" 0 \
      "merge: review-reject -> no pre-merge verify line"
    mg_not_merged "merge: review-reject"
  }
  scenario "merge: review-reject" sc_mg_reject
  sc_mg_break_verify() {
    mg_prep break-verify handoff review-accept
    expect_eq "$(mg_merge)" "handoff-invalid
rc=0" "merge: script break-verify handoff review-accept -> handoff-invalid"
    mg_findings | grep -F VERIFY-BROKEN >/dev/null && ok || nope "merge: break-verify -> the findings hold the verify log's tail"
    expect_eq "$(jq -s -c '[.[] | select(.role == "verify" and .phase == "pre-merge") | .outcome]' "$CDIR/usage.jsonl" 2>/dev/null)" '["fail"]' \
      "merge: break-verify -> one pre-merge verify line, outcome fail"
    mg_not_merged "merge: break-verify"
  }
  scenario "merge: pre-merge verify fails" sc_mg_break_verify
  # Review Focus 2: a required check that never reports.
  sc_mg_no_checks() {
    local t0 dt got
    mg_prep handoff review-accept
    echo '[]' > "$CS/gh/checks.json"
    t0=$SECONDS; got="$(mg_merge)"; dt=$((SECONDS - t0))
    expect_eq "$got" "checks-timeout
rc=0" "merge: checks [] for the whole wait -> checks-timeout"
    [[ "$dt" -lt 120 ]] && ok || nope "merge: checks-timeout within 120 s: took ${dt}s"
    mg_not_merged "merge: checks-timeout"
  }
  scenario "merge: required checks never report" sc_mg_no_checks
  sc_mg_checks_fail() {
    mg_prep handoff review-accept
    echo '[{"name":"ci","bucket":"pass"},{"name":"lint-x","bucket":"fail"}]' > "$CS/gh/checks.json"
    expect_eq "$(mg_merge)" "handoff-invalid
rc=0" "merge: a failing required check -> handoff-invalid"
    mg_findings | grep -F lint-x >/dev/null && ok || nope "merge: a failing required check -> the findings name it"
    mg_not_merged "merge: checks fail"
  }
  scenario "merge: a required check fails" sc_mg_checks_fail
  sc_mg_checks_pending() {
    local t0 dt
    mg_prep handoff review-accept
    echo '[{"name":"ci","bucket":"pending"}]' > "$CS/gh/checks.json"
    ( sleep 2; echo '[{"name":"ci","bucket":"pass"}]' > "$CS/gh/checks.json.t" && mv "$CS/gh/checks.json.t" "$CS/gh/checks.json" ) </dev/null >/dev/null 2>&1 &
    t0=$SECONDS
    expect_eq "$(CONDUCT_CHECKS_TIMEOUT_SECONDS=120 mg_merge)" "merged
rc=0" "merge: checks pending for 2 s, then pass -> merged"
    dt=$((SECONDS - t0))
    [[ "$dt" -ge 2 ]] && ok || nope "merge: the merge waited for the pending check: took ${dt}s"
  }
  scenario "merge: checks pending, then pass" sc_mg_checks_pending
  # Review Focus 3: the handoff branch moves after the verdict, or the pull request gains a file.
  sc_mg_head_moved() {
    mg_prep handoff review-accept
    mg_push_branch "$HOUT"
    expect_eq "$(mg_merge)" "handoff-invalid
rc=0" "merge: a commit pushed to HANDOFF_BRANCH after the verdict -> handoff-invalid"
    mg_findings | grep -F 'head moved after the review' >/dev/null && ok || nope "merge: head moved -> the findings say so"
    mg_not_merged "merge: head moved"
  }
  scenario "merge: head moved after the review" sc_mg_head_moved
  sc_mg_second_file() {
    mg_prep handoff review-accept
    mg_push_branch README.md
    expect_eq "$(mg_merge)" "handoff-invalid
rc=0" "merge: a second file pushed to the pull request after the review -> handoff-invalid"
    mg_not_merged "merge: second file pushed"
  }
  scenario "merge: second file pushed" sc_mg_second_file
  sc_mg_second_file_stale() {
    mg_prep handoff review-accept
    gh pr list --state all --search "head:$HPH" --limit 200 --json number >/dev/null   # refresh the fake's head
    hp_pr1 '.files += [{path: "README.md"}]'
    expect_eq "$(mg_merge)" "handoff-invalid
rc=0" "merge: the pull request lists a second file at the reviewed head -> handoff-invalid"
    mg_findings | grep -F README.md >/dev/null && ok || nope "merge: a second file -> the findings name it"
    mg_not_merged "merge: second file listed"
  }
  scenario "merge: second file listed" sc_mg_second_file_stale
  # Fix wave F1, the twin of "handoff-pr: rename into the handoff": probe p1 up to the merge.
  sc_mg_rename() {
    hp_ci_main
    printf '%s\n' "$MGH" > "$CS/claude/handoff.md"; printf '%s\n' handoff review-accept > "$CS/claude/script"
    (cd / && export CONDUCT_DEFINE_ONLY=1 && source "$FARM/bin/farm-conduct.sh" >/dev/null 2>&1 || exit 9
     conduct_run_lead "$PP" M1 start >/dev/null) </dev/null 2>>"$CS/lead.err"
    hp_rename && ok || nope "probe p1: the rename commit is pushed to the handoff branch"
    (cd / && fcs conduct_run_review "$PP" M1 "$(mg_pr)" "$(git -C "$CSO" rev-parse "refs/heads/$HPH" 2>/dev/null)") 2>>"$CS/lead.err" \
      | sed '$d' > "$CS/verdict"
    expect_eq "$(cut -d' ' -f1-3 "$CS/verdict" 2>/dev/null)" "accept 0 0" "merge: rename probe -> the review accepts"
    expect_eq "$(mg_merge)" "handoff-invalid
rc=0" "merge: a protected file renamed into HANDOFF_OUT, accepted by the review -> handoff-invalid"
    git -C "$CSO" cat-file -e "main:$HPCI" 2>/dev/null && ok || nope "merge: rename probe -> $HPCI is still on origin's main"
    mg_not_merged "merge: rename probe"
  }
  scenario "merge: rename into the handoff (F1)" sc_mg_rename
  # Lead ruling R6, the twin of "handoff-pr: merge commit on the handoff branch".
  sc_mg_merge_commit() {
    printf '%s\n' "$MGH" > "$CS/claude/handoff.md"; printf '%s\n' handoff review-accept > "$CS/claude/script"
    (cd / && export CONDUCT_DEFINE_ONLY=1 && source "$FARM/bin/farm-conduct.sh" >/dev/null 2>&1 || exit 9
     conduct_run_lead "$PP" M1 start >/dev/null) </dev/null 2>>"$CS/lead.err"
    hp_merge_commit && ok || nope "R6: the merge commit is pushed to the handoff branch"
    (cd / && fcs conduct_run_review "$PP" M1 "$(mg_pr)" "$(git -C "$CSO" rev-parse "refs/heads/$HPH" 2>/dev/null)") 2>>"$CS/lead.err" \
      | sed '$d' > "$CS/verdict"
    expect_eq "$(cut -d' ' -f1-3 "$CS/verdict" 2>/dev/null)" "accept 0 0" "merge: R6 merge commit -> the review accepts"
    expect_eq "$(mg_merge)" "handoff-invalid
rc=0" "merge: a merge commit on the handoff branch, accepted by the review -> handoff-invalid"
    mg_findings | grep -F 'merge commit' >/dev/null && ok || nope "merge: R6 merge commit -> the findings say so"
    mg_not_merged "merge: R6 merge commit"
  }
  scenario "merge: merge commit on the handoff branch (R6)" sc_mg_merge_commit
  sc_mg_other_open() {
    mg_prep handoff review-accept
    ev_pr conduct/p/m1/late 1 src
    expect_eq "$(mg_merge)" "handoff-invalid
rc=0" "merge: a pull request under the prefix opened after phase one -> handoff-invalid"
    mg_not_merged "merge: other pull request open"
  }
  scenario "merge: other pull request open" sc_mg_other_open
  sc_mg_other_protected() {
    mg_prep handoff review-accept
    ev_pr conduct/p/m1/prot 1 .claude
    expect_eq "$(mg_merge)" "awaiting-merge
rc=0" "merge: a protected pull request under the prefix opened after phase one -> awaiting-merge"
    mg_not_merged "merge: protected pull request open"
  }
  scenario "merge: protected pull request open" sc_mg_other_protected
  sc_mg_merge_fails() {
    mg_prep handoff review-accept
    : > "$CS/gh/fail.merge"
    expect_eq "$(mg_merge)" "merge-failed
rc=0" "merge: gh pr merge fails -> merge-failed"
    mg_not_merged "merge: merge-failed"
  }
  scenario "merge: gh pr merge fails" sc_mg_merge_fails
  # Review finding on M3b.2: a gh outage must not spend the rework round.
  sc_mg_gh_down() {
    mg_prep handoff review-accept
    : > "$CS/gh/fail.list"
    expect_eq "$(mg_merge)" "merge-failed
rc=0" "merge: gh cannot list the pull requests -> merge-failed, not handoff-invalid"
    mg_not_merged "merge: gh down"
  }
  scenario "merge: gh outage" sc_mg_gh_down
  sc_mg_branch_gone() {
    mg_prep handoff review-accept
    git -C "$CSO" update-ref -d "refs/heads/$HPH"
    expect_eq "$(mg_merge)" "merge-failed
rc=0" "merge: ls-remote returns no handoff branch tip -> merge-failed, not handoff-invalid"
    mg_not_merged "merge: handoff branch gone"
  }
  scenario "merge: handoff branch gone" sc_mg_branch_gone
  # Fix round 1, review item 1: merged by someone else at another head is not the reviewed merge.
  sc_mg_foreign() {
    mg_prep handoff review-accept
    cat "$CSU/start_sha" > "$CS/gh/merge.foreign"
    expect_eq "$(mg_merge | head -1) $([[ -s "$CDIR/reviews.jsonl" ]] && echo record || echo no-record) $(grep unit-shipped "$CS/notify.log" >/dev/null 2>&1 && echo shipped || echo no-event)" \
      "merge-failed no-record no-event" "merge: gh pr merge fails, the pull request is MERGED at a moved head -> merge-failed, no record, no unit-shipped"
  }
  scenario "merge: merged at a foreign head" sc_mg_foreign
  # Fix round 1, review item 2: unit-shipped only with a written review record.
  sc_mg_record_fails() {
    mg_prep handoff review-accept
    mkdir -p "$CDIR/reviews.jsonl"
    expect_eq "$(mg_merge | head -1) $(grep unit-shipped "$CS/notify.log" "$CDIR/notifications.log" >/dev/null 2>&1 && echo shipped || echo no-event)" \
      "merge-failed no-event" "merge: the review record cannot be written -> merge-failed, no unit-shipped"
  }
  scenario "merge: review record unwritable" sc_mg_record_fails
  # Fix round 1, review item 6: a step that dies still ends in an outcome, and no merge.
  sc_mg_verify_dies() {
    mg_prep handoff review-accept
    (cd / && export CONDUCT_DEFINE_ONLY=1 && source "$FARM/bin/farm-conduct.sh" >/dev/null 2>&1 || exit 9
     declare -F conduct_merge_handoff >/dev/null || exit 9
     conduct_run_verify() { exit 3; }
     conduct_merge_handoff "$PP" M1 "$(mg_pr)" "$(cat "$CS/verdict")") </dev/null 2>>"$CS/lead.err" > "$CS/merge.out"
    expect_eq "$(head -1 "$CS/merge.out")" merge-failed "merge: conduct_run_verify dies -> merge-failed"
    mg_not_merged "merge: verify dies"
  }
  scenario "merge: verify dies" sc_mg_verify_dies
  sc_mg_phase_two_dies() {
    mg_prep handoff review-accept
    (cd / && export CONDUCT_DEFINE_ONLY=1 && source "$FARM/bin/farm-conduct.sh" >/dev/null 2>&1 || exit 9
     declare -F conduct_merge_handoff >/dev/null || exit 9
     conduct_check_handoff_pr() { exit 1; }
     conduct_merge_handoff "$PP" M1 "$(mg_pr)" "$(cat "$CS/verdict")") </dev/null 2>>"$CS/lead.err" > "$CS/merge.out"
    expect_eq "$(head -1 "$CS/merge.out")" merge-failed "merge: conduct_check_handoff_pr dies -> merge-failed"
    mg_not_merged "merge: phase two dies"
  }
  scenario "merge: phase two dies" sc_mg_phase_two_dies
fi

# ---- one unit: conduct_run_start_decide, farmctl conduct run (section "one unit") ----
rsd() { run_fn conduct_run_start_decide "$@" </dev/null; }
expect_eq "$(rsd shipped '' 0)" "refuse:already-shipped
rc=0" "unit: start decide, shipped -> refuse:already-shipped"
expect_eq "$(rsd shipped '' 1)" "refuse:already-shipped
rc=0" "unit: start decide, shipped with an answer -> refuse:already-shipped"
expect_eq "$(rsd shipped-unreviewed '' 0)" "refuse:shipped-unreviewed
rc=0" "unit: start decide, shipped-unreviewed -> refuse:shipped-unreviewed"
expect_eq "$(rsd escalated cap-rework 0)" "refuse:stopped
rc=0" "unit: start decide, escalated without an answer -> refuse:stopped"
expect_eq "$(rsd escalated cap-rework 1)" "answer
rc=0" "unit: start decide, escalated with an answer -> answer"
expect_eq "$(rsd ready '' 1)" "refuse:no-answer-needed
rc=0" "unit: start decide, an answer for a unit that is not stopped -> refuse:no-answer-needed"
expect_eq "$(rsd doing 'awaiting-operator-merge: #1' 1)" "refuse:no-answer-needed
rc=0" "unit: start decide, an answer while awaiting a merge -> refuse:no-answer-needed"
expect_eq "$(rsd doing 'awaiting-operator-merge: #1' 0)" "awaiting
rc=0" "unit: start decide, doing and awaiting-operator-merge -> awaiting"
expect_eq "$(rsd doing '' 0)" "restart
rc=0" "unit: start decide, doing without a stop reason -> restart"
expect_eq "$(rsd review '' 0)" "restart
rc=0" "unit: start decide, review -> restart"
expect_eq "$(rsd ready '' 0)" "start
rc=0" "unit: start decide, ready -> start"
expect_eq "$(rsd backlog '' 0)" "start
rc=0" "unit: start decide, backlog -> start (preflight refuses its dependencies)"
expect_eq "$(rsd bogus '' 0)" "refuse:stopped
rc=0" "unit: start decide, an unknown status -> refuse:stopped"

# stdout: the number of fake claude invocations so far.
cs_inv() { local k=0; while [[ -e "$CS/claude/argv.$((k + 1))" ]]; do k=$((k + 1)); done; echo "$k"; }
# <unit> <action words...>: the fake's script gets these words for its next invocations (the lines of
# earlier invocations are kept), then `farmctl conduct run $PP <unit>`, with --answer "$CS_ANSWER" when
# that is set; output in $CS/run.out. stdout: the exit code.
cs_run() {
  local u="$1" k s="$CS/claude/script" a=()
  shift; k="$(cs_inv)"
  { awk -v k="$k" 'NR <= k' "$s" 2>/dev/null; i=0; while (( i < k )); do echo nothing; i=$((i + 1)); done; } \
    | awk -v k="$k" 'NR <= k' > "$s.t"
  printf '%s\n' "$@" >> "$s.t"; mv -f "$s.t" "$s"
  [[ -z "${CS_ANSWER+set}" ]] || a=(--answer "$CS_ANSWER")
  [[ "$u" == plan ]] || a=("$u" ${a[@]+"${a[@]}"})   # plan: the plan loop, no unit argument
  (cd / && env -u MAIN_BRANCH -u REPO_DIR CLAUDE_PROJECT_DIR=/some/other/repo \
     "$BASH" "$FARM/bin/farmctl" conduct run "$PP" ${a[@]+"${a[@]}"} </dev/null >"$CS/run.out" 2>&1); echo "$?"
  cat "$CS/run.out" >> "$CS/run.all"
}
# <dir>: "rework continuation interruption" read from it, an absent counter as 0.
cs_ctr() { local c v o=""; for c in rework continuation interruption; do v="$(cat "$1/$c" 2>/dev/null)"; o="$o ${v:-0}"; done; echo "${o# }"; }
# <jq filter>: applied to the M1 row of farmctl conduct status --json.
cs_row() { (cd / && "$BASH" "$FARM/bin/farmctl" conduct status "$PP" --json </dev/null 2>/dev/null) | jq -r ".[0] | $1" 2>/dev/null; }
cs_on_main() { git -C "$CSO" cat-file -e "main:$HOUT" 2>/dev/null && echo on-main || echo not-on-main; }
# <description> <events...>: one assertion: the run printed no usage text, notify.log holds exactly
# these events ("<event> $PP M1", in order), notifications.log the same, the event pause appears
# nowhere (U) and the fake gh logged no unknown call.
cs_events() {
  local d="$1" want; shift
  want="$(for e in "$@"; do printf '%s %s M1\n' "$e" "$PP"; done)"
  expect_eq "$(grep -F 'usage: farmctl conduct' "$CS/run.out" >/dev/null 2>&1 && echo usage || echo run)|$(cat "$CS/notify.log" 2>/dev/null)|$(sed 's/^[^ ]* //' "$CDIR/notifications.log" 2>/dev/null)|pause $(cat "$CS/notify.log" "$CDIR/notifications.log" 2>/dev/null | grep -c ' pause ')|$(cat "$CS/gh/unknown.log" 2>/dev/null)" \
    "run|$want|$want|pause 0|" "$d: events"
}

# [smoke] A: handoff review-accept
sc_unit_a() {
  printf '%s\n' "$MGH" > "$CS/claude/handoff.md"
  expect_eq "$(cs_run M1 handoff review-accept) $(cs_row .status) $(cs_ctr "$CSU") $(cat "$CSU/attempts" 2>/dev/null)" "0 shipped 0 0 0 2" \
    "unit: A handoff review-accept -> exit 0, shipped, counters 0 0 0, attempts 2"
  expect_eq "$(jq -s -c '[.[] | select(.role == "verify") | .phase]' "$CDIR/usage.jsonl" 2>/dev/null)" '["preflight","pre-merge"]' \
    "unit: A usage.jsonl has two verify lines, preflight and pre-merge"
  expect_eq "$(cs_on_main) $([[ -e "$CDIR/lock" ]] && echo locked || echo unlocked)" "on-main unlocked" "unit: A the handoff is on main and the lock is released"
  cs_events "unit: A" unit-shipped
}
scenario "unit: A" sc_unit_a

# [smoke] C: handoff review-reject handoff review-reject (then M, K and K2 in the full tier)
sc_unit_c() {
  printf '%s\n' "$MGH" > "$CS/claude/handoff.md"
  expect_eq "$(cs_run M1 handoff review-reject handoff review-reject) $(cs_row .status) $(cs_row .stop_reason) $(cs_on_main)" \
    "3 escalated cap-rework not-on-main" "unit: C two rejections -> exit 3, escalated, cap-rework, the handoff is not on main"
  cs_events "unit: C" stop
  if is_full; then
    # M: the rework counter was written before the launch it counts.
    expect_eq "$(cat "$CS/claude/snap.3/rework" 2>/dev/null) $(grep -x 'MODE: rework' "$CS/claude/prompt.3" 2>/dev/null)" "1 MODE: rework" \
      "unit: M snap.3/rework reads 1"
    # K: no answer -> refused, the stop reason printed, no invocation.
    expect_eq "$(cs_run M1) $(grep -c cap-rework "$CS/run.out") $(cs_inv)" "1 1 4" "unit: K a stopped unit without --answer -> exit 1, the stop reason, no invocation"
    cs_events "unit: K" stop
    # K2: an answer resets the three counters; attempts keep growing.
    local af
    expect_eq "$(CS_ANSWER="use approach B" cs_run M1 handoff review-accept) $(cs_ctr "$CS/claude/snap.5") $(cat "$CS/claude/snap.5/attempts" 2>/dev/null)" \
      "0 0 0 0 5" "unit: K2 --answer -> exit 0; counters 0 0 0 and attempts 5 at the first new launch"
    af="$(ctx_of "$CS/claude/prompt.5" | sed -n 's/^OPERATOR_ANSWER_FILE: //p')"
    expect_eq "$(cat "$af" 2>/dev/null)" "use approach B" "unit: K2 OPERATOR_ANSWER_FILE holds exactly the answer"
    cs_events "unit: K2" stop unit-shipped
  fi
}
scenario "unit: C" sc_unit_c

# [smoke] D: limit handoff review-accept, the gate opened by cs_open_gate
sc_unit_d() {
  printf '%s\n' "$MGH" > "$CS/claude/handoff.md"
  cs_open_gate
  expect_eq "$(cs_run M1 limit handoff review-accept) $(cs_ctr "$CSU")" "0 0 0 1" "unit: D limit, then shipped -> exit 0, interruption 1"
  cs_events "unit: D" limit unit-shipped
}
scenario "unit: D" sc_unit_d

# [smoke] H: protected-pr (then H2 and H3 in the full tier)
sc_unit_h() {
  expect_eq "$(cs_run M1 protected-pr) $(cs_row .status) $(cs_ctr "$CSU")" "3 doing 0 0 0" "unit: H protected-pr -> exit 3, doing, counters 0 0 0"
  case "$(cs_row .stop_reason)" in awaiting-operator-merge*) ok ;; *) nope "unit: H stop_reason starts awaiting-operator-merge: [$(cs_row .stop_reason)]" ;; esac
  cs_events "unit: H" awaiting-operator-merge
  if is_full; then
    # Plan loop row (M4.2) on H's fixture: the loop meets a unit still waiting on its protected pull request.
    expect_eq "$(cs_run plan handoff) $(grep '#1' "$CS/run.out" >/dev/null && echo named) $(cs_inv)" "3 named 1" \
      "loop: a unit still waiting on an open protected pull request -> exit 3, names it, no invocation"
    cs_events "loop: still waiting" awaiting-operator-merge
    expect_eq "$(cs_run M1 handoff) $(grep -c '#1' "$CS/run.out") $(cs_inv)" "1 1 1" "unit: H2 the protected pull request still open -> exit 1 naming #1, no invocation"
    cs_events "unit: H2" awaiting-operator-merge
    jq 'map(if .number == 1 then .state = "MERGED" else . end)' "$CS/gh/prs.json" > "$CS/gh/prs.json.t" && mv "$CS/gh/prs.json.t" "$CS/gh/prs.json"
    printf '%s\n' "$MGH" > "$CS/claude/handoff.md"
    expect_eq "$(cs_run M1 handoff review-accept) $(cs_ctr "$CS/claude/snap.2") $(grep -x 'MODE: continue' "$CS/claude/prompt.2" 2>/dev/null)" \
      "0 0 0 0 MODE: continue" "unit: H3 merged by the operator, no answer -> exit 0, counters 0 0 0 at the launch, MODE: continue"
    cs_events "unit: H3" awaiting-operator-merge unit-shipped
  fi
}
scenario "unit: H" sc_unit_h

if is_full; then
  sc_unit_b() {
    printf '%s\n' "$MGH" > "$CS/claude/handoff.md"
    local f; expect_eq "$(cs_run M1 handoff review-reject handoff review-accept) $(cs_ctr "$CSU")" "0 1 0 0" "unit: B reject, then accept -> exit 0, rework 1"
    f="$(ctx_of "$CS/claude/prompt.3" | sed -n 's/^FINDINGS_FILE: //p')"
    expect_eq "$(grep -x 'MODE: rework' "$CS/claude/prompt.3" 2>/dev/null) $([[ -f "$f" ]] && echo exists)" "MODE: rework exists" \
      "unit: B prompt.3 has MODE: rework and an existing FINDINGS_FILE"
    cs_events "unit: B" unit-shipped
  }
  scenario "unit: B" sc_unit_b
  sc_unit_e() {
    printf '%s\n' "$MGH" > "$CS/claude/handoff.md"
    expect_eq "$(cs_run M1 code-pr handoff review-accept) $(cs_ctr "$CSU") $(cs_row '.prs | length')" "0 0 1 0 2" \
      "unit: E code-pr, then shipped -> exit 0, continuation 1, two pull requests in the row"
    cs_events "unit: E" unit-shipped
  }
  scenario "unit: E" sc_unit_e
  sc_unit_f() {
    expect_eq "$(cs_run M1 nothing nothing) $(cs_ctr "$CSU") $(cs_row .stop_reason) $(cs_inv)" "3 1 0 0 cap-rework 2" \
      "unit: F nothing nothing -> exit 3, rework 1, cap-rework, two invocations"
    cs_events "unit: F" stop
    # F2 (pilot finding 3): after an answer, a lead the guard stopped with no progress -> stop guard-blocked, no rework session.
    expect_eq "$(CS_ANSWER="retry" cs_run M1 guard-stop) $(cs_ctr "$CSU") $(cs_row .status) $(cs_inv)" "3 0 0 0 escalated 3" \
      "unit: F2 guard-stop -> exit 3, counters 0 0 0, escalated, one more invocation"
    expect_eq "$(cs_row .stop_reason)" "guard-blocked: FARM-GUARD BLOCKED: fake" "unit: F2 the stop reason quotes the first denial"
    cs_events "unit: F2" stop stop
  }
  scenario "unit: F" sc_unit_f
  sc_unit_g() {
    expect_eq "$(cs_run M1 transient transient transient transient) $(cs_row .stop_reason) $(cs_inv)" "3 cap-interruption 4" \
      "unit: G four transients -> exit 3, cap-interruption, four invocations"
    cs_events "unit: G" stop
  }
  scenario "unit: G" sc_unit_g
  sc_unit_i() {
    printf '%s\n' "$MGH" > "$CS/claude/handoff.md"
    expect_eq "$(cs_run M1 handoff review-noverdict) $(cs_row .status) $(cs_row .stop_reason)" "3 escalated review-no-verdict" \
      "unit: I no verdict -> exit 3, escalated, review-no-verdict"
    cs_events "unit: I" stop
  }
  scenario "unit: I" sc_unit_i
  sc_unit_j() {
    expect_eq "$(cs_run M1 direct-push) $(cs_row .status) $(cs_row .stop_reason)" "3 shipped-unreviewed shipped-unreviewed" \
      "unit: J direct-push -> exit 3, shipped-unreviewed"
    cs_events "unit: J" stop
  }
  scenario "unit: J" sc_unit_j
  sc_unit_l() {
    push_file "$CSR" "$HOUT" "$HO"
    printf '{"plan":"%s","unit":"M1"}\n' "$PP" > "$CDIR/reviews.jsonl"
    expect_eq "$(cs_run M1 handoff) $(grep -c 'already shipped' "$CS/run.out") $(cs_inv)" "1 1 0" "unit: L a shipped unit -> exit 1, already shipped, no invocation"
    cs_events "unit: L"
  }
  scenario "unit: L" sc_unit_l
  sc_unit_n() {
    local p sid=11111111-2222-3333-4444-555555555555
    printf '%s\n' "$MGH" > "$CS/claude/handoff.md"
    sh -c 'exit 0' & p=$!; wait "$p"
    echo doing > "$CSU/state"; echo "$p" > "$CSU/pid"; echo "$sid" > "$CSU/session_id"
    expect_eq "$(CONDUCT_RESUME_SESSIONS=1 cs_run M1 handoff review-accept) $(cs_ctr "$CSU")" "0 0 0 1" "unit: N a restart -> exit 0, interruption 1"
    argv_pair "$CS/claude/argv.1" --resume "$sid" && ok || nope "unit: N argv.1 has --resume <the recorded session id>"
    cs_events "unit: N" unit-shipped
  }
  scenario "unit: N" sc_unit_n
  sc_unit_o() {
    push_exec "$CSR" verify.sh "$(printf '#!/bin/sh\nexit 1')"
    expect_eq "$(cs_run M1 handoff) $(grep -c verify-failed "$CS/run.out") $(cs_inv)" "1 1 0" "unit: O verify fails -> exit 1, verify-failed, no invocation"
    cs_events "unit: O"
  }
  scenario "unit: O" sc_unit_o
  sc_unit_p() {
    expect_eq "$(cs_run M1 protected-and-handoff) $(cs_row .status) $(cs_inv) $(cs_on_main)" "3 doing 1 not-on-main" \
      "unit: P protected-and-handoff -> exit 3, doing, one invocation (no review), not on main"
    cs_events "unit: P" awaiting-operator-merge
  }
  scenario "unit: P" sc_unit_p
  sc_unit_q() {
    printf '%s\n' "$MGH" > "$CS/claude/handoff.md"
    local f; expect_eq "$(cs_run M1 open-pr-and-handoff nothing) $(cs_row .stop_reason) $(cs_on_main)" "3 cap-rework not-on-main" \
      "unit: Q an open code pull request -> exit 3, cap-rework, not on main"
    f="$(ctx_of "$CS/claude/prompt.2" | sed -n 's/^FINDINGS_FILE: //p')"
    grep -F '#1' "$f" >/dev/null 2>&1 && ok || nope "unit: Q prompt.2's FINDINGS_FILE names the open pull request: [$f]"
    cs_events "unit: Q" stop
  }
  scenario "unit: Q" sc_unit_q
  sc_unit_r() {
    printf '%s\n' "$MGH" > "$CS/claude/handoff.md"
    cs_open_gate
    local k2 k3 v
    expect_eq "$(cs_run M1 handoff limit review-accept) $(cs_ctr "$CSU")" "0 0 0 1" "unit: R a review hits the limit -> exit 0, interruption 1"
    for v in NONCE VERDICT_FILE; do
      k2="$(ctx_of "$CS/claude/prompt.2" | sed -n "s/^$v: //p")"; k3="$(ctx_of "$CS/claude/prompt.3" | sed -n "s/^$v: //p")"
      [[ -n "$k2" && -n "$k3" && "$k2" != "$k3" ]] && ok || nope "unit: R invocation 3 is a review with a new $v: [$k2] [$k3]"
    done
    cs_events "unit: R" limit unit-shipped
  }
  scenario "unit: R" sc_unit_r
  sc_unit_s() {
    expect_eq "$(cs_run M1 noguard) $(cs_row .status) $(cs_row .stop_reason)" "3 escalated guard-not-loaded" "unit: S noguard -> exit 3, escalated, guard-not-loaded"
    cs_events "unit: S" stop
  }
  scenario "unit: S" sc_unit_s
  sc_unit_t() {
    local s="$CS/claude/script" dp i=0 p
    echo hang > "$s"
    (cd / && exec env -u MAIN_BRANCH -u REPO_DIR "$BASH" "$FARM/bin/farmctl" conduct run "$PP" M1 </dev/null >"$CS/run.out" 2>&1) &
    dp=$!
    while (( i < 300 )) && [[ ! -s "$CS/claude/pid.1" ]]; do sleep 0.2; i=$((i + 1)); done
    sleep 1; p="$(cat "$CS/claude/pid.1" 2>/dev/null)"
    kill -TERM "$dp" 2>/dev/null
    i=0; while (( i < 120 )) && [[ -n "$p" ]] && kill -0 "$p" 2>/dev/null; do sleep 1; i=$((i + 1)); done
    [[ "$p" =~ ^[0-9]+$ ]] && ! kill -0 "$p" 2>/dev/null && ok || nope "unit: T TERM to the conductor -> the fake's pid is gone within 120 s"
    wait "$dp" 2>/dev/null
    expect_eq "$([[ -e "$CDIR/lock" ]] && echo locked || echo unlocked) $(cat "$CSU/state" 2>/dev/null)" "unlocked doing" "unit: T the lock is released, state stays doing"
    cs_events "unit: T"
    # Fix wave M4 (final review I1): the session the TERM ended is recorded by the next run, outcome killed.
    printf '%s\n' "$MGH" > "$CS/claude/handoff.md"
    expect_eq "$(cs_run M1 handoff review-accept) $(jq -s -c '[.[] | select(.role != "verify") | [.role, .outcome]]' "$CDIR/usage.jsonl" 2>/dev/null) $(jq -s -c '[.[] | select(.role != "verify")][0] | .wall_s' "$CDIR/usage.jsonl" 2>/dev/null)" \
      '0 [["lead","killed"],["lead","handoff"],["review","merged"]] 0' "unit: T the next run records the killed lead session first, then its own two"
  }
  scenario "unit: T" sc_unit_t
  # Carry-forward 7: a merge GitHub made, whose review record cannot be written, says so in the stop reason.
  sc_unit_merged_unrecorded() {
    printf '%s\n' "$MGH" > "$CS/claude/handoff.md"
    mkdir -p "$CDIR/reviews.jsonl"
    expect_eq "$(cs_run M1 handoff review-accept) $(cs_on_main)" "3 on-main" "unit: merged without a review record -> exit 3"
    case "$(cat "$CSU/stop_reason" 2>/dev/null)" in handoff-merge-failed*merged*) ok ;; *) nope "unit: merged without a review record -> the stop reason says it is merged: [$(cat "$CSU/stop_reason" 2>/dev/null)]" ;; esac
    cs_events "unit: merged without a review record" stop
  }
  scenario "unit: merged without a review record" sc_unit_merged_unrecorded
  # Carry-forward 1: gh failing while a finished session is refined is transient, not evidence.
  sc_unit_refine_gh_down() {
    : > "$CS/gh/fail.list"
    export INFRA_BACKOFF_SECONDS=600
    expect_eq "$(ev_run nothing)|$(cat "$CS/gh/unknown.log" 2>/dev/null)" "transient
rc=0|" "unit: gh cannot list pull requests while refining -> transient, no unknown gh call"
    # Lead ruling M4.2: an outage transient sets the farm's infra backoff gate, so three outages cannot hit the cap in seconds.
    local g; g="$(cat "$CSR/.agent-farm/state/limit-until" 2>/dev/null)"
    [[ "$g" =~ ^[0-9]{1,10}$ ]] && (( 10#$g > $(date +%s) + 60 )) && ok || nope "unit: an outage transient leaves the infra backoff gate in the future: [$g]"
  }
  scenario "unit: refine with gh down" sc_unit_refine_gh_down
  # Carry-forward 2: a resumed session keeps the baseline of the session it continues.
  sc_unit_resume_baseline() {
    echo limit > "$CS/claude/script"
    rl start >/dev/null
    ev_pr conduct/p/m1/x 1 src
    gh pr merge 1 --squash --match-head-commit "$(git -C "$CSO" rev-parse refs/heads/conduct/p/m1/x)" >/dev/null 2>&1
    printf 'limit\nnothing\n' > "$CS/claude/script"
    rl resume >/dev/null
    expect_eq "$(cat "$CSU/merged_before" 2>/dev/null) $(cat "$CSU/handoff_sha_before" 2>/dev/null)|$(fcs conduct_refine_ended "$PP" M1 2>/dev/null)|$(cat "$CS/gh/unknown.log" 2>/dev/null)" "0 |progress
rc=0|" "unit: a resumed session keeps the merged count and handoff sha of the interrupted one, no unknown gh call"
  }
  scenario "unit: resume keeps the baseline" sc_unit_resume_baseline
  # Carry-forward 3: the review step's phase-one check during an outage. <fail|gone>: a gh wrapper
  # counts the conduct_find_prs lists (field isCrossRepository) after the lead launched: the first is
  # the refinement's, the second the review step's phase one. fail: that list exits 1. gone: the
  # handoff branch is deleted on origin just before it (ls-remote then returns nothing) and restored
  # before the third.
  cs_gh_outage() {
    printf '#!/bin/sh\nD="%s"; H="%s"\n' "$CS" "$HPH" > "$CS/bin/gh"
    cat >> "$CS/bin/gh" <<EOS
case "\$*" in *"pr list"*isCrossRepository*)
  if [ -e "\$D/claude/argv.1" ]; then
    n=\$(( \$(cat "\$D/lc" 2>/dev/null || echo 0) + 1 )); echo "\$n" > "\$D/lc"
    if [ "\$n" = 2 ] && [ "$1" = fail ]; then exit 1; fi
    if [ "\$n" = 2 ] && [ "$1" = gone ]; then git -C "$CSO" rev-parse "refs/heads/\$H" > "\$D/gone"; git -C "$CSO" update-ref -d "refs/heads/\$H"; fi
    if [ "\$n" = 3 ] && [ -s "\$D/gone" ]; then git -C "$CSO" update-ref "refs/heads/\$H" "\$(cat "\$D/gone")"; fi
  fi ;;
esac
exec "$STUBS/gh" "\$@"
EOS
    chmod +x "$CS/bin/gh"
  }
  # <fail|gone> <description>: handoff review-accept with the outage at the first review step.
  cs_review_outage() {
    printf '%s\n' "$MGH" > "$CS/claude/handoff.md"
    cs_gh_outage "$1"
    expect_eq "$(cs_run M1 handoff review-accept) $(cs_ctr "$CSU") $(cs_inv) $(ctx_of "$CS/claude/prompt.2" | grep -c '^NONCE: ') $([[ "$(cat "$CS/lc" 2>/dev/null)" -ge 3 ]] && echo hooked)" \
      "0 0 0 1 2 1 hooked" "unit: $2 -> transient: exit 0, rework 0, interruption 1, the next step is a review (invocation 2), shipped"
    expect_eq "$(ls "$CSU"/findings-*.md 2>/dev/null | wc -l | tr -d ' ')" 0 "unit: $2 -> the phase-one findings file is removed"
    [[ "$(cat "$CSR/.agent-farm/state/limit-until" 2>/dev/null)" =~ ^[0-9]{1,10}$ ]] && ok || nope "unit: $2 -> the outage set the infra backoff gate"
    cs_events "unit: $2" unit-shipped
  }
  sc_unit_review_gh_down() { cs_review_outage fail "gh cannot list pull requests at the review step"; }
  scenario "unit: review step, gh down" sc_unit_review_gh_down
  sc_unit_review_branch_gone() { cs_review_outage gone "ls-remote gives no handoff branch at the review step"; }
  scenario "unit: review step, handoff branch gone" sc_unit_review_branch_gone
fi

# ---- metrics: conduct_session_id, conduct_usage_by_model, conduct_log_counts, conduct_init_fingerprint, conduct_record_usage (section "metrics") ----
# <function> [args], the run log on stdin: the library function's output, or MISSING when the library or function is absent.
# shellcheck source=../../bin/farm-conduct-lib.sh
ml() { (source "$LIB" 2>/dev/null || exit 9; declare -F "$1" >/dev/null || exit 9; "$@") || echo "MISSING-or-failed rc=$?"; }
# Run logs built the way the fake writes them, but by hand so each case is exact.
mlog_init() { jq -nc --argjson m "${1:-[]}" '{type:"system",subtype:"init",session_id:"s1",tools:["Bash","Agent"],mcp_servers:$m,plugins:[],model:"claude-opus-5",permissionMode:"bypassPermissions",apiKeySource:"none",claude_code_version:"1.2.3"}'; }
mlog_text() { jq -nc --arg t "$1" '{type:"assistant",message:{content:[{type:"text",text:$t}]}}'; }
mlog_result() { jq -nc '{type:"result",subtype:"success",modelUsage:{"claude-opus-5":{inputTokens:100,outputTokens:50,cacheReadInputTokens:7,cacheCreationInputTokens:3,costUSD:0.5}}}'; }
mx_a="$( { mlog_init '[]'; mlog_text 'FARM-GUARD BLOCKED: only said in assistant text'; echo 'not json FARM-GUARD BLOCKED'; mlog_result; mlog_result; } )"
expect_eq "$(printf '%s\n' "$mx_a" | ml conduct_log_counts './verify.sh' | jq -c .guard_denials 2>/dev/null)" 0 "metrics: FARM-GUARD BLOCKED only in assistant text or a non-JSON line -> guard_denials 0"
# conduct_first_denial: the stop reason's quote (pilot finding 3).
mlog_deny() { jq -nc --argjson c "$1" '{type:"user",message:{content:[{type:"tool_result",tool_use_id:"t",content:$c}]}}'; }
expect_eq "$(printf '%s\n' "$mx_a" | ml conduct_first_denial)" "" "metrics: first denial, none in a tool result -> empty"
expect_eq "$( { mlog_init '[]'; mlog_deny '"ok"'; mlog_deny '"line one\nFARM-GUARD BLOCKED: push\u0007 denied\nmore"'; mlog_deny '"FARM-GUARD BLOCKED: second"'; } | ml conduct_first_denial)" \
  "FARM-GUARD BLOCKED: push denied" "metrics: first denial -> its first denying line, control characters removed"
expect_eq "$(mlog_deny '[{"type":"text","text":"x"},{"type":"text","text":"FARM-GUARD BLOCKED: in an array"}]' | ml conduct_first_denial)" \
  "FARM-GUARD BLOCKED: in an array" "metrics: first denial in array content"
expect_eq "$(mlog_deny "$(jq -nc --arg t "FARM-GUARD BLOCKED: $(printf 'x%.0s' $(seq 1 300))" '$t')" | ml conduct_first_denial | awk '{ print length($0) }')" 200 \
  "metrics: first denial bounded to 200 characters"
expect_eq "$(printf '%s\n' "$mx_a" | ml conduct_usage_by_model | jq -c '[.["claude-opus-5"].in, .["claude-opus-5"].out, .["claude-opus-5"].cache_read, .["claude-opus-5"].cache_creation, .["claude-opus-5"].cost_usd]' 2>/dev/null)" \
  '[200,100,14,6,1]' "metrics: two result events are summed by model"
mx_b="$(mlog_init '[{"name":"x","status":"connected"}]')"
mx_c="$(mlog_init '[{"name":"x","status":"connected"},{"name":"y","status":"connected"}]')"
fpb="$(printf '%s\n' "$mx_b" | ml conduct_init_fingerprint | jq -r .fp 2>/dev/null)"; fpc="$(printf '%s\n' "$mx_c" | ml conduct_init_fingerprint | jq -r .fp 2>/dev/null)"
case "$fpb" in ''|*[!0-9]*) nope "metrics: fp is an integer: [$fpb]" ;; *) [[ "$fpb" != "$fpc" ]] && ok || nope "metrics: an extra mcp_servers entry changes the fp ($fpb $fpc)" ;; esac
expect_eq "$(printf '%s\n' "$mx_b" | ml conduct_init_fingerprint | jq -c 'keys' 2>/dev/null)" '["api_key_source","fp","mcp_servers","model","permission_mode","plugins","tools","version"]' \
  "metrics: the fingerprint carries the seven fields and fp"
expect_eq "$(printf '%s\n' "$mx_b" | ml conduct_init_fingerprint | jq -c '[.version, .api_key_source, .permission_mode]' 2>/dev/null)" '["1.2.3","none","bypassPermissions"]' "metrics: fingerprint field values"
expect_eq "$(printf 'plain text\n' | ml conduct_usage_by_model) $(printf 'plain text\n' | ml conduct_init_fingerprint | jq -r .fp 2>/dev/null) $(printf 'plain text\n' | ml conduct_session_id)|" \
  '{} none |' "metrics: a log with no init and no result -> {}, fp none, no session id, no error"
expect_eq "$(printf '' | ml conduct_log_counts '' | jq -c '[.agent_dispatches, .verify_runs, .guard_denials]' 2>/dev/null)" '[0,0,0]' "metrics: an empty log -> zero counts"
# Fix wave M4 (final review m10): the fingerprint names the MCP servers, never their health.
mx_d="$(mlog_init '[{"name":"x","status":"failed"}]')"
expect_eq "$(printf '%s\n' "$mx_d" | ml conduct_init_fingerprint | jq -r .fp 2>/dev/null) $(printf '%s\n' "$mx_b" | ml conduct_init_fingerprint | jq -c .mcp_servers 2>/dev/null)" "$fpb [\"x\"]" \
  "metrics: an MCP server whose status changes keeps the fp; the fingerprint lists server names"
# Security review L-1: token counts are finite non-negative integers, cost a finite non-negative number; anything else counts 0.
mx_e="$(jq -nc '{type:"result",modelUsage:{m:{inputTokens:1e400,outputTokens:-5,cacheReadInputTokens:"9",cacheCreationInputTokens:1.5,costUSD:-1}}}'
        jq -nc '{type:"result",modelUsage:{m:{inputTokens:4,outputTokens:2,cacheReadInputTokens:1,cacheCreationInputTokens:1,costUSD:0.25}}}')"
expect_eq "$(printf '%s\n' "$mx_e" | ml conduct_usage_by_model | jq -c '.m | [.in, .out, .cache_read, .cache_creation, .cost_usd]' 2>/dev/null)" '[4,2,1,1,0.25]' \
  "metrics: a huge, negative, string or fractional token count and a negative cost count 0"

# [smoke] the lead and review sessions of scenario A are recorded, the lead's log is the fake's handoff log
sc_metrics_a() {
  printf '%s\n' "$MGH" > "$CS/claude/handoff.md"
  cs_run M1 handoff review-accept >/dev/null
  local lg u="$CDIR/usage.jsonl" vc; lg="$(ls "$CDIR"/logs/conduct-*-lead-*.log 2>/dev/null | head -1)"
  vc="$(sed -n 's/^VERIFY_CMD: //p' "$CS/claude/prompt.1" | head -1)"
  expect_eq "$(ml conduct_session_id < "$lg")" 00000000-0000-0000-0000-000000000001 "metrics: session id of the fake's handoff log"
  expect_eq "$(ml conduct_usage_by_model < "$lg" | jq -c 'keys | length' 2>/dev/null)" 2 "metrics: the fake's log has two models in modelUsage"
  expect_eq "$(ml conduct_log_counts "$vc" < "$lg" | jq -c '[.agent_dispatches, .agent_dispatches_by_model.haiku, .verify_runs, .guard_denials]' 2>/dev/null)" '[1,1,1,1]' \
    "metrics: the fake's log -> one agent dispatch (haiku), one verify run, one guard denial"
  expect_eq "$(ml conduct_init_fingerprint < "$lg" | jq -c '[(.fp | type), .model, .tools]' 2>/dev/null)" '["number","claude-opus-5",["Agent","Bash"]]' "metrics: the fake's init fingerprint"
  expect_eq "$(jq -s -c '[.[] | select(.role != "verify") | .role]' "$u" 2>/dev/null) $(jq -s -c '[.[] | select(.role == "verify")] | length' "$u" 2>/dev/null)" '["lead","review"] 2' \
    "metrics: A usage.jsonl has a lead and a review session line beside two verify lines"
  expect_eq "$(jq -s -c '[.[] | select(.role == "lead")][0] | [.plan, .unit, .outcome, (.wall_s | type), .in, .out, .cache_read, .cache_creation, .cost_usd, (.by_model | keys | length), .agent_dispatches, .verify_runs, .guard_denials, (.fingerprint.fp | type), .drift, .session_id]' "$u" 2>/dev/null)" \
    "[\"$PP\",\"M1\",\"handoff\",\"number\",110,55,0,0,0,2,1,1,1,\"number\",false,\"00000000-0000-0000-0000-000000000001\"]" "metrics: A the lead session line"
  expect_eq "$(cs_row '.usage | [.sessions, .in, .out]' | jq -c . 2>/dev/null)" "$(jq -s -c '[.[] | select(.role != "verify")] | [length, (map(.in) | add), (map(.out) | add)]' "$u" 2>/dev/null)" \
    "metrics: A status --json usage sums the session lines, not the verify lines"
  expect_eq "$(cs_row .usage.sessions)" 2 "metrics: A status --json usage.sessions is 2"
  cat "$CDIR/p/m1/first_fp" > /dev/null 2>&1 && ok || nope "metrics: A first_fp state file written"
  # drift: a session whose init differs from the unit's first one
  local dl="$CS/drift.log" rc
  mlog_init '[{"name":"x"}]' > "$dl"
  (cd / && export CONDUCT_DEFINE_ONLY=1 && source "$FARM/bin/farm-conduct.sh" >/dev/null 2>&1 || exit 9
   declare -F conduct_record_usage >/dev/null || exit 9
   setup "$PP"; conduct_record_usage "$PP" M1 lead "$dl" 100 130 ended 0 0) </dev/null 2>"$CS/drift.err"; rc=$?
  expect_eq "$rc $(tail -n 1 "$u" | jq -c '[.drift, .wall_s, .outcome]' 2>/dev/null) $(grep -c -i 'drift' "$CS/drift.err")" '0 [true,30,"ended"] 1' "metrics: a session with a different fp -> drift true, stderr names it"
  # Security review L-3: an init event the fingerprint cannot read says drift detection is skipped; a log with no init says nothing.
  mlog_init '[]' | jq -c '.tools = "notarray"' > "$CS/badinit.log"; printf 'plain text\n' > "$CS/noinit.log"
  (cd / && export CONDUCT_DEFINE_ONLY=1 && source "$FARM/bin/farm-conduct.sh" >/dev/null 2>&1 || exit 9
   declare -F conduct_record_usage >/dev/null || exit 9
   setup "$PP"; conduct_record_usage "$PP" M1 lead "$CS/badinit.log" 100 130 ended 0 0 2>"$CS/badinit.err"
   conduct_record_usage "$PP" M1 lead "$CS/noinit.log" 100 130 ended 0 0 2>"$CS/noinit.err") </dev/null >/dev/null 2>&1; rc=$?
  expect_eq "$rc $(grep -c 'drift detection skipped' "$CS/badinit.err" 2>/dev/null) $(grep -c 'drift detection skipped' "$CS/noinit.err" 2>/dev/null)" '0 1 0' \
    "metrics: a malformed init event -> one stderr line, drift detection skipped; no init -> none"
}
scenario "metrics: A" sc_metrics_a
if is_full; then
  sc_metrics_e() {
    printf '%s\n' "$MGH" > "$CS/claude/handoff.md"
    expect_eq "$(cs_run M1 code-pr handoff review-accept) $(jq -s -c '[.[] | select(.role == "lead")][0] | [.prs_opened, .prs_merged]' "$CDIR/usage.jsonl" 2>/dev/null)" "0 [1,1]" \
      "metrics: E the first session line has prs_opened 1 and prs_merged 1"
  }
  scenario "metrics: E" sc_metrics_e
fi

# ---- plan loop: conduct_loop_decide, farmctl conduct run <plan> (section "plan loop") ----
lpd() { run_fn conduct_loop_decide "$@" </dev/null; }
for c in 'shipped 0=skip' 'ready 0=run' 'doing 0=run' 'review 0=run' 'doing 1=stop:session-alive' 'review 1=stop:session-alive' \
         'escalated 0=stop:escalated' 'shipped-unreviewed 0=stop:shipped-unreviewed' 'backlog 0=stop:backlog' 'bogus 0=stop:invalid-state' \
         'ready 1=stop:session-alive' 'ready 2=stop:invalid-state'; do
  # shellcheck disable=SC2086  # the two arguments are word-split on purpose
  expect_eq "$(lpd ${c%%=*})" "${c#*=}
rc=0" "loop: conduct_loop_decide ${c%%=*}"
done
# Security review M-1: the plan blob pinned at loop start against the one re-read before each unit.
pz="$(printf '%040d' 0)"; p1="$(printf '%040d' 1)"
for c in "$pz,$pz=same" "$pz,$p1=changed" ",$pz=changed" "$pz,=changed" "XYZ,XYZ=changed"; do
  pa="${c%%=*}"
  expect_eq "$(run_fn conduct_plan_pin_decide "${pa%%,*}" "${pa#*,}" </dev/null)" "${c#*=}
rc=0" "loop: conduct_plan_pin_decide [$pa]"
done
# Operator decision 2026-11-18: a plan must match a protected glob (the guard's match, * crosses /).
MG="$(GUARD_DEFINE_ONLY=1 CLAUDE_PLUGIN_ROOT="$FARM" "$BASH" -c 'source "$1" || exit 9; _guard_mandatory_globs' _ "$FARM/hooks/guard-bash.sh" </dev/null 2>/dev/null)"
ppd() { printf '%s' "$2" | run_fn conduct_plan_protected_decide "$1"; }
NL=$'\n'; CR=$'\r'
for c in "docs/superpowers/plans/a/b.md|$MG|ok" "notes/p.md|$MG${NL}notes/*|ok" "notes/p.md|$MG${NL}notes/*$CR|ok" \
         "notes/p.md|$MG|refuse:plan-unprotected" "docs/superpowers/plans/p.md||refuse:plan-unprotected" \
         "docs/superpowers/plans/p.md|# docs/*${NL}${NL}|refuse:plan-unprotected" \
         "docs/superpowers/plans/../x.md|$MG|refuse:plan-unprotected" "../docs/superpowers/plans/x.md|*|refuse:plan-unprotected"; do
  g="${c#*|}"
  expect_eq "$(ppd "${c%%|*}" "${g%|*}")" "${c##*|}
rc=0" "plan: conduct_plan_protected_decide [${c%%|*} ${c##*|}]"
done
# Operator requirement 2026-11-18: a plan links its spec. <plan path> <plan text>: conduct_plan_spec.
psd() { printf '%s\n' "$2" | run_fn conduct_plan_spec "$1"; }
P1=docs/superpowers/plans/p.md; HD='# Plan'; U1='## M1 — a'
for c in "$P1|$HD${NL}**Spec:** [the spec](../specs/x.md)${NL}$U1|docs/superpowers/specs/x.md|0" \
         "$P1|$HD${NL}**Spec:** [\`docs/superpowers/specs/x.md\`](../specs/x.md), [other](../specs/y.md)${NL}$U1|docs/superpowers/specs/x.md|0" \
         "$P1|$HD${NL}**Spec:** \`docs/superpowers/specs/x.md\`${NL}$U1|docs/superpowers/specs/x.md|0" \
         "$P1|$HD${NL}**Spec:** [s](./../../superpowers/specs/./x.md#part-2)${NL}$U1|docs/superpowers/specs/x.md|0" \
         "$P1|$HD${NL}**Spec:** [s](x.md)$CR${NL}$U1|docs/superpowers/plans/x.md|0" \
         "$P1|$HD${NL}**Spec:** [s](https://example.com/x.md)${NL}$U1|spec-bad-path|1" \
         "$P1|$HD${NL}**Spec:** [s](file:x.md)${NL}$U1|spec-bad-path|1" \
         "$P1|$HD${NL}**Spec:** [s](/etc/passwd)${NL}$U1|spec-bad-path|1" \
         "$P1|$HD${NL}**Spec:** [s](../../../../x.md)${NL}$U1|spec-bad-path|1" \
         "$P1|$HD${NL}**Spec:** \`../../../x.md\`${NL}$U1|spec-bad-path|1" \
         "$P1|$HD${NL}**Spec:** [s](#top)${NL}$U1|spec-bad-path|1" \
         "$P1|$HD${NL}**Spec:** the design doc${NL}$U1|spec-bad-path|1" \
         "$P1|$HD${NL}Spec: [s](../specs/x.md)${NL}$U1|no-spec|1" \
         "$P1|$HD${NL}$U1${NL}**Spec:** [s](../specs/x.md)|no-spec|1" \
         "$P1|$HD${NL}\`\`\`text${NL}**Spec:** [s](../specs/x.md)${NL}\`\`\`${NL}$U1|no-spec|1" \
         "$P1|$HD${NL}**Spec:** [s](../specs/x.md)${NL}**Spec:** [t](../specs/y.md)|docs/superpowers/specs/x.md|0" \
         "notes/p.md|$HD${NL}**Spec:** [s](../specs/x.md)|specs/x.md|0" "p.md|$HD${NL}**Spec:** [s](../x.md)|spec-bad-path|1"; do
  pt="${c#*|}"; pt="${pt%|*|*}"; w="${c%|*}"; w="${w##*|}"
  expect_eq "$(psd "${c%%|*}" "$pt")" "$w
rc=${c##*|}" "plan: conduct_plan_spec [${c%%|*} -> $w]"
done
# <jq filter>: applied to the rows array of farmctl conduct status --json.
cs_rows() { (cd / && "$BASH" "$FARM/bin/farmctl" conduct status "$PP" --json </dev/null 2>/dev/null) | jq -r "$1" 2>/dev/null; }
# <description> <"event unit"...>: notify.log and notifications.log hold exactly these events, in
# order (each naming its unit), and the fake gh logged no unknown call.
cs_levents() {
  local d="$1" want; shift
  want="$(for e in "$@"; do printf '%s %s %s\n' "${e% *}" "$PP" "${e#* }"; done)"
  expect_eq "$(cat "$CS/notify.log" 2>/dev/null)|$(sed 's/^[^ ]* //' "$CDIR/notifications.log" 2>/dev/null)|$(cat "$CS/gh/unknown.log" 2>/dev/null)" \
    "$want|$want|" "$d: events"
}
m2_dir() { [[ -d "$CDIR/p/m2" ]] && echo m2-dir || echo no-m2-dir; }

# [smoke] one run carries both units: unit 1 continues, is rejected once and ships; unit 2 hits the limit and ships.
sc_loop_two() {
  local u="$CDIR/usage.jsonl" h2=docs/superpowers/handoffs/p-m2-handoff.md n=0 sb eb p
  if is_full; then
    # Lead ruling M4.2: the loop's lock is one conductor's; another live conductor still refuses both commands.
    sleep 300 >/dev/null 2>&1 & p=$!
    mkdir -p "$CDIR/lock"; echo "$p" > "$CDIR/lock/pid"
    expect_eq "$(cs_run plan handoff) $(grep -c conductor-active "$CS/run.out") $(cs_run M1 handoff) $(grep -c conductor-active "$CS/run.out") $(cs_inv)" "1 1 1 1 0" \
      "loop: another live conductor holds the lock -> the loop and the single-unit command exit 1, conductor-active, no invocation"
    kill "$p" 2>/dev/null; wait "$p" 2>/dev/null
  fi
  printf '%s\n' "$MGH" > "$CS/claude/handoff.md"
  cs_open_gate
  expect_eq "$(cs_run plan code-pr handoff review-reject handoff review-accept limit handoff review-accept) $(cs_rows '[.[].status] | join(",")') $(cs_ctr "$CDIR/p/m1") $(cs_ctr "$CDIR/p/m2") $(cs_inv)" \
    "0 shipped,shipped 1 1 0 0 0 1 8" "loop: two units -> exit 0, both shipped; unit 1 rework 1, continuation 1; unit 2 interruption 1; eight invocations"
  expect_eq "$(ctx_of "$CS/claude/prompt.6" | sed -n 's/^UNIT: //p;s/^DEPENDENCY_HANDOFFS: //p;s/^DEPENDENT_UNITS: //p' | tr '\n' ' ')" "M2 $HOUT none " \
    "loop: the first unit-2 prompt has DEPENDENCY_HANDOFFS unit 1's handoff and DEPENDENT_UNITS none"
  expect_eq "$(git -C "$CSO" show "main:$HOUT" 2>/dev/null | run_fn conduct_entry_statuses M2 | tr '\n' ',')" "met,accepted,rc=0," \
    "loop: unit 1's handoff on main has an M2 entry criteria section, every row met or accepted"
  expect_eq "$(git -C "$CSO" log --format=%H main -- docs/superpowers/handoffs 2>/dev/null | wc -l | tr -d ' ') $(git -C "$CSO" log --name-only --format= main -- docs/superpowers/handoffs 2>/dev/null | grep . | sort | tr '\n' ' ')" \
    "2 $HOUT $h2 " "loop: only the two conductor merges touch docs/superpowers/handoffs on main"
  while read -r sb eb; do git -C "$CSO" merge-base --is-ancestor "$sb" "$eb" 2>/dev/null && n=$((n + 1)); done < <(jq -r '"\(.start_sha) \(.end_sha)"' "$CDIR/reviews.jsonl" 2>/dev/null)
  expect_eq "$(wc -l < "$CDIR/reviews.jsonl" 2>/dev/null | tr -d ' ') $n" "2 2" "loop: reviews.jsonl has two lines, each start_sha an ancestor of its end_sha"
  expect_eq "$(jq -s -c '[([.[] | select(.role != "verify")] | length), ([.[] | select(.role == "verify")] | length), ([.[] | select(.role == "verify" and .outcome == "pass")] | length)]' "$u" 2>/dev/null) $(cs_rows '[.[].usage.sessions] | add')" \
    "[8,4,4] 8" "loop: usage.jsonl has eight session lines and four verify lines with outcome pass; usage.sessions sums to 8"
  expect_eq "$([[ -e "$CDIR/lock" ]] && echo locked || echo unlocked)" unlocked "loop: the lock is released"
  cs_levents "loop: two units" "unit-shipped M1" "limit M2" "unit-shipped M2"
  # Operator decision 2026-11-18: a plan outside every protected glob on origin/main is refused by both commands.
  gitq -C "$CSR" pull -q origin main 2>/dev/null; push_file "$CSR" notes/p.md "$(cat "$CSR/$PP")"
  n="$(cat "$CS/notify.log" 2>/dev/null | wc -l | tr -d ' ')"
  expect_eq "$(PP=notes/p.md cs_run plan handoff) $(grep -c plan-unprotected "$CS/run.out") $(PP=notes/p.md cs_run M1 handoff) $(grep -c plan-unprotected "$CS/run.out") $(cs_inv) $(cat "$CS/notify.log" 2>/dev/null | wc -l | tr -d ' ')" \
    "1 1 1 1 8 $n" "loop: an unprotected plan -> the loop and the single-unit command exit 1, plan-unprotected, no invocation or event"
  # Operator requirement 2026-11-18: a protected plan without a Spec line is refused by both commands, at the same place.
  push_file "$CSR" docs/superpowers/plans/nospec.md "$(grep -v '^\*\*Spec:\*\*' "$CSR/$PP")"
  expect_eq "$(PP=docs/superpowers/plans/nospec.md cs_run plan handoff) $(grep -c no-spec "$CS/run.out") $(PP=docs/superpowers/plans/nospec.md cs_run M1 handoff) $(grep -c no-spec "$CS/run.out") $(cs_inv) $(cat "$CS/notify.log" 2>/dev/null | wc -l | tr -d ' ')" \
    "1 1 1 1 8 $n" "loop: a plan without a Spec line -> the loop and the single-unit command exit 1, no-spec, no invocation or event"
}
scenario "loop: two units" sc_loop_two

if is_full; then
  # Unit 1 shipped by an earlier run; verify on origin/main fails, then passes again.
  sc_loop_shipped() {
    push_file "$CSR" "$HOUT" "$HO"
    printf '{"plan":"%s","unit":"M1"}\n' "$PP" > "$CDIR/reviews.jsonl"
    push_exec "$CSR" verify.sh "$(printf '#!/bin/sh\nexit 1')"
    expect_eq "$(cs_run plan handoff review-accept) $(cs_inv) $(grep -c verify-failed "$CS/notify.stdin" 2>/dev/null)" "3 0 1" \
      "loop: verify fails on main -> exit 3, no invocation, the pause names verify-failed"
    cs_levents "loop: verify fails" "pause M2"
    push_exec "$CSR" verify.sh "$(printf '#!/bin/sh\nexit 0')"
    printf '%s\n' "$MGH" > "$CS/claude/handoff.md"
    expect_eq "$(cs_run plan handoff review-accept) $(cs_inv) $(cat "$CS/claude/prompt.1" "$CS/claude/prompt.2" 2>/dev/null | grep -c '^UNIT: M2$')" "0 2 2" \
      "loop: unit 1 already shipped -> exit 0, only two invocations, both for unit 2"
    cs_levents "loop: unit 1 already shipped" "pause M2" "unit-shipped M2"
  }
  scenario "loop: unit 1 shipped earlier" sc_loop_shipped
  sc_loop_stop() {
    printf '%s\n' "$MGH" > "$CS/claude/handoff.md"
    expect_eq "$(cs_run plan handoff review-reject handoff review-reject) $(cs_rows '[.[].status] | join(",")') $(cs_inv) $(m2_dir)" "3 escalated,backlog 4 no-m2-dir" \
      "loop: two rejections -> exit 3, unit 2 never launched, its row backlog"
    cs_levents "loop: two rejections" "stop M1"
    expect_eq "$(cs_run plan handoff) $(grep cap-rework "$CS/run.out" >/dev/null && echo named) $(cs_inv)" "3 named 4" \
      "loop: an escalated unit -> exit 3, its stop reason printed, no invocation"
    cs_levents "loop: an escalated unit" "stop M1"
  }
  scenario "loop: a stopped unit" sc_loop_stop
  sc_loop_notmet() {
    printf '%s\n' "$(swap "$MGH" "met (#12 merged)" "not met")" > "$CS/claude/handoff.md"
    expect_eq "$(cs_run plan handoff review-accept) $(cs_inv) $(m2_dir) $(grep -c entry-criteria-blocked "$CS/notify.stdin" 2>/dev/null)" "3 2 no-m2-dir 1" \
      "loop: unit 2's entry criteria not met -> exit 3 after unit 1 ships, no unit-2 invocation or state directory, the pause names entry-criteria-blocked"
    cs_levents "loop: not met" "unit-shipped M1" "pause M2"
    expect_eq "$(cs_run M2 handoff) $(grep -c entry-criteria-blocked "$CS/run.out") $(cs_inv)" "1 1 2" \
      "loop: the single-unit command on the not met case -> exit 1, no invocation"
    cs_levents "loop: single unit, not met" "unit-shipped M1" "pause M2"
  }
  scenario "loop: entry criteria not met" sc_loop_notmet
  # <plan file>: a gh wrapper that pushes it to main as the plan after the first successful pr merge
  # (the unit-1 lead's plan edit landing while the conductor merges its handoff).
  cs_plan_on_merge() {
    local c="$CS/pc"
    git clone -q "$CSO" "$c" 2>/dev/null
    printf '#!/bin/sh\n"%s/gh" "$@"; r=$?\ncase "$1 $2" in "pr merge") if [ "$r" = 0 ] && [ ! -e "%s/cyc.done" ]; then : > "%s/cyc.done"; (cd "%s" && git pull -q origin main && cp "%s" "%s" && git -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -qam cycle && git push -q origin HEAD:main) >/dev/null 2>&1; fi ;; esac\nexit "$r"\n' \
      "$STUBS" "$CS" "$CS" "$c" "$1" "$PP" > "$CS/bin/gh"
  }
  # Fix round 1 (I1): the plan on main gains a cycle while unit 1 ships. Since the M4 fix wave
  # (security review M-1) any plan change pauses the loop; the next loop run lints the plan and names the cycle.
  sc_loop_cycle() {
    printf '%s\n' "$(swap "$(cat "$CSR/$PP")" "## M1 — Greeting" "## M1 — Greeting

Depends-on: M2")" > "$CS/cyc.md"
    cs_plan_on_merge "$CS/cyc.md"
    printf '%s\n' "$MGH" > "$CS/claude/handoff.md"
    expect_eq "$(cs_run plan handoff review-accept) $(grep -c 'plan shipped' "$CS/run.out") $(grep -c plan-changed "$CS/notify.stdin" 2>/dev/null) $(cs_inv) $(m2_dir) $([[ -e "$CS/cyc.done" ]] && echo pushed)" \
      "3 0 1 2 no-m2-dir pushed" "loop: the plan on main gains a cycle after unit 1 ships -> exit 3, plan-changed, no shipped claim, unit 2 never launched"
    cs_levents "loop: cycle" "unit-shipped M1" "pause M2"
    expect_eq "$(cs_run plan handoff) $(grep -c 'LINT: cycle' "$CS/run.out") $(cs_inv)" "1 1 2" \
      "loop: the next loop run on the cyclic plan -> exit 1 naming the cycle, no invocation"
  }
  scenario "loop: a cycle after unit 1 ships" sc_loop_cycle
  # Security review M-1: unit 1's lead merged a plan edit that drops unit 2's dependency; the loop pauses, launches nothing.
  sc_loop_plan_changed() {
    local b0 b1
    printf '%s\n' "$(swap "$(cat "$CSR/$PP")" "## M2 — Farewell" "## M2 — Farewell

Depends-on: none")" > "$CS/edit.md"
    cs_plan_on_merge "$CS/edit.md"
    printf '%s\n' "$MGH" > "$CS/claude/handoff.md"
    b0="$(git -C "$CSO" rev-parse "main:$PP")"
    expect_eq "$(cs_run plan handoff review-accept) $(grep -c 'plan shipped' "$CS/run.out") $(cs_inv) $(m2_dir) $([[ -e "$CS/cyc.done" ]] && echo pushed)" \
      "3 0 2 no-m2-dir pushed" "loop: the plan on main changes while unit 1 ships -> exit 3, no shipped claim, unit 2 never launched"
    b1="$(git -C "$CSO" rev-parse "main:$PP")"
    expect_eq "$(grep -c plan-changed "$CS/notify.stdin" 2>/dev/null) $(grep -F -- "$b0" "$CS/notify.stdin" 2>/dev/null | grep -c -F -- "$b1")" "1 1" \
      "loop: the pause reason names plan-changed with the old and the new plan blob"
    cs_levents "loop: plan changed" "unit-shipped M1" "pause M2"
    # Per-commit hook H1: the plan changes after the loop pinned it, before the unit run's own setup. A git
    # wrapper pushes an edit just before the second fetch (the child's setup); the unit run refuses it.
    local rg; rg="$(command -v git)"
    printf '#!/bin/sh\ncase "$*" in *"fetch origin --prune"*) n=$(( $(cat "%s/fc" 2>/dev/null || echo 0) + 1 )); echo "$n" > "%s/fc"; if [ "$n" = 2 ]; then (cd "%s" && "%s" pull -q origin main && echo "Edited again." >> "%s" && "%s" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -qam again && "%s" push -q origin HEAD:main) >/dev/null 2>&1; fi ;; esac\nexec "%s" "$@"\n' \
      "$CS" "$CS" "$CS/pc" "$rg" "$PP" "$rg" "$rg" "$rg" > "$CS/bin/git"
    chmod +x "$CS/bin/git"
    : > "$CS/notify.stdin"; b0="$(git -C "$CSO" rev-parse "main:$PP")"
    expect_eq "$(cs_run plan handoff review-accept) $(cs_inv) $(cat "$CS/fc" 2>/dev/null) $(grep -c plan-changed "$CS/notify.stdin" 2>/dev/null) $(grep -F -- "$b0" "$CS/notify.stdin" 2>/dev/null | grep -c -F -- "$(git -C "$CSO" rev-parse "main:$PP")")" \
      "3 2 2 1 1" "loop: the plan changes between the loop's pin check and the unit run's setup -> exit 3, no launch, one plan-changed pause naming both blobs"
    rm -f "$CS/bin/git"
    cs_levents "loop: plan changed before the unit run" "unit-shipped M1" "pause M2" "pause M2"
  }
  scenario "loop: the plan changes after unit 1 ships" sc_loop_plan_changed
fi
# Fix round 1: the outage gate never shortens a longer gate already set (conduct_gate_keep_decide).
g0=$(( $(date +%s) + 86400 )); mkdir -p "$CSR/.agent-farm/state"; echo "$g0" > "$CSR/.agent-farm/state/limit-until"
expect_eq "$(fcs conduct_outage_backoff 2>/dev/null | tail -n 1) $(cat "$CSR/.agent-farm/state/limit-until" 2>/dev/null)" "rc=0 $g0" \
  "loop: an outage transient leaves a longer existing gate unchanged"
rm -f "$CSR/.agent-farm/state/limit-until"

# ---- syntax and lint of the conductor files (last block) ----
for f in "$LIB" "$HERE/conduct.sh" "$FARM/bin/farm-conduct.sh"; do
  if bash -n "$f" 2>/dev/null; then ok; else nope "bash -n ${f#"$FARM"/}"; fi
done
if command -v shellcheck >/dev/null 2>&1; then
  # The suite without -x, as CI lints it: -x re-follows the library at each of its ~40 sources (11 GB
  # RSS with shellcheck 0.9.0, killed under a 7 GB cap); the library has its own -x pass.
  if (cd "$FARM" && shellcheck -x -S warning bin/farm-conduct-lib.sh bin/farm-conduct.sh >/dev/null 2>&1 \
    && shellcheck -S warning engine/tests/conduct.sh >/dev/null 2>&1); then ok
  else nope "shellcheck -S warning on the conductor files (-x on bin/)"; fi
fi

echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
