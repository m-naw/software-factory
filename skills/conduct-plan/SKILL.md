---
name: conduct-plan
description: >
  Use only when a plan already written (or being written) with
  superpowers:writing-plans is meant to be run by `farmctl conduct`: adapts its
  headings to conductor units, adds the spec link and handoff protocol, and runs
  `farmctl conduct lint`. Not a planning method; for writing a plan use
  superpowers:writing-plans.
allowed-tools:
  - Bash(farmctl conduct lint *)
  - Read
  - Edit
  - Grep
---

# Conduct-ready plans

This skill gives a plan the format `farmctl conduct` reads (rules: `contract/README.md`). How to decompose
work and write tasks is `superpowers:writing-plans`' job, not this skill's.

## Prerequisites

- A spec exists (from `superpowers:brainstorming`), is merged to `origin/<main>`, and the plan links it.
- The plan is under `docs/superpowers/plans/`. That is a protected path, so the conductor accepts the plan
  only as committed on `origin/<main>` (`plan-unprotected` otherwise).

## Format

Copy `templates/plan-template.md` and fit the plan to it:
1. Header lines `**Goal:**`, `**Spec:** [title](relative path)` (mandatory; a link resolves from the plan's directory,
   a backticked path from the repository root), `**Architecture:**`, `**Tech Stack:**`.
2. A `## 0. How to run this plan` section listing the handoff sections the unit's lead writes.
3. Each unit is a level-2 heading `## M1 — name`, `## PR 3` or `## Iteration 2`; its tasks are
   `### Task M1.1: name` headings with checkbox steps. A unit has at least one task.
4. `Depends-on: M1, M2` must be the first non-blank line under the unit heading; anywhere else it is ignored and
   the unit depends on the previous one. `Depends-on: none` makes a unit independent.
5. One unit fits one session. No unit changes what the guard's self-tampering rules (`hooks/guard-bash.sh`) block
   agents from writing: `.github/workflows/`, `CODEOWNERS`, `.claude/settings*`, `.agent-farm/protected-paths.txt`, `.agent-farm/farm.env`, `.agent-farm/prompts/`, `hooks/guard-bash.sh`, `hooks/hooks.json`, `agent-farm/(hooks|bin|systemd|launchd)/`, and the launchd units (`engine/launchd/`, `com.agent-farm.*.plist`).
   Put such a change in the handoff's operator actions.
6. No `## M...` heading in a fenced code block, except as an example.

## Final step (mandatory)

Run `farmctl conduct lint <plan>` until it exits 0. Do not claim the plan is ready before. A refusal names a code:

| Code | Meaning and fix |
| --- | --- |
| `no-spec` | No `**Spec:**` line before the first unit (outside fences). Add it. |
| `spec-bad-path` | The spec path is a URL, absolute, empty or escapes the repository. Use a relative path. |
| `spec-missing` | The spec is not a file on `origin/<main>`. Merge the spec first, or fix the path. |
| `no-units` | No unit heading matched. Rename the headings to the forms in step 3. |
| `duplicate` | Two units share an id. Rename one. |
| `unknown-dep` | A `Depends-on:` names a unit the plan lacks. Fix the id. |
| `no-tasks` | A unit has no `### Task` heading. Add one, or delete the heading. |
| `cycle` | Units depend on each other. Remove an edge. |
| `renamed-shipped` | A unit that already shipped was renamed or removed. Restore its id. |
| `plan-unprotected` | The plan matches no protected glob on `origin/<main>`. Move it under `docs/superpowers/plans/`. |

## Delivery
The plan reaches main by a pull request the operator merges (protected path), only after lint exits 0.
