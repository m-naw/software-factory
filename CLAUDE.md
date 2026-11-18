# CLAUDE.md — working in the agent-farm repo

Guidance for contributors and for Claude sessions editing **this repository** (the plugin
source). It is not injected into running farm agents — that is `defaults/FARM.md`. Do not
confuse the two:

- **`defaults/FARM.md`** — the *runtime* operating constitution, appended to every farm
  agent's system prompt. Governs how agents behave when the farm runs.
- **`CLAUDE.md`** (this file) — how *you* change the plugin's own code safely.

## What this is

An installable Claude Code plugin that runs an autonomous, multi-agent software-development
farm. A file-based kanban board (`kanban-md`) coordinates implementer, QA, scout, and janitor
agents; `systemd --user` units supervise them. Two safety layers bound unattended runs: the
deterministic bash-safety **guard hook** (`hooks/guard-bash.sh`, a `PreToolUse` firewall) and
the injected **`FARM.md`** constitution. The engine is **pure bash** — no build step, no
package manager, no compiled artifacts. See `README.md` for install/operate; this file is the
contributor's map.

## Layout

```text
bin/        engine — farmctl, farm-runner.sh, farm-scout.sh, farm-janitor.sh, farm-lib.sh,
            and the Plan Conductor: farm-conduct.sh, farm-conduct-lib.sh
hooks/      guard-bash.sh + hooks.json (the PreToolUse command firewall)
engine/     install.sh, systemd/ (user units), tests/ (the safety suite)
defaults/   generic config injected at runtime — FARM.md, farm.env, protected-paths.txt, prompts/
templates/  per-project scaffolds the installer copies into an adopting repo
skills/     the agent-farm:* skills (namespaced SKILL.md files)
contract/   what `farmctl conduct` reads and writes (README.md) and its fixtures
```

`bin/farm-lib.sh` is the shared library — **sourced, never executed** (no shebang, no `+x`).
Every other farm script in `bin/` sources it, inherits its `set -euo pipefail`, and derives paths from
`REPO_DIR`/`STATE_DIR`. Per-project config resolves through `farm_resolve <name>`: the adopting
repo's `.agent-farm/<name>` wins, else the plugin `defaults/`.

The conductor is the exception. `farmctl` hands `conduct` to `bin/farm-conduct.sh` before it
sources `farm-lib.sh`, and `farm-conduct.sh` never sources it either: a repository's
`.agent-farm/farm.env` is bash, and it must not run in the conductor. It calls the few `farm-lib.sh`
functions it needs in a child process (`farm_lib_call`). `bin/farm-conduct-lib.sh` is sourced only
(no shebang, no `+x`) and holds pure decision functions. A test in `engine/tests/conduct.sh` fails
if `farm-conduct.sh` sources `farm-lib.sh`.

## Running the tests

```bash
engine/tests/run.sh          # the whole safety suite — exits non-zero on any failure
engine/tests/conduct.sh      # the Plan Conductor suite (CONDUCT_TEST_TIER=smoke for the macOS tier)
```

`run.sh` holds the safety suite: the guard hook, the merge gate and the farm engine. `conduct.sh`
holds everything for `farmctl conduct`: assertions on the decision functions of
`bin/farm-conduct-lib.sh`, and scenarios that run the conductor against the fake `claude` and `gh`
in `engine/tests/stubs/conduct/`. Conductor tests go in `conduct.sh`, not `run.sh`.

No test framework. Both are plain bash scripts; `run.sh` is also run by `farmctl audit` and
by CI (`.github/workflows/farm-ci.yml`). Read the header of `engine/tests/run.sh` before adding
tests. Conventions:

- Helpers: `ok`/`nope "<desc>"` for assertions; `t`/`te` drive the guard hook with a JSON tool
  call; `bash_cmd` builds the Bash-tool payload.
- Source `farm-lib.sh` **in its own subshell** so its `set -e` can never abort the harness.
- Pure decision functions (`_qa_gate_decide`, `_ci_rescue_decide`, `resolve_*`) are unit-tested
  directly, separate from the side-effecting shell that calls them. Keep new logic in that
  shape: a pure decider + a thin wrapper, so it stays testable without systemd or a live board.

