# Plan Conductor: increment 1, and the direction beyond it

Date: 2026-11-12. Status: fourth draft. Part I is scoped to what a final independent review
called ready for planning. Part II is direction only and is not to be planned from this document.

Scope: `software-factory` (this repo, formerly agent-farm) and a planning consumer of its contract.

History. Draft 1 improved the ticket mill; an independent review judged it unsound. Draft 2 was a
thin serial conductor; the operator rejected it as slimming with no stated gain. Draft 3 answered
with a whole system (contract, parallel scheduler, scouts, a planning consumer, eval, a platform without a local runtime); the final
independent review found central defects in its queue, its unattended level, its scouts and its
eval, and recommended planning only rails, contract, a supervised conductor and a one-unit pilot.
This draft does that, and records what each later piece must fix before it gets its own spec.

Line references come from subagent recon, two independent reviews and reproduction scripts.
Re-verify every `file:line` before editing.

## 1. Intent

The operator wants a tool they can put into any repository, including one on a platform without a local runtime, and
leave running day and night with minimal oversight, delivering solid value to production without
worrying that something is broken; a top software team optimised for cost, throughput and
quality, on a Claude subscription and never an API key.

Increment 1 delivers the smallest piece of that which can be run and measured for real: the
operator starts one unit of one real plan, and the farm carries it to an independently reviewed,
merged handoff without the operator pasting anything, recording what it cost.

## 2. Evidence

### 2.1 Why the farm fails today

- The unit of work is a small ticket with one implementer and one QA session. In
  one production repository, 93 of 209 tickets were scout-created in 17 days; 13 backlog tickets are
  47–56 days old. The operator stopped the farm and deleted the backlog every time.
- The scout is told to "fill the backlog" (`defaults/prompts/scout.md:6-7`), re-scans unchanged
  code after an unclean sweep (`bin/farm-scout.sh:32-39`) and files tickets itself.
- `FARM_VERIFY_CMD` is referenced nowhere under `bin/`; defaults say `npm`
  (`defaults/farm.env:3-4`). The farm is JavaScript-only in practice.

### 2.2 What works for the operator

A process run by hand, visible in about 700 plans and 67 handoffs: spec and plan first, reviewed
from several angles by independent subagents; the plan split at planning time into units that
each fit a session (`## M1`, `## M2a` … or `## PR 1` …) and carrying its own protocol; one clean
lead session per unit that opens and merges several PRs and runs a production e2e; a handoff
with verification evidence, a security review record, cumulative lessons and entry criteria;
the operator pasting the handoff's prompt into the next clean session. One real unit ran for
more than five hours. The reference project's CI requires specific job ids, never skips a
required job at job level, and ends deploys with a smoke test that fails the run.

### 2.3 Defects in the existing rails

Reproduced by script unless marked:

- A. The guard reads protected paths from `${CLAUDE_PROJECT_DIR}/.agent-farm/protected-paths.txt`
  (`hooks/guard-bash.sh:148-149`); with that file emptied a denied merge is allowed. A
  repository's file replaces the plugin defaults entirely (`engine/install.sh:306`).
- B. The merge gate looks at changed files only, never at checks (`hooks/guard-bash.sh:146-176`).
- C. Limit detection matched the limit phrase anywhere in the run log; limit requeues were
  uncounted. Fixed on this branch (section 4.3).
- D. A task moved from `review` to `ready` with a `pr-N` tag is struck and returned to `review`.
  Legacy board flow only; not fixed here.
- Read, not reproduced: an infra backoff overwrites a longer limit gate in the same file
  (`bin/farm-lib.sh:681` vs `:766`); the failstreak counter has no lock and any success resets it.
- Found by review of this branch: arithmetic on state-file content executes code written into
  the file, in the runner process, outside the guard. Fixed on this branch.

### 2.4 What the guard is and is not

It confines tool writes to the worktree, `FARM_STATE_DIR` and temp directories
(`hooks/guard-bash.sh:249-266`). Bash writes are not confined (`:246-247`). `git push` is denied
only with force flags or when deleting the main branch. Farm sessions launch with no
configuration flags (`bin/farm-runner.sh:207-209`), so they inherit the operator's plugins, hooks
and MCP connectors, and MCP tool calls are not matched by the guard (`hooks/hooks.json:5,11`).
The guard has never been shown to deny anything in a live session.

