## Why / Context

<1-3 sentences: what user/system outcome this serves; link masterplan/spec/ADR if relevant>

## Scope

- IN: <what this task changes>
- OUT: <explicitly not part of this task — prevents scope creep>

## Complexity (pipeline routing)

- Add `tier:light` ONLY if this is a trivial, single-file-ish change touching NO
  safety/protected surface — it runs the cheaper Light pipeline (Sonnet
  implementer; QA review unchanged). Omit it (or use `tier:heavy`) otherwise:
  **default is Heavy**, and the farm forces Heavy on any protected/safety surface
  regardless of the tag.
- Optional implementer-model override: add a `model:sonnet|opus|haiku` tag
  (honored below the safety floor).

## Acceptance Criteria

- [ ] AC1: <observable, testable statement — "user can X", "endpoint returns Y">
- [ ] AC2: ...
- [ ] All ACs covered by automated tests (TDD)

## Verification

<exact commands QA will run, e.g.:>

- `${FARM_VERIFY_CMD}`
- `${FARM_TEST_CMD} -- <pattern>`
- <manual check if unavoidable, with precise steps>

## Context pointers

- <file:line — entry points, related modules, prior art>
- <relevant ADRs / specs / SCHEMA.yaml sections>

## Risks / Notes

- <known traps, perf or security considerations, affected visual scope for UI>

## Evidence (scout/bug tasks only)

- <file:line citation or command + output proving the problem is real>
