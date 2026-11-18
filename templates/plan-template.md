# <Plan name> — Implementation Plan

**Goal:** <one sentence>

**Spec:** [<spec title>](<relative path to the spec file, e.g. ../specs/2026-11-18-topic-design.md>)

**Architecture:** <two or three sentences>

**Tech Stack:** <languages, tools, test runner>

<!--
Skeleton for a plan run by `farmctl conduct`. It fixes the format only. How to decompose the work and
write tasks is superpowers:writing-plans' job. Delete this comment block when you copy the file.

- The **Spec** line is mandatory: the conductor refuses a plan without it (`no-spec`, `spec-bad-path`, `spec-missing`).
  A markdown link target resolves from the plan's directory; a backticked path from the repository root.
  The spec must already be a file on origin main.
- The plan lives under docs/superpowers/plans/ (a protected path) and reaches main by a pull request
  the operator merges. Run `farmctl conduct lint <plan>`: it must exit 0 first.
- One unit (`## M1 ...`, `## PR 3`, `## Iteration 2`) fits one session. Split it if it does not.
- A unit never requires a change to what the guard's self-tampering rules (hooks/guard-bash.sh) block agents
  from writing: .github/workflows/, CODEOWNERS, .claude/settings*, .agent-farm/protected-paths.txt, .agent-farm/farm.env, .agent-farm/prompts/, hooks/guard-bash.sh, hooks/hooks.json, agent-farm/(hooks|bin|systemd|launchd)/, and the launchd units (engine/launchd/, com.agent-farm.*.plist).
  List such a change as an operator action, outside any unit's tasks.
- No `## M...` heading inside a fenced code block, except as an example: the parser is fence-aware,
  but readers are not.
- `Depends-on: M1, M2` must be the first non-blank line under the unit heading; elsewhere it is ignored and the
  unit depends on the previous one. `Depends-on: none` makes a unit independent.
-->

## 0. How to run this plan

Each unit runs in its own fresh session, started by `farmctl conduct run <plan> [<unit>]`. Read this
section, the unit's section and the previous handoff, including its "Lessons learned", before the first task.
The lead's last pull request changes only the unit's handoff file,
`docs/superpowers/handoffs/<plan file name without .md>-<unit, lowercase>-handoff.md`, with these level-2 sections:

- `## Verification evidence`: the commands run and their output.
- `## Lessons learned`: what the next session needs to know.
- `## <unit> entry criteria`: one per dependent unit, a table with a `Status` column.
- `## Operator actions pending`: even if it says "none"; it feeds the unit-shipped event.
- `## Deviations`: anything that differs from this plan.

## M1 — <name>

### Task M1.1: <name>

**Files:** <paths to create or change>

- [ ] **Step 1:** <action>
- [ ] **Step 2:** <verification command and its expected result>

## M2 — <name>

Depends-on: M1

### Task M2.1: <name>

- [ ] **Step 1:** <action>
- [ ] **Step 2:** <verification command and its expected result>