So the guard is a tripwire against known-bad commands and honest mistakes. Under one Unix user
with unconfined Bash, nothing the farm stores is tamper-proof against a misbehaving session.
Increment 1 is therefore a supervised tool. Unattended operation needs sessions under a separate
Unix user and is Part II.

### 2.5 Subscription

Headless `claude -p` draws from the same 5-hour and weekly limits as interactive use; in `-p`
mode an API key in the environment always wins over the login; `total_cost_usd` is a list-price
estimate. Local logs show the CLI emits `rate_limit_event` lines with status `allowed` and
`allowed_warning`; `rejected` has not been observed, and the docs do not describe the stream
shape of a limit hit.

Baseline before this branch: farm suite `PASS=687 FAIL=0`.

## 3. Mechanisms: what is claimed, and what increment 1 actually implements

A claim with no implementation and no measure is "on paper". This table says which are which.

| Mechanism | Increment 1 | Measure available after the pilot |
|---|---|---|
| Spec and plan before code, independently reviewed | Not enforced: the operator does it, as today | none |
| One lead session per plan unit, fed the previous handoff | Yes | sessions per unit; tokens per unit |
| Executable verification: explicit verify command, required CI checks | Yes: verify command required, merge denied without a required check | verify runs; denied merges |
| Independent unit review with a security review, before the unit counts as done | Yes: conductor-run review session and a review record | findings by severity; rework count |
| Per-PR independent reviewer inside the unit | Prompt-level only | reviewer dispatches per session |
| Lessons read by the next unit | Yes: the dependency handoffs are in the prompt | none yet |
| Model tiering inside the unit | Prompt-level only, following the plan | tokens by model, if the stream reports them |
| Deterministic scheduling and gates | Yes | sessions started per shipped unit |
| Bounded loops | Yes: three counters with caps | interruptions, continuations, rework per unit |
| Scouts under supervision, parallel units, production feedback, eval | No (Part II) | none |

## 4. Part I: increment 1

### 4.1 Scope

In:

- Rails: fixes A and B, a mandatory protected-paths list, guard rules for direct pushes and MCP
  tools, a notify command. Fix C and the billing guard are already merged or in review.
- Contract v2, minimum: plan lint, unit status rows, handoff validation, review record.
- A conductor that runs one unit when the operator tells it to, and then a plan's units in
  dependency order.
- A planning consumer: the billing guard, and a test pinning the unit-row shape it will later
  consume.
- Eight spikes that settle how Claude Code really behaves, before the conductor is built on it.
- A pilot.

Out, deliberately: any queue backend, scheduler, claims, `Touches`, parallel running, scouts,
planning-consumer changes, GitHub Issues, the unattended level, deploy and health hooks.
The operator's command is the approval. State is local to the conductor. Visibility is the
notify command and `farmctl conduct status`.

### 4.2 Spikes

Each runs a real `claude -p` session against a throwaway repository and records its result. The conductor is built only on what they show.

| # | Question | If the answer is no |
|---|---|---|
| S1 | Does a guard denial (hook exit 2) block a command under `--dangerously-skip-permissions`? | Stop. Nothing unattended is safe until this holds |
| S2 | Can a `-p` session wait about 50 minutes on a background command, and at what token cost? | A unit whose plan needs such a wait is not eligible for conducting in increment 1; there is no deploy hook yet for the conductor to wait on |
| S3 | Does `claude --resume` continue a session after it exited, and which flags must be passed again? | An interrupted unit restarts in a fresh session from its work in progress |
| S4 | Can `/security-review` be invoked inside a `-p` session? | The review prompt carries the method itself |
| S5 | What does a real limit hit look like in the stream? | Keep the phrase fallback; collect the sample when it happens |
| S6 | What does `CLAUDE_PROJECT_DIR` resolve to in a session launched in a worktree? | Fix A must not depend on it |
| S7 | Is a subagent's model honoured and reported per model in the result's usage? | Tiering stays unmeasured |
| S8 | Which flags pin a session's configuration (`--strict-mcp-config`, `--mcp-config`, `--setting-sources`, `--settings`) while still loading the guard hook? | Record the init event and warn on drift instead |