**CI gates.** PRs and pushes run the Linux jobs `lint-and-test` and `conduct-linux`. `conduct-macos`
(stock bash 3.2, BSD userland, about a minute) runs nightly and on
`gh workflow run farm-ci.yml -f macos=true --ref <branch>`; `test-macos` (the full farm suite, ~37 min)
runs nightly and on `-f macos_full=true`, once at the end of a plan increment, not per unit.
This gives up catching farm-suite (`run.sh`) bash 3.2/BSD regressions per unit: they surface nightly or at the increment end.
Rule: per unit, before merging a change to `bin/`, `hooks/` or `engine/`, dispatch
`gh workflow run farm-ci.yml -f macos=true --ref <branch>` and wait for `conduct-macos` green.

## Shellcheck

CI runs, and every change must pass:

```bash
shellcheck -x -S warning bin/*.sh bin/farmctl hooks/guard-bash.sh engine/install.sh
shellcheck -S warning engine/tests/run.sh engine/tests/conduct.sh
```

`-x` (follow `source`), `-S warning` (warning severity floor). `engine/tests/run.sh` is linted
separately **without** `-x`: it sources `bin/farm-lib.sh` 61 times (once per test subshell), and
`-x` re-follows/re-analyzes that 1500+-line file on every source — superlinear, and it OOM-kills
shellcheck (>6min). `farm-lib.sh` is already covered by the `-x` pass above. Fix findings; don't
blanket-disable. A narrow `# shellcheck disable=SCxxxx` with a reason is acceptable where the
code is provably correct (see the existing `SC2053` glob-match disable in the guard).

## Vocabulary you must preserve

- **Board columns:** `backlog → ready → doing → review → shipped`, plus **`escalated`**
  (blocked pending a supervisor decision — supervisor-agnostic) and `archived` (terminal). The
  escalation status is `escalated` — supervisor-agnostic; don't reintroduce an older name.
- **Protected paths:** globs in `defaults/protected-paths.txt` (or the repo's
  `.agent-farm/protected-paths.txt` override). A PR touching one cannot be auto-merged — the
  guard blocks `gh pr merge` and the task is escalated, green CI or not. **The merge gate fails
  closed:** if the changed-file list can't be determined, the merge is blocked.
- **Conductor mode** (`farmctl conduct`). The merge gate's protected list is the mandatory list in
  `hooks/guard-bash.sh` plus `.agent-farm/protected-paths.txt` as committed on `origin/<main>`
  (the plugin default only when that file is absent), never the work tree's copy. A lead merges its
  own code pull requests after the required checks pass. The guard blocks a merge of any pull
  request that touches a protected path, and `docs/superpowers/handoffs/*` is on the mandatory
  list, so the conductor alone merges handoff pull requests (`conduct_merge_handoff`; the guard is a
  tripwire, branch protection is the boundary); the unit review session is the independent actor
  between the lead and that merge. `CLAUDE.md` and `AGENTS.md` at any depth are on the mandatory
  list too: the review session loads them, so a lead's pull request must not change them. Conductor lead sessions carry `defaults/prompts/unit.md` and review
  sessions `defaults/prompts/unit-review.md`, instead of `FARM.md`; a repository cannot override either.
- **Two-strike / QA invariant:** one rework round with the same tier; a second rejection
  escalates to a higher tier — never loop a failing tier on the same task (`qa_gate`,
  `_qa_gate_decide`, `handle_failure`).

## What NOT to do

- **Never weaken the rails.** The guard hook, the merge gate, protected-paths enforcement, the
  fail-closed behavior, and the two-strike/QA invariants are load-bearing safety properties.
  Changing them to make a test or a run pass is a regression, not a fix.
- **Never edit a test to make CI green.** A failing test is a regression until proven otherwise.
- **No direct pushes to `main`** — every change ships via PR with green CI (the guard forbids
  force-push and main deletion outright).
- **Don't add a build step or runtime dependencies.** The engine stays pure bash; the plugin
  manifest declares no hard `dependencies` on purpose (see README's companion-plugins note).
- **Keep `farm-lib.sh` sourced-only** (no shebang, no `+x`) and preserve the pure-decider /
  thin-wrapper split so the safety logic stays unit-testable.

## Shipping a change

1. Branch, implement test-first, run `engine/tests/run.sh`, `engine/tests/conduct.sh` and the
   shellcheck lines above — all green — before you claim done.
2. Push the branch, open a PR, watch `farm-ci` go green (for `bin/`, `hooks/`, `engine/` changes also dispatch `-f macos=true` on the branch and wait for `conduct-macos` green; `-f macos_full=true` only at the end of a plan increment).
3. Squash-merge only when finished and no human judgment is needed; otherwise leave it for review.
