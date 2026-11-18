# Plan Conductor contract (v2, minimum)

What `farmctl conduct` reads and writes (spec section 4.4). Tests: `engine/tests/conduct.sh`.

## Plan

A markdown file on `origin/<main>` at a repo-relative path matching `^[A-Za-z0-9._/-]+\.md$`, with no `..`
component. Units are level-2 headings matching
`^## (M[0-9]+[a-z]?|PR [0-9]+|Iteration [0-9]+)([^A-Za-z0-9]|$)`; headings inside fenced code are ignored. A unit's
tasks are level-3 headings such as `### Task M1.1: …`. An optional `Depends-on: A, B` (or `none`) is the first
non-blank line under the unit heading; the default is the previous unit. `farmctl conduct lint <plan>` refuses a
unit with no tasks, an unknown dependency, a cycle, a duplicate unit, or the rename of a shipped unit (a unit with a
review or adoption record that the plan no longer has). `lint` and `run` also refuse a plan whose path matches no protected glob on `origin/<main>`
(`plan-unprotected`: the guard's mandatory list, which holds `docs/superpowers/plans/*`, plus `.agent-farm/protected-paths.txt` as committed there).
They also refuse a plan that does not link its spec: the first line starting `**Spec:**` before the first unit heading
(outside fenced code) names it by its first markdown link (the target resolved against the plan's directory, a
`#fragment` dropped) or else its first backticked path (repository-relative). No such line is `no-spec`; a URL, any
`scheme:`, an absolute path or a path that leaves the repository is `spec-bad-path`; a path that is not a file on
`origin/<main>` (the work tree does not count) is `spec-missing`.

## Handoff

Path `docs/superpowers/handoffs/<plan basename>-<unit slug>-handoff.md` (slug: lower case, spaces as `-`).
Sections are level-2 headings matched case-insensitively, with an optional `<number>[letter]. ` prefix and any suffix.

- Phase one (the lead's handoff pull request): `Verification evidence`, `Lessons learned`, and for each dependent
  unit a `<unit> entry criteria` section with at least one table row. A row's status (the column headed `Status`,
  else the last) starts with exactly `met`, `not met` or `accepted`. `not met` blocks the dependent unit. Every
  table needs a separator row (as many cells as the header) as its second row; each row of a table without one is
  invalid.
- Phase two (after the review session): `Security review` is present and phase one still holds.

`farmctl conduct adopt <plan> <unit> <handoff path>` records an existing, differently named handoff as shipped. The
file must be on `origin/<main>` and pass phase two; nothing is written otherwise.

## Unit row

`farmctl conduct status <plan> --json` prints a JSON array, one row per unit in plan order, with exactly these keys:
`id` (`<plan path>#<unit>`), `plan`, `unit`, `title`, `status`, `depends_on` (array of ids), `claimed_by`
(`<host>:<pid>` of the running conductor, else null), `stop_reason` (null when none), `prs` (array of numbers),
`handoff_path` (the adopted path when adopted), `attempts` (`{sessions, rework, continuation, interruption}`),
`owner_ref` (null in increment 1), `usage` (`{sessions, in, out, cache_read, cache_creation, cost_usd, wall_s}`).

`status` is one of `backlog`, `ready`, `doing`, `review`, `shipped`, `escalated`, `shipped-unreviewed` (a handoff
on main with no review record). A handoff on main with a review or adoption record is `shipped`; otherwise the
conductor state (`doing`, `review`, `escalated`; any other value counts as `escalated`) applies; a unit without
state is `ready` when every dependency is `shipped`, else `backlog`.

## Conductor state and records

`${XDG_STATE_HOME:-$HOME/.local/state}/agent-farm/<owner>__<repo>/conduct/`, one JSON object per line (`notifications.log` is plain text):

- `reviews.jsonl` (review record, written by the review step):
  `{"plan", "unit", "start_sha", "end_sha", "review_session_id", "verdict", "high", "medium", "low", "log_path",
  "ts"}`. It counts for a unit when `plan` (the plan path) and `unit` match.
- `adopted.jsonl` (written by `adopt`): `{"plan", "unit", "handoff_path", "adopted_at", "sha"}`, `sha` being
  `origin/<main>` at adoption.
- `usage.jsonl`: one line per lead or review session, `{"ts", "plan", "unit", "role", "outcome", "wall_s", "in", "out",
  "cache_read", "cache_creation", "cost_usd", "by_model", "prs_opened", "prs_merged", "fingerprint", "drift",
  "session_id", "agent_dispatches", "agent_dispatches_by_model", "verify_runs", "guard_denials"}`, with `role` `lead`
  or `review`; `by_model` has `in`, `out`, `cache_read`, `cache_creation` and `cost_usd` per model id, and the
  top-level token fields are their sums. A verify run adds a line `{"ts", "plan", "unit", "role": "verify", "phase",
  "outcome", "exit_code", "wall_s"}` (`phase` `preflight` or `pre-merge`). A row's `usage` sums the numeric fields of
  its unit's session lines and leaves verify lines out.
- `notifications.log`: one line per notify event, `<UTC timestamp> <event> <plan> <unit>`, written before the
  notify command runs.

Malformed lines are skipped. Per unit, `<plan key>/<unit slug>/` holds `state`, `stop_reason`, `prs`, `pid` and the
integer counters `attempts`, `rework`, `continuation`, `interruption` (a non-integer reads as 0), and after a
`guard-blocked` outcome `guard_denial` (the quoted first denial of that session's run log).

## Fixtures

- `fixtures/plan.md` — a two-unit plan (M1, M2) with a fenced fake unit and a `**Spec:**` link to `../specs/p-spec.md`.
- `fixtures/handoff.md` — an M1 handoff that passes phase two with dependent M2.
- `fixtures/unit-rows.json` — four unit rows (shipped, doing, escalated with a stop reason, backlog) with the exact
  key set of a `status --json` row.