S5 cannot be forced; it is satisfied by the first real limit hit, whose log path the limit gate
now records.

Safety of the spikes themselves. A spike session never runs with permission prompts skipped
while the operator's real MCP connectors are loaded: a step that needs an MCP call runs without
the skip flag and names one read-only tool. S4 passes only if the review works on a commit range
that is already merged, because that is where the conductor uses it (4.5).

### 4.3 Rails

Already done in an earlier pull request, independently reviewed:

- C. Limit detection, in order: the final result's own text carries the limit phrase (a limit
  hit); otherwise a clean success is never one, even after a `rejected` event, because the CLI
  may carry on under extra usage; otherwise, on a run that did not succeed, a top-level
  `rate_limit_event` with status `rejected` counts only when no work followed it; otherwise the
  phrase match on the log tail, ignoring tool-result events and a cut first line. A retried
  `api_retry` rate-limit event is not evidence. Reset epochs are normalised and bounded to eight
  days. Limit requeues count toward a cap of three only on phrase evidence from a session that
  had been working for two minutes. Known residue: a successful run whose final text quotes the
  phrase is still treated as a limit hit, and the legacy runner checks for a limit before it
  checks whether the task completed (`bin/farm-runner.sh`), so such a task is requeued.
- A pre-existing test flake is fixed: eleven `sed … | grep -q` assertions could fail under
  `pipefail` when `grep` exited before `sed` finished writing (11% on one CPU, reproduced on a
  clean clone of `main`). Only the `grep` form changed; ranges, patterns and meanings did not.
- State files are validated as integers before any arithmetic.
- Billing guard: `ANTHROPIC_API_KEY` and `ANTHROPIC_AUTH_TOKEN` do not reach launched `claude`
  processes unless the operator's own environment sets `FARM_ALLOW_API_BILLING=1`.

To build:

- A. Protected paths are resolved from `origin/<main>` (`git show`), not from the session's
  directory. An unresolvable ref denies. The plugin defaults apply only when the file is absent
  from that tree.
- Mandatory list. A built-in list is unioned with the project's file, so a repository can add
  protection but not remove it. It contains the existing defaults, `.agent-farm/**`,
  `docs/superpowers/handoffs/**` and `docs/superpowers/plans/**`. `.agent-farm/farm.env` matters
  most: the farm sources it as bash in its own process, so it can defeat any guard that runs
  after it, including the billing guard. It must only ever change through a human merge.
- B. `gh pr merge` is denied unless `gh pr checks --required` reports at least one required
  check, and denied when that cannot be determined. Every required check must be `pass`, or
  pending when the merge is `--auto`; a skipped required check does not count as passed. Merges
  with `--admin` are denied, and so is any merge that names a repository with `-R`/`--repo`,
  because the guard cannot tell whether it is the same one. Repositories
  with no required checks get pull requests that wait for a human; this is a behaviour change
  for such adopters.
- Merge target parsing. The existing gate takes the pull-request number from the command; for
  `gh pr merge <branch>`, `gh pr merge <url>` or flags before the number it can check the wrong
  pull request or none (`hooks/guard-bash.sh:153-162`). A merge is denied unless a number
  parses unambiguously.
- Direct pushes. The guard denies a farm agent's `git push` whose target is `main` or `master`;
  it cannot ask the remote which branch is the default. This is a tripwire; the boundary is
  branch protection, which the conductor checks (4.5).
- MCP: a new matcher in `hooks/hooks.json` and a guard branch deny `mcp__*` tool calls for farm
  agents.
