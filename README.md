# Software Factory

Software Factory is an installable [Claude Code](https://docs.claude.com/en/docs/claude-code) plugin
for running coding agents on your repository, on a Claude subscription (not API billing). It was
called agent-farm before 0.4.0. Paths, commands and environment variables still use the agent-farm/farm
names (`.agent-farm/`, `farmctl`, `FARM_*`); renaming them is planned with a migration. It has two
ways of working:

- **The conductor (`farmctl conduct`) — use this.** You write a spec and a plan; the conductor carries
  the plan's units one at a time: a lead session implements and merges its code after the required
  checks pass, an independent review session checks the work, and the conductor merges the unit's
  handoff. It has been run end to end on real GitHub with real sessions; both merge canaries were
  denied live. Start at
  [Quick start](#quick-start-conducting-a-plan).
- **The board farm — frozen.** The original design below: parallel implementer, QA, scout and
  janitor agents coordinated by a kanban board. It still installs and passes its tests, but it gets
  only shared safety fixes; its future (replaced by the conductor as executor, inside a role-based
  "software factory") is open work for Part II
  ([spec](docs/superpowers/specs/2026-11-12-iteration-conductor-design.md), section 5).

Both share the **guard hook** (`hooks/guard-bash.sh`, a `PreToolUse` firewall): a tripwire against
known-bad commands. Branch protection on GitHub is the real boundary.

## Quick start: conducting a plan

One-time setup of a repository (details in [Conducting a plan](#conducting-a-plan)):

1. **GitHub.** The repository needs a ruleset (or branch protection) on the default branch that
   requires pull requests and at least one required status check that **also runs on docs-only
   changes** (handoff pull requests change only docs), **pinned to the app that runs it** (for
   GitHub Actions, `integration_id` 15368) so a token cannot forge it, with no bypass for you. A
   private repository needs a GitHub plan that can protect it; otherwise the conductor refuses, by
   design.
2. **Plugin.** Install it (see [Install](#install--two-steps)); after every update, check the cache
   against the checkout with `diff -r` (updates are keyed on the plugin version).
3. **Repository config.** Run `software-factory:agent-farm-init` and choose conductor only, or run
   the installer yourself:
   `"${CLAUDE_PLUGIN_ROOT}"/engine/install.sh --init-project <repo> --conductor-only --verify-cmd '<your test command>'`.
   It writes only `.agent-farm/farm.env` (`FARM_VERIFY_CMD`, which must pass from a clean clone) and
   adds `.farm-worktrees/` and `.agent-farm/state/` to `.gitignore`: no board, no supervision units,
   no `kanban-md`. Commit both files, with a project `CLAUDE.md`, by pull request. (The full init in
   [Install](#install--two-steps) sets up the board farm.)
4. **Notifications.** Set `FARM_NOTIFY_CMD` in your own environment (never in the repository): see
   [Notifications](#notifications).

For each piece of work:

1. **Spec**, with `superpowers:brainstorming`, under `docs/superpowers/specs/`.
2. **Plan**, with `superpowers:writing-plans`, then the `software-factory:conduct-plan` skill and
   [`templates/plan-template.md`](templates/plan-template.md) for the conductor's format: units
   (`## M1 — …`), a `**Spec:**` link, the handoff sections. The plan lives under
   `docs/superpowers/plans/`.
3. `farmctl conduct lint <plan>` must exit 0. Merge the spec and the plan (your merge: plans are
   protected).
4. Run it, in `tmux`: `FARM_REPO_DIR=<clone> farmctl conduct run <plan>` (or `… <plan> <unit>`).
5. Answer when it stops. `awaiting-operator-merge` means a pull request touches a protected path
   (for example `CLAUDE.md`): review it, merge it yourself, and run the same command again. `stop`
   means a cap or a validation failed: read the reason in `farmctl conduct status <plan>`.

What the pilots taught (keep these in mind when writing a plan):

- **A unit must not change CI or guard configuration** (`.github/workflows/`, `CODEOWNERS`,
  `.claude/settings*`, `.agent-farm/protected-paths.txt`, `.agent-farm/farm.env`, the plugin's hooks):
  the guard blocks the write itself, the lead stops (`guard-blocked`). Make such a change yourself.
- **Choose the model per run.** Lead and review default to Opus at high effort. For small units,
  `CONDUCT_LEAD_MODEL=sonnet CONDUCT_LEAD_EFFORT=medium CONDUCT_REVIEW_MODEL=sonnet
  CONDUCT_REVIEW_EFFORT=medium` shipped the pilot's units at about 0.44 million tokens each (Opus/high on
  other, equally trivial units: about 1.09 million; not like for like). Most tokens are a fixed ~22 thousand-token context re-read every turn, so
  fewer turns matter more than shorter answers.
- **One unit fits one session.** Bigger work is more units, not a longer one.
- Per-session tokens, wall time and an API-equivalent cost are in
  `${XDG_STATE_HOME:-~/.local/state}/agent-farm/<owner>__<repo>/conduct/usage.jsonl` and in `farmctl conduct status <plan> --json`.

## The board farm (frozen)

A file-based kanban board (`kanban-md`)
coordinates implementer, QA, scout, and janitor agents; platform-native supervision keeps them
running (systemd `--user` units on Linux, launchd agents on macOS) so work continues across logout
and reboot. Two safety layers keep unattended runs bounded: a
deterministic bash-safety **guard hook** (a `PreToolUse` command firewall) and an injected
operating constitution, **`FARM.md`**, that gives every agent the same rules — tiered delegation,
the review invariant, Two-Actor review, a TDD/verify baseline, and hard escalation triggers.

> Work flows `backlog → ready → doing → review → shipped`. One task = one pull request.

## Requirements

The farm runs on **Linux and macOS**, out of the box. Supervision is platform-native and picked
automatically: **systemd `--user`** units on Linux (linger survives SSH disconnect), **launchd**
LaunchAgents on macOS (per-user, survive logout). You need, on the host that runs the farm:

- **Linux:** `systemd --user` with linger available (`loginctl enable-linger`).
  **macOS:** nothing extra — launchd is built in; agents install to `~/Library/LaunchAgents`.
- `git`, `tmux`, `curl`, `jq`, `tar` (macOS: `brew install git tmux jq gh`; `curl`/`tar` ship with macOS)
- [`gh`](https://cli.github.com/) (GitHub CLI), **authenticated** to the target repo
- the `claude` CLI, **logged in** (subscription auth — not a stray `ANTHROPIC_API_KEY`)
- **bash** — the engine is pure bash and runs on macOS's stock bash 3.2 (no Homebrew bash needed)

`kanban-md` ([`antopolskiy/kanban-md`](https://github.com/antopolskiy/kanban-md)):
- **Linux** — `install.sh` downloads and installs the pinned release for you.
- **macOS** — install it yourself first, then run `install.sh` — it detects it and continues.
  The reliable way is from source (note the `/cmd/kanban-md` package path — the module root has no
  installable package):
  ```bash
  go install github.com/antopolskiy/kanban-md/cmd/kanban-md@v0.33.0
  # then ensure Go's bin dir is on PATH:  export PATH="$(go env GOPATH)/bin:$PATH"
  ```
  A darwin release build works too. (`install.sh` won't guess a macOS binary; the pinned release
  asset is a Linux tarball. A source build reports its version as `dev` — cosmetic; nothing gates
  on it.)

## ⚠️ Security & isolation — read before running

Farm agents run **unattended** with `--dangerously-skip-permissions` — no per-command approval
prompts. At runtime they are bounded **only** by the guard hook (a deterministic `PreToolUse`
firewall that blocks known-fatal commands) and the injected `FARM.md` rules. **That is a layer, not
a jail.** The guard catches the dumb-but-fatal cases cheaply; it is not a sandbox and does not try
to be one.

So the real safety boundary is **where you run it**. Run the farm on a host whose blast radius you
accept:

- **Prefer an isolated environment** — a dedicated machine, VM, or container — not your primary dev
  box. In a VM/container, the worst a runaway command can do is scoped to the sandbox.
- **Scoped GitHub access** — a dedicated `gh` machine-user authenticated to *only* the target repo,
  not your personal token. Add **branch protection + CODEOWNERS** on your `protected-paths.txt`
  surfaces so agents cannot merge safety-critical changes even in principle.
- **No cloud credentials on the box.** The guard blocks common destructive cloud CLIs, but *absence
  is the real control* — an agent cannot destroy or exfiltrate what isn't there. Keep AWS/GCP/etc.
  creds off the machine.
- **No `ANTHROPIC_API_KEY` in the environment** — use subscription auth via `claude` login (a stray
  key would override it and bill/behave differently).

Treat the guard hook, the merge gate, and `FARM.md` as **defense-in-depth on top of** isolation —
not a substitute for it. If you would not hand a new contractor an unsupervised shell on the box,
don't run the farm there.

## What it assumes (project fit)

- **GitHub PR workflow — required.** The farm's model is *one task = one pull request*, driven
  through `gh` (`pr create/view/checks/merge`, `api repos`). You need a GitHub repo you can push to
  and `gh` authenticated to it. This is not optional.
- **Required status checks — needed for agents to merge.** The guard lets a farm agent merge a PR
  only when `gh pr checks --required` reports at least one required check and every one passed
  (pending is accepted only for `gh pr merge --auto` pinned to the PR's head; skipped does not count).
  In a repository with no required check, the farm still works, but its pull requests wait for a
  human to merge them. With required checks, the janitor's CI-rescue pass also re-drives PRs whose
  checks are red or behind main.
- **Updating the plugin updates every farm on the machine.** The guard runs from the installed
  plugin, so updating it applies fixes A (protected paths read from `origin`'s default branch) and B
  (required checks) and the rule that denies `mcp__*` tools to farm agents to every farm at once.
- **Build/test commands default to npm/JS**, and nothing else in the engine assumes JavaScript. The
  defaults are `FARM_VERIFY_CMD="npm run check"` and `FARM_TEST_CMD="npm run test"`; set them in
  `.agent-farm/farm.env` for any stack (`cargo test`, `pytest`, `make check`, …). Two env vars, no
  deeper coupling.

## Install — two steps

Installing the plugin gives you the tooling. It does **not** start a farm. You need both steps.

### Step 1 — install the plugin (tooling)

```text
/plugin marketplace add m-naw/software-factory
/plugin install software-factory@software-factory
```

`software-factory` is both the plugin and its marketplace. If the repo is private, your
`git`/`gh` must be authenticated to it. This step provides the skills (`software-factory:*`), the guard
hook, the engine scripts, and the `FARM.md` default.

### Step 2 — bootstrap the farm in your repo (running infrastructure)

Inside Claude Code, from your project, run the init skill (recommended — it resolves the plugin
path for you):

```text
/software-factory:agent-farm-init
```

Or run the installer directly. Inside Claude Code the plugin path is `${CLAUDE_PLUGIN_ROOT}`:

```bash
"${CLAUDE_PLUGIN_ROOT}"/engine/install.sh --init-project "$CLAUDE_PROJECT_DIR"
```

`install.sh` is idempotent. It installs `kanban-md` (Linux; on macOS you install it first),
initializes the board with the farm columns, installs the `kanban-md` skills, scaffolds
`.agent-farm/`, seeds `.gitignore`, and installs the supervision units — **systemd user units +
PATH drop-ins + linger on Linux, launchd LaunchAgents in `~/Library/LaunchAgents` on macOS**. It
also runs against an adopting repo: pass `--init-project <repo>` (the init skill fills in
`$CLAUDE_PROJECT_DIR`) so `.agent-farm/` and the board scaffold into *that* repo, not the plugin.

`farmctl` and the other engine scripts live in the plugin's `bin/`. The installer prints the
absolute path; for a bare `farmctl` add that `bin/` directory to your `PATH`.

## Configure — the `.agent-farm/` layer

Init scaffolds a per-project config directory. Edit these for your project (they are never
clobbered on re-run):

| File | What to set |
| --- | --- |
| `.agent-farm/protected-paths.txt` | Your safety-critical globs (auth, payments, migrations, data-deletion, CI). The guard hook blocks edits to them; they also gate auto-merge and force higher-tier review. The merge gate reads this file as committed on `origin/<main>` and adds a mandatory list that no project file can remove (including `.agent-farm/*`, `docs/superpowers/handoffs/*`, `docs/superpowers/plans/*`, and `CLAUDE.md`, `CLAUDE.local.md` and `AGENTS.md` at any depth). Files that a `CLAUDE.md` imports with `@path` are not protected by this list; a project lists them in `.agent-farm/protected-paths.txt`. Replace the `TODO(operator)` placeholders. |
| `.agent-farm/farm.env` | `FARM_VERIFY_CMD` / `FARM_TEST_CMD` for your stack (defaults: `npm run check` / `npm run test`). Optional `FARM_SAFETY_KEYWORDS_RE` forces heavy-pipeline (opus) routing for tasks whose text matches your domain's safety vocabulary — it is a tiering floor, NOT a guard-hook command firewall. |
| `.agent-farm/FARM.md` | The farm's operating constitution, seeded from the plugin default. Injected into every agent. Edit to extend for your project. |
| `.agent-farm/prompts/{scout,implementer,qa}.md` | Optional per-role overrides. Fill the PROJECT DOMAIN INVARIANTS block with your safety-critical surfaces. Copy from the plugin's `templates/project-prompts/` as a starting point. |

**Precedence.** For any config or prompt file the engine reads `.agent-farm/<file>` from your repo
if present, else the plugin default (via `farm_resolve`).

**Tuning knobs.** Everything below is an environment override — set it in `.agent-farm/farm.env`
(sourced by every farm process). Defaults are committed in `bin/farm-lib.sh`; you only add a line
to change one.

| Knob | Default | What it controls |
| --- | --- | --- |
| `FARM_VERIFY_CMD` / `FARM_TEST_CMD` | `npm run check` / `npm run test` | Verification + test commands agents run before declaring work done. |
| `IMPL_MODEL` / `QA_MODEL` / `SCOUT_MODEL` | `opus` | Model per role for default (heavy) tasks. |
| `IMPL_MODEL_LIGHT` / `QA_MODEL_LIGHT` | `sonnet` | Model for `tier:light` tasks. Protected-path tasks always get `opus` QA (hard floor, not overridable). |
| `IMPL_EFFORT` / `QA_EFFORT` / `SCOUT_EFFORT` | `medium` / `high` / `high` | Reasoning-effort per role. |
| `MAIN_BRANCH` | `main` | The branch PRs target and merge into. |
| `POLL_SECONDS` / `QA_POLL_SECONDS` | `60` / `30` | How often an idle runner / QA re-checks the board. |
| `CLAIM_REFRESH_SECONDS` | `900` | How often a long-running claim is refreshed before it expires. |
| `CI_WATCH_TIMEOUT_SECONDS` | `2700` | How long a post-merge CI watcher waits before giving up. |
| `FARM_MAX_FAILSTREAK` / `INFRA_MAX_STREAK` | `5` / `8` | Consecutive-failure ceilings that pause a runner (real vs. infra failures). |
| `INFRA_MAX_TASK_RETRIES` | `3` | Times one task is retried through transient infra errors before it escalates. |
| `EPIC_MAX_CHILDREN` | `12` | Max phase-children a single epic may decompose into. |
| `FARM_SAFETY_KEYWORDS_RE` | _(unset)_ | Tiering soft-floor: a task whose text matches this regex is routed to the heavy (opus) pipeline. It does NOT extend the guard hook / command firewall. |

## How governance reaches agents

`FARM.md` is passed to every farm agent with `--append-system-prompt-file`, so the farm's rules
hold even on a repo that has no `CLAUDE.md`. `FARM.md` is self-contained: with only that file an
agent knows how to operate the farm safely. Your project's own `CLAUDE.md` (if any) and the
per-role prompts layer project-specifics on top — they refine the baseline, never weaken it.

## Companion plugins (recommended, optional)

The role prompts use the [`superpowers`](https://github.com/obra/superpowers) skill suite
(brainstorming, writing-plans, test-driven-development, systematic-debugging,
requesting-code-review, verification-before-completion, subagent-driven-development) and
`frontend-design` for UI work. These deepen the workflow but are **not required** — the baseline
discipline (TDD, Two-Actor review, verification-before-completion) is stated as binding rules in
`FARM.md` and holds whether or not they are installed. The prompts degrade gracefully when a
companion skill is absent.

Both are published under the `claude-plugins-official` marketplace. Install each:

```text
/plugin install superpowers@claude-plugins-official
/plugin install frontend-design@claude-plugins-official
```

(These are **not** declared as `dependencies` in this plugin's manifest on purpose — a hard
`dependencies` entry has no "optional" mode and would fail the plugin's own load if the companion
were absent or lived in a different marketplace. They stay README-level recommendations; `FARM.md`
carries the baseline rules regardless.)

## Operating the farm

```bash
farmctl start [IMPL_N] [QA_N]   # start implementers + QA + scout/janitor timers (default 2 1)
farmctl status                  # units + board summary + per-agent "what now"
farmctl scale <role> <N>        # e.g. farmctl scale implementer 3
farmctl pause | resume          # soft-pause: runners finish the current task, then idle
farmctl dash                    # tmux dashboard: board TUI + live tail + stats
farmctl audit                   # verify safety assumptions on THIS box (creds, hook, tests)
farmctl stop                    # stop everything; in-flight tasks are requeued
```

Additional subcommands: `logs`, `tail`, `release <task-id>`, `scout-now`, `metrics`.

**Board columns:** `backlog → ready → doing → review → shipped`, plus `escalated`
(blocked pending a supervisor decision — supervisor-agnostic: a human on the board, or an
external triage layer; the farm doesn't care which) and `archived` (terminal).

> **Upgrade note (2026-07):** the escalation column was renamed from its pre-public name to
> `escalated`. Existing boards are migrated automatically and idempotently by re-running
> `engine/install.sh` (renames the column in `kanban/config.yml` and sweeps any tickets still
> carrying the old status). Implementers own a task in `doing` via a claim; QA owns `review`
(CI, in-place fixes, squash-merge); the janitor archives shipped+merged tasks.

To drive the farm as the operator, use the `software-factory:farm-orchestration` skill. To file work,
use `software-factory:task-new` / `software-factory:bug-new` (or `/software-factory:task-new <description>`).

## Conducting a plan

`farmctl conduct` runs the units of a written plan, one at a time, without a board. A plan is a
markdown file on the default branch; each level-2 heading such as `## M1 — Greeting`, `## PR 3` or
`## Iteration 2` is a unit, and its `### Task ...` headings are its tasks (the exact rules are in
[`contract/README.md`](contract/README.md)). It is for a supervised run: you start it, watch it, and
answer when it stops.

To write a plan the conductor accepts, start from [`templates/plan-template.md`](templates/plan-template.md)
and the `software-factory:conduct-plan` skill (a format adapter; the planning itself stays with
`superpowers:writing-plans`). A plan pull request merges only after `farmctl conduct lint` exits 0.

**What one unit run does**

1. It checks every precondition below. If one fails it prints the code and exits 1.
2. It starts a lead session (Opus by default) in its own work tree under `.farm-worktrees/`. The lead
   does the unit's tasks and opens code pull requests, which it merges itself once the required checks pass.
3. The lead ends by opening one handoff pull request that changes only the unit's handoff file.
4. A fresh review session reads the work and gives a verdict. A reject sends the unit back to the lead
   (once).
5. The conductor, not the lead, merges the handoff pull request after the verify command and the required
   checks pass (the guard is a tripwire; branch protection is the boundary). Then the unit is `shipped` and
   the next unit may start.

### Preconditions

The conductor refuses to start a unit until all of these hold. The refusal names a code.

| Precondition | How to meet it |
| --- | --- |
| The plan is on the default branch of `origin` and passes `lint` (code `lint`). | Merge the plan. Run `farmctl conduct lint <plan>`. |
| The plan's path matches a protected glob on the default branch (`plan-unprotected`), so the guard blocks any lead merge that rewrites it. `lint` and `run` check it. | Move the plan under `docs/superpowers/plans/` or list it in `.agent-farm/protected-paths.txt`. |
| The plan links its spec: a line starting `**Spec:**` before the first unit heading (outside fenced code) holds a markdown link to the spec, resolved from the plan's directory, or a backticked repository-relative path, and that file is on the default branch. `lint` and `run` check it (`no-spec`; `spec-bad-path` for a URL, an absolute path or a path outside the repository; `spec-missing` when the file is not on the default branch, even if your work tree has it). | Add `**Spec:** [spec](../specs/<name>.md)` under the plan's title and merge the spec. |
| Every unit it depends on is `shipped` (`dependency-not-shipped`), and the entry-criteria table in each dependency's handoff has no `not met` row (`entry-criteria-blocked`, or `entry-criteria-invalid` when a row is unreadable). | Ship or `adopt` the dependency. Resolve the `not met` row, then run again. |
| `.agent-farm/farm.env` on the default branch sets `FARM_VERIFY_CMD` (`verify-cmd-unset`). | Commit it. |
| `FARM_VERIFY_CMD` passes from a clean checkout of the default branch within `CONDUCT_VERIFY_TIMEOUT_SECONDS` (`verify-failed`, `verify-timeout`). The conductor runs it before every unit and again before every handoff merge. | The installer seeds `npm run check`: replace it in a repository that is not JavaScript. A command that needs installed dependencies or running services must set them up itself. |
| The default branch has a ruleset or branch protection that requires pull requests and requires at least one status check with no path filter, and your own token cannot bypass it (`no-pull-request-rule`, `no-required-check`, `admin-bypass`). | Set the rule on GitHub. For a ruleset, the bypass list must not include you. |
| GitHub can answer for the branch (`branch-rules-undetermined` otherwise). | A private repository on a GitHub plan that cannot protect it gets this refusal. That is by design: use a plan that can, or do not conduct that repository. |
| The guard's default branch is `origin`'s own (`main-branch-mismatch`), and the guard hook blocks a destructive command in a self-test (`guard-self-test`). | Fix `refs/remotes/origin/HEAD` (`git remote set-head origin --auto`); check that the plugin is installed. |
| No other conductor holds the repository (`conductor-active`) and no session of the unit is still running (`session-alive`). | Wait for it, or stop it. |

Also keep `.farm-worktrees/` and `.agent-farm/state/` in `.gitignore` (the installer adds both); the
conductor does not check this. No board is needed: `farmctl conduct` does not read or write `kanban/`.

### The four commands

Every example sets `FARM_REPO_DIR` (or run inside the repository). `<plan>` is the plan's path
relative to the repository root.

```bash
export FARM_REPO_DIR=/path/to/example-repo
P=docs/superpowers/plans/example-plan.md

farmctl conduct lint "$P"                          # the units, or why the plan is refused
farmctl conduct status "$P" [--json]               # one row per unit
farmctl conduct adopt "$P" M1 docs/superpowers/handoffs/older-name.md   # record an existing handoff
farmctl conduct run "$P" M1                        # carry one unit to a reviewed, merged handoff
farmctl conduct run "$P"                           # run every unit in dependency order
farmctl conduct run "$P" M1 --answer "use approach B"   # restart a stopped unit
```

`lint` prints `<plan>#<unit>`, the title and the dependencies, one line per unit. `status` prints
`<unit>`, its status and its title. For a two-unit plan on a fresh repository:

```text
$ farmctl conduct lint "$P"
docs/superpowers/plans/example-plan.md#M1	Greeting	depends on: none
docs/superpowers/plans/example-plan.md#M2	Farewell	depends on: M1
$ farmctl conduct status "$P"
M1	ready	Greeting
M2	backlog	Farewell
```

With `--json`, `status` prints the rows described in
[`contract/README.md`](contract/README.md), including `attempts` (the three counters) and `usage`.

**What `lint` refuses (exit 1).** No units; a duplicate unit; a dependency that is not a unit; a
dependency cycle; a unit with no tasks; a shipped unit that the plan no longer has. A heading with no
task gets `no-tasks`. Delete the heading, or give the next unit an explicit `Depends-on:` line.

A unit depends on the previous unit unless the line under its heading says `Depends-on: none` or names
others (`Depends-on: M1, M2`).

A plan's header links its spec, for example:

```markdown
# Example plan

**Spec:** [`docs/superpowers/specs/example-spec.md`](../specs/example-spec.md)
```

### Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Done. For `run <plan>`: every unit is shipped. |
| 1 | Refused, or a usage or input error. The message names the code. |
| 2 | Environment error: no repository, no `origin`, `origin` unreadable or changed since the first run (`origin-changed`), repo-local git config the conductor does not allow (`git-local-config`), a state file that cannot be written. |
| 3 | The run ended with a unit stopped (`escalated`) or waiting for you, or the plan loop paused (a refused precondition, or the plan changed on the default branch). |

### Counters and caps

Each unit has three counters in its state directory. Each is bumped before the session it counts.

| Counter | Counts | Cap | Stop reason at the cap |
| --- | --- | --- | --- |
| `rework` | a lead session after the review rejected the handoff, the handoff failed validation, or the lead ended with no progress and no guard denial | 1 | `cap-rework` |
| `continuation` | a lead session started because the last one made progress but opened no handoff | 2 | `cap-continuation` |
| `interruption` | a session resumed after a usage limit, a transient error or a restart | 3 | `cap-interruption` |

`attempts` also counts every session but has no cap. Other stop reasons: `review-no-verdict`,
`guard-not-loaded`, `settings-tampered`, `shipped-unreviewed`, `handoff-merge-failed`,
`required-checks-not-reported`, `invalid-state`, and `guard-blocked: <the first denial>` (a lead
ended with no progress after the guard denied a command: a rework session would meet the same
denial, so the unit stops at once). A stopped unit has status `escalated` and its stop reason
is in `status --json` (`stop_reason`) and in the unit's `stop_reason` file.

### Notifications

The conductor sends five events. Each fires in one kind of situation only; everything else is logged.

| Event | Fires when |
| --- | --- |
| `unit-shipped` | The handoff pull request is merged and the review record is written. Stdin carries the handoff's "Operator actions pending" text. |
| `limit` | A session ended on a subscription limit. The conductor waits for the limit gate and resumes by itself. |
| `awaiting-operator-merge` | A pull request of the unit touches a protected path and is open. The unit stays `doing`. You merge it and run the command again, with no answer. |
| `pause` | The plan loop cannot start its next unit because a precondition refused, or because the plan changed on the default branch since the loop started (`plan-changed`, naming the old and new blob). Nothing is wrong with a running session. |
| `stop` | A cap was reached, a validation failed, or the guard blocked a lead that then made no progress. The unit is `escalated`. |

Before each dispatch the conductor appends `<timestamp> <event> <plan> <unit>` to
`notifications.log` in the conductor directory. If you set `FARM_NOTIFY_CMD` in the environment of
`farmctl`, it is then run as `<cmd> <event> <plan> <unit>` with the reason on stdin, bounded by
`FARM_NOTIFY_TIMEOUT_SECONDS` (default 20). It is read from the environment only, never from
`farm.env`. A failing command is logged and ignored. The reason can hold text a session wrote: for
`unit-shipped` it is the "Operator actions pending" section of the handoff the lead wrote. Treat it as
untrusted. An example script, which strips control characters:

```bash
#!/usr/bin/env bash
# Called as: notify.sh <event> <plan> <unit>; the reason is on stdin.
set -u
event="$1"; plan="$2"; unit="$3"
reason="$(head -c 2000 | tr -d '\000-\010\013-\037\177')"
{
  printf '%s %s#%s\n' "$event" "$plan" "$unit"
  printf '%s\n' "$reason"
} >> "$HOME/farm-events.txt"
# Replace the redirect with your own channel (mail, chat webhook).
```

`farm_notify` runs the path directly, so make it executable:

```bash
chmod +x "$HOME/bin/notify.sh"
export FARM_NOTIFY_CMD="$HOME/bin/notify.sh"
```

### Where things live

Conductor state is outside the repository, in
`${XDG_STATE_HOME:-$HOME/.local/state}/agent-farm/<owner>__<repo>/conduct/`:

| Path | Holds |
| --- | --- |
| `reviews.jsonl`, `adopted.jsonl` | One line per reviewed or adopted unit. A unit with one of these and its handoff on the default branch is `shipped`. |
| `usage.jsonl` | One line per session (tokens by model, wall time, pull requests opened and merged) and one per verify run. A session that did not end normally (the conductor was killed) is recorded by the next run with outcome `killed`: wall time 0 when the session itself was cut off, its real wall time when the session ended and a later step failed. |
| `notifications.log` | The events above. |
| `logs/` | `conduct-<unit>-lead-<time>.log`, `-review-` and `-verify-` logs. Read the lead's final message here. |
| `<plan key>/<unit slug>/` | `state`, `stop_reason`, `prs`, `pid`, the counters, `findings-<n>.md`, `answer.txt`, `guard_denial`. The plan key is the plan file's name without `.md`; the unit slug is the unit id in lower case with spaces as `-` (`M1` is `m1/`). |
| `lock/` | Held while a conductor runs. |

Work trees are in `<repo>/.farm-worktrees/`.

### Stopping and restarting

A unit that stopped restarts only when you run the command again with an answer:

```bash
farmctl conduct run "$P" M1 --answer "use approach B"
```

The answer is written to `answer.txt` and the lead is told where it is. This resets the three counters
(`rework`, `continuation`, `interruption`) to 0; `attempts` keeps growing. Without `--answer` a stopped
unit is refused with its stop reason. `--answer` on a unit that is not stopped is refused too.
`farmctl conduct run <plan>` stops at the first unit that is `escalated`, `shipped-unreviewed`, or
`backlog`, that still waits for an operator merge (`awaiting-operator-merge`), whose session is still
alive (`session-alive`), or whose state cannot be read (`invalid-state`), and prints why. It pauses
(the `pause` event) when a precondition refuses or the plan on the default branch changed since the loop
started (`plan-changed`): check the new plan with `farmctl conduct lint`, then run the loop again.

A lead has no way to ask a question in the middle of a unit. If it cannot go on, it ends the session and
says why in its final message. The conductor then sees a session with no handoff: it continues or
reworks the unit until a cap stops it. Read the lead's log, then answer with `--answer`.

How to resolve what you will see:

- **`shipped-unreviewed`**: the handoff is on the default branch but no review record exists (for
  example, it was merged by hand). Run `farmctl conduct adopt "$P" <unit> <handoff path>`. The file must
  be on the default branch and pass the handoff checks.
- **`pause`**: a precondition refused, or the plan changed on the default branch since the loop started
  (`plan-changed`). Fix what the message names (for `plan-changed`, check the new plan with
  `farmctl conduct lint`), then run the command again.
- **`awaiting-operator-merge`**: merge the named pull request, then run the command again.

A run that is killed (a closed terminal, a reboot) leaves the unit `doing`. The next run counts it as an
interruption and resumes. Run the conductor inside `tmux` so a closed terminal does not kill it.

### Knobs

Set these in the environment of `farmctl conduct`. They are not read from `farm.env`.

| Knob | Default | What it controls |
| --- | --- | --- |
| `CONDUCT_VERIFY_TIMEOUT_SECONDS` | `1800` | The bound on the verify command. |
| `CONDUCT_LEAD_MODEL` / `CONDUCT_LEAD_EFFORT` | `opus` / `high` | The lead session. |
| `CONDUCT_REVIEW_MODEL` / `CONDUCT_REVIEW_EFFORT` | `opus` / `high` | The review session. |
| `CONDUCT_LONG_WAIT` | `1` | `1`: the lead may wait on a long command (CI, a deploy) in the background. `0`: no command may wait over nine minutes, and a unit that needs more is not eligible. |
| `CONDUCT_MAX_SESSION_SECONDS` | `21600` | A session that runs longer is ended. |
| `CONDUCT_GATE_POLL_SECONDS` | `60` | How often a waiting conductor re-reads the limit gate. |
| `CONDUCT_CHECKS_POLL_SECONDS` / `CONDUCT_CHECKS_TIMEOUT_SECONDS` | `30` / `2700` | Polling the required checks of the handoff pull request, and the time before `required-checks-not-reported`. |
| `CONDUCT_INIT_TIMEOUT_SECONDS` | `120` | How long to wait for a session's init event, which proves the guard is loaded. |

### Limits

- Supervised only. Do not leave it running unattended.
- One unit at a time per repository.
- A session with unconfined Bash can still write conductor state (the files above).
- The guard's rule against a direct push to the default branch is a tripwire. Branch protection is the
  boundary.
- The verify command, and the files it runs, are project code. The conductor runs them outside the guard.

## ⚠️ Updating the plugin

The plugin's on-disk location (`${CLAUDE_PLUGIN_ROOT}`) is **ephemeral**: it changes on every
plugin update, and the old directory is garbage-collected roughly 7 days later. The supervision
units (systemd on Linux, launchd plists on macOS) bake an **absolute** path to the plugin's scripts
at scaffold time — they do **not** follow an update. So **after any plugin update you must re-run
the installer** (or the init skill) to regenerate the units:

```bash
"${CLAUDE_PLUGIN_ROOT}"/engine/install.sh --init-project "$CLAUDE_PROJECT_DIR"
```

Skip this and the units will point at a deleted directory once the old checkout is collected.

`claude plugin update` is keyed on the `version` in `.claude-plugin/plugin.json`: if the version
string did not change, it reports "already at the latest version" and keeps the old cache, even
after `claude plugin marketplace update` fetched newer code. So every release that should reach
installed copies bumps that version. Verify an install with `diff -r` between the cache directory
and the checkout, not by the update command's message.

## Troubleshooting

**A task sits in `ready` and no runner picks it up.** Check, in order: (1) `farmctl status` — are
implementer units actually `active`? Start them with `farmctl start`. (2) Is the farm paused?
`farmctl resume` clears a soft-pause. (3) Auth — a farm agent needs the `claude` CLI logged in on
the box, and **no** `ANTHROPIC_API_KEY` in the environment (it would override subscription auth).
(4) Backlog vs. ready — implementers drain `ready`, not `backlog`; promote backlog items first.
(5) A hit usage limit backs runners off (`LIMIT_FALLBACK_SECONDS`, default 30 min) — `farmctl logs`
shows the gate.

**Everything stalled right after a plugin update.** The supervision units (systemd on Linux,
launchd plists on macOS) bake an **absolute** plugin path that an update invalidates (see the
Updating section). Run `farmctl doctor` — it detects a stale `REPO_DIR` or a garbage-collected
plugin path. Fix: re-run `engine/install.sh --init-project` to regenerate the units.

**A task is stuck in `review` with red or hung CI.** QA owns `review`; the janitor's CI-rescue pass
re-drives PRs whose CI is red or behind main. Confirm the janitor timer is running
(Linux: `systemctl --user list-timers | grep janitor`; macOS: `launchctl list | grep com.agent-farm`)
and read `farmctl logs` for the QA/janitor verdict.
A PR touching a protected path will **not** auto-merge by design — it lands in `escalated` instead.
If your default branch is neither `main` nor `master` and `origin/HEAD` does not name it, every agent merge is denied (run `git remote set-head origin --auto`).

**Tasks piling up in `escalated`.** This is the farm asking for a human decision (money, credentials,
low confidence, or a protected-path merge). List them with the board skill or
`kanban-md --dir <board> list --status escalated`, read each task's timestamped block note, make the
call, then move it back to `ready` (or `archived`). The farm never self-resolves an escalation.

**The guard hook blocked a command you expected to run.** That is the `PreToolUse` firewall
(`hooks/guard-bash.sh`) doing its job — it only governs farm agents (`FARM_AGENT=1`), never your
interactive session. If a task legitimately needs the blocked action, it belongs in `escalated`, not
in a weakened guard.

## Uninstall

The plugin ships no destructive uninstaller — teardown is a few explicit steps so nothing is removed
by surprise. `farmctl stop` already tears down the running supervision on either platform:

```bash
farmctl stop                                   # stop workers + timers; in-flight tasks requeue
```

**Linux (systemd):**

```bash
systemctl --user stop    'claude-farm@*' claude-scout.timer claude-janitor.timer
systemctl --user disable 'claude-farm@*' claude-scout.timer claude-janitor.timer
rm -f  ~/.config/systemd/user/claude-farm@.service \
       ~/.config/systemd/user/claude-{scout,janitor}.{service,timer}
rm -rf ~/.config/systemd/user/claude-farm@.service.d \
       ~/.config/systemd/user/claude-{scout,janitor}.service.d   # PATH drop-ins
systemctl --user daemon-reload
loginctl disable-linger "$USER"                # optional: only if nothing else needs linger
```

**macOS (launchd):**

```bash
# boot out any loaded agents, then remove the plists
for p in ~/Library/LaunchAgents/com.agent-farm.*.plist; do
  launchctl bootout "gui/$(id -u)/$(basename "$p" .plist)" 2>/dev/null
done
rm -f ~/Library/LaunchAgents/com.agent-farm.*.plist
```

Then remove the per-project config with `rm -rf .agent-farm/` in your repo (this deletes the board
state and logs — archive them first if you want the history). Uninstall the plugin itself from
Claude Code with `/plugin uninstall software-factory@software-factory`.

## Skills provided

| Skill | Purpose |
| --- | --- |
| `software-factory:agent-farm-init` | Scaffold farm config + governance into the current repo (run once per project). |
| `software-factory:farm-orchestration` | Operate the farm as the human-facing orchestrator: health, filing work, escalations, merges. |
| `software-factory:task-new` | Create a well-formed feature/chore task (Acceptance Criteria, Scope IN/OUT, verification). |
| `software-factory:bug-new` | File a well-formed bug with reproduction, evidence, and a failing-test-first criterion. |
| `software-factory:task-authoring` | Write high-quality tickets that autonomous agents can execute without follow-up questions. |
| `software-factory:conduct-plan` | Give a plan written with `superpowers:writing-plans` the format `farmctl conduct` reads, then lint it. |
| `software-factory:requesting-pr-revision` | Send a task that already has a PR back for more implementer work on its branch. |
| `software-factory:kanban-md` | Manage tasks on the file-based `kanban-md` board (create, list, move, edit). |
| `software-factory:kanban-based-development` | Parallel-safe multi-agent development workflow with explicit handoffs. |

## Layout & further reading

```text
bin/        engine scripts — farmctl, farm-runner.sh, farm-scout.sh, farm-janitor.sh, farm-lib.sh, farm-conduct.sh, farm-conduct-lib.sh
hooks/      guard-bash.sh + hooks.json (the PreToolUse command firewall)
engine/     install.sh, systemd/ (Linux units), launchd/ (macOS plist templates), tests/ (safety test suite)
defaults/   generic config — FARM.md, farm.env, protected-paths.txt, prompts/
templates/  per-project scaffolds — task/bug templates, project-prompts/, protected-paths
skills/     the software-factory:* skills
contract/   what `farmctl conduct` reads and writes, with fixtures
```

- [`engine/tests/run.sh`](engine/tests/run.sh) — the safety test suite (also run by `farmctl audit`).
- [`engine/tests/conduct.sh`](engine/tests/conduct.sh) — the Plan Conductor suite.
- [`contract/README.md`](contract/README.md) — the Plan Conductor's plan, handoff and state formats.

## License

MIT.
