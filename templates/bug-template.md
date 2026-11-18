## Symptom

<what happens, where, for whom>

## Reproduction

1. <exact steps / command>
2. ...

## Expected vs Actual

- Expected: <...>
- Actual: <...> (paste the relevant output/stacktrace excerpt)

## Evidence

- <file:line / failing command output / log excerpt — REQUIRED>

## Suspected cause (optional, mark confidence)

<hypothesis + confidence 0-1; implementer must verify via systematic-debugging, not trust this>

## Acceptance Criteria

- [ ] A failing test reproducing the bug exists FIRST, then passes after the fix
- [ ] Root cause fixed (not the symptom); explain the root cause in the PR body
- [ ] Regression test stays in the suite
- [ ] No behavior outside Scope changes

## Verification

- `${FARM_TEST_CMD} -- <new regression test>`
- `${FARM_VERIFY_CMD}`