- Notify: `$FARM_NOTIFY_CMD <event> <plan> <unit>`, read from the process environment only,
  never from a repository file, because the conductor executes it. Arguments are generated by
  the conductor; reason text arrives on stdin; it runs under `farm_timeout`. A failure or
  timeout is logged and never changes state. Unset means log only. It mirrors the
  planning consumer's notify dispatch. Events:
  - `unit-shipped`: the handoff is merged and the review record written; carries the handoff's
    `Operator actions pending` text.
  - `limit`: the conductor paused on a subscription limit and will resume by itself.
  - `awaiting-operator-merge`: a pull request touches a protected path, so only a human can
    merge it. The unit stays `doing`; the operator merges and runs the command again, with no
    answer needed.
  - `pause`: the plan loop cannot start its next unit because a precondition refused, for
    example an entry criterion that is `not met`. Nothing is wrong with a running session.
  - `stop`: a cap was reached or a validation failed; the unit is `escalated`.

  A lead has no way to ask the operator a question in the middle of a unit in increment 1.

Test policy for A and B. They change what existing guard assertions are set up against (the
source of the list, the fake `gh`). The operator delegated this decision. It is taken as: an
existing fixture may be extended so that an existing assertion keeps its meaning under the
stricter rule; no assertion is deleted or loosened; every pre-existing assertion that is touched
is listed in the handoff with its meaning before and after; an independent reviewer checks that
list.

### 4.4 Contract v2, minimum

Files under `contract/` in this repo.

Plan. The operator's format. Units are level-2 headings matching
`^## (M[0-9]+[a-z]?|PR [0-9]+|Iteration [0-9]+)([^A-Za-z0-9]|$)`, parsed fence-aware. (The
boundary is spelled out because `\b` is not portable to bash 3.2.) `Depends-on:` directly
under a heading is optional; the default is the previous unit. A plan must be on `origin/<main>`.

`farmctl conduct lint <plan>` prints the units and refuses a unit with no task headings, an
unknown dependency, a cycle, or the rename of a shipped unit.

Unit row, from `farmctl conduct status --json`: `id` (`<plan>#<unit>`), `plan`, `unit`, `title`,
`status`, `depends_on`, `claimed_by`, `stop_reason`, `prs`, `handoff_path`, `attempts`,
`owner_ref`, `usage`. `status` uses the existing vocabulary: `backlog`, `ready`, `doing`,
`review`, `shipped`, `escalated`, plus `shipped-unreviewed` (a handoff on main with no review
record).

Handoff. Path `docs/superpowers/handoffs/<plan basename>-<unit slug>-handoff.md`, computed by
the conductor. Validation is tolerant of the operator's real files: section names match with an
optional number and suffix. It runs in two phases, because the security review section is
written by the review session, not the lead. Phase one, on the lead's handoff pull request:
verification evidence, lessons learned, and an entry-criteria section for each dependent unit
with at least one row, where the leading token of a row's status is exactly `met`, `not met` or
`accepted`. Phase two, after the review session: the security review section is present and
phase one still holds. `not met` blocks the dependent unit; anything else fails validation.

`farmctl conduct adopt <plan> <unit> <handoff path>` lets the operator record an existing,
differently named handoff as shipped.

Review record. One JSON line in conductor state: unit, start and end SHA, review session id,
verdict, log path.

### 4.5 Conductor

`bin/farm-conduct.sh`, reached through `farmctl conduct`. Pure deciders with thin wrappers. It
sources `bin/farm-lib.sh` for the limit gate, the transient-error classifier, `farm_timeout`, the
worktree helpers, the log renderer and usage metrics, and launches sessions with `FARM_AGENT=1`.
It does not use the board, the runner, the QA role, the janitor or the scout.

`farmctl conduct run <plan> <unit>` refuses unless: lint passes; every dependency is shipped
with a review record or adopted; the dependency handoffs' entry criteria for this unit are all
`met` or `accepted`; the default branch requires pull requests and has at least one required
check; no other conductor run is active for this repository on this machine; and the project's
verify command passes on the current `origin/<main>` in a clean worktree.

The verify command is read from `.agent-farm/farm.env` on `origin/<main>`, parsed and not
sourced. Running it before the unit starts is what makes the contract stack-neutral: a wrong
command, such as the installer's seeded `npm run check` in a repository that is not JavaScript,
fails here instead of misleading a session, and a main branch that is already red is not handed
to a lead.

A stopped unit (`escalated`) restarts only when the operator runs the command again with an
answer; that resets its three counters.

Then:

1. Lead session. Prompt: a short fixed `prompts/unit.md`, the unit heading, the plan path, the
   dependency handoff paths, the handoff path to write, the verify command, and any operator
   answer. The lead follows the plan's own protocol, opens and merges its code PRs (each merge
   passes the guard and rule B), and opens a handoff PR that changes only the handoff file. It
   cannot merge that PR: the handoff directory is protected.
2. The conductor validates the handoff in the PR.
3. Review session. A fresh session reviews the unit's commit range, performs the security
   review, writes the `Security review` section into the handoff, and writes a verdict file:
   verdict, and counts of high, medium and low findings. The review method is written into the
   review prompt and applied to the already-merged commit range; `/security-review` is not the
   default, because it reviews the current branch's diff, which at this point is only the handoff.
4. The conductor merges the handoff PR only when the verdict is accept with no high and no
   medium finding, the PR changes only the handoff file, required checks pass, and the unit has
   no other pull request still open, so a unit can never ship while its code is unmerged or
   waiting for a human. It writes the review record and notifies `unit-shipped`.
5. Otherwise the findings go back to the lead once. A second rejection stops the unit.

A unit is complete when its handoff is on `origin/<main>` and the conductor holds a review
record for it.

Counters, each written before the session it counts is launched:

| Counter | Counts | Cap | At the cap |
|---|---|---|---|
| Rework | a review returning high or medium findings; or a session ending with no handoff and no evidence of progress | 1 | stop and notify |
| Continuation | a session ending without a handoff while git shows a newly merged PR or a new commit on the handoff branch | 2 | stop and notify |
| Interruption | a limit pause, a transient error, a restart | 3 | stop and notify |

They live in machine-level state outside the worktree and outside `FARM_STATE_DIR`
(`${XDG_STATE_HOME:-$HOME/.local/state}/agent-farm/<repo id>/conduct/`). This resists mistakes,
not a misbehaving session.

A limit pauses the conductor until the gate reopens and resumes the same session if S3 allows,
otherwise starts a fresh one from the work in progress. A session that left an open handoff
pull request is never classified as a limit hit, which keeps the conductor clear of the residue
in 4.3 C.

The verify command is project code that the conductor runs outside the guard. It is acceptable
only because it comes from a protected path on `origin/<main>`; the security reviews of the
units that add this call must cover it.

`Operator actions pending` is sent through the notify command and never blocks.

`farmctl conduct run <plan>` runs a plan's units in dependency order and stops at the first stop.

The guard must be proven present in every session the conductor starts. The conductor registers
the guard hook itself in the settings it passes to `claude`, reads the session's `system/init`
event, and ends the session at once if the guard is not listed there. A plugin that happens to
be enabled in the operator's own configuration is not relied on.

Conductor scenario tests live in their own test file and their own CI job, each unit's handoff
records how long its tests take, and the existing macOS job is not slowed: it already takes
about 32 of its 45 minutes.

Metrics per session, appended to the usage file: tokens in, out and cached, by model where the
stream reports it; wall-clock; PRs opened and merged; reviewer subagent dispatches; verify
command runs; guard denials; and a fingerprint of the session's `system/init` event (tools, MCP
servers, plugins, model, permission mode, API key source, version).

### 4.6 The planning consumer in increment 1

- The same billing guard at its four session launches.
- A contract test that feeds sample unit rows through the normalisation the consumer already
  applies to board tickets and asserts the fields it needs are present. It pins the row shape
  from the consumer's side without changing how the consumer plans.

Its planning, triage and board coupling are untouched.

### 4.7 Pilot

Step one, on this machine: a throwaway GitHub repository with a small plan of two units, one
required check, and a planted protected-path temptation. It proves the loop end to end with real
sessions, real PRs and a real merge gate, and it includes two deliberate merge attempts that the
guard must deny, so the pilot cannot pass without the gate firing live.

The repository must be able to enforce a pull-request rule and a required check. A private
repository needs a GitHub plan that can protect a private repository; otherwise the pilot uses a
public throwaway repository holding only synthetic content. The conductor refuses to run on a
private repository whose plan cannot protect it; that refusal is intended, because without required checks nothing stops an unverified merge.

