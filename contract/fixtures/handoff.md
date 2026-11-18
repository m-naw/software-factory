# M1 handoff (synthetic fixture)

A handoff used by engine/tests/conduct.sh (section "handoff").

## 1. Delivered

A script that prints `hello`.

## 3. Verification evidence

```text
PASS=12 FAIL=0
```

## 5a. Security review (plan §0.5)

No findings.

## 5b. Lessons learned (cumulative — read first)

- Write the failing test first.

## 6. M2 entry criteria

| # | Criterion | Status | Evidence |
|---|---|---|---|
| 1 | M1 pull request merged | met (#12 merged) | PR #12 |
| 2 | Slow nightly job | accepted 2026-11-12; re-confirm in M2 | run 7 |

## 7. Prompt for the next session

Start M2.