Step two, started by the operator: one real unit of one real plan in a repository with required
checks.

The pilot is passed when the unit ships with a review record and no manual step other than the
start command, the operator actions the unit itself lists, and, in step one, the single human
merge and re-run that the planted protected-path change is there to force. Its metrics are the first real
numbers for tokens per shipped unit and are the baseline the later eval compares against.

## 5. Part II: direction, not to be planned from this document

Each of these gets its own spec after the pilot. The clause after each is what the final review
said that spec must fix.

- **Eval harness.** Executor interface, held-out checks, repetitions, benchmarks in several
  languages. Must give both arms the same plan, add a bare-model arm, and use a benchmark the
  bare arm fails; three runs cannot separate arms that differ less than the observed twofold
  spread.
- **Work items.** GitHub Issues as a one-way mirror of conductor state, with a label and
  comments as operator input. Not Trello: a new service and credentials on every machine, not
  linked to pull requests. A backend interface only once two real consumers exist. Must solve
  notification, because GitHub does not notify a user of their own account's activity.
- **A planning consumer on the contract.** Planner writes spec and plan; poll, plan and accept read unit
  rows. Needs a row schema compatible with its normaliser and an operator-approved rewording of
  its "no upfront decomposition" rule.
- **Scouts under supervision.** Several narrow roles that report findings and never create
  work: regression, security, production signals, follow-ups harvested from handoffs, drift.
  Must have deterministic fingerprints, and precision defined as operator-approved over
  operator-shown across at least ten decisions.
- **Parallel running.** Needs a machine-level gate and environment slots first; evidence
  gathered after a merge is not valid for concurrent units in one repository.
- **Unattended level.** Sessions under a separate Unix user, a least-privilege token, a second
  identity for approval, and the conductor doing every write and merge.
- **Deploy and health hooks.** Deploy status, health, rollback and production signals supplied
  by the project; stop new merges on regression.
- **Platforms without a local runtime.** Verification needs scarce remote environments, so the
  farm needs environment slots and a teardown sweep; where a deploy cannot be rolled back,
  production promotion stays a human step; sessions must be authenticated only to disposable
  environments, never to production.

## 6. Decisions

Taken here under the operator's instruction to act autonomously with independent review:

- Scope is cut to Part I, following the final review.
- No queue backend in increment 1; GitHub Issues later; not Trello.
- At this level the lead merges its own code PRs after CI, as in the operator's process. The
  conductor alone merges the handoff.
- Fixtures for fixes A and B may be extended under the test policy in 4.3.
- The board-based farm is frozen: shared-rail fixes only.
- The planning consumer gets the billing guard and a contract test now; its redesign waits for
  the pilot.

Still the operator's: a GitHub plan that can protect a private repository, or a public
throwaway repository, for the pilot (4.7); the real plan and unit for pilot step two; the
rewording of the planning consumer's decomposition rule.

## 7. Named and not built

A fix for defect D; a Trello backend; an own UI; stack presets; a per-PR approving session;
quota reservation for the operator's interactive work; automatic regression fixes.

Parsing `.agent-farm/farm.env` as data instead of sourcing it as bash. This is the only real fix
for a repository file defeating guards that run in the farm's own process (a function named
`builtin` in `farm.env` still defeats the billing guard). It changes how every legacy setting is
loaded, so it is its own change; until then the control is that the file is a protected path.
The conductor already parses the one value it needs instead of sourcing the file.

Deferred from increment 1 after planning showed their cost: making the shared limit gate keep
the longer of two gates, and locking the failstreak counter. Both live in functions the existing
suite extracts one at a time, so changing them touches dozens of pre-existing assertions, and a
single conductor run per repository does not need them. The conductor's own pause logic must
never shorten an existing gate; the shared functions stay as they are.

## 8. Unverified

- Everything the spikes in 4.2 exist to settle.
- `gh pr checks --required` output and exit codes when nothing is required or checks are pending.
- GitHub's behaviour for `--auto` merges when nothing is required.
- Behaviour on macOS of the code added on this branch.
- Every statement about platforms without a local runtime.
- The conductor itself: it is a design reviewed against code, and none of it has run.
