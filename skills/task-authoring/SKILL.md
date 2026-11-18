---
name: task-authoring
description: >
  Write high-quality kanban-md tickets (tasks and bugs) that autonomous
  implementer/QA agents can execute without follow-up questions. Use this
  whenever creating, editing, splitting, or reviewing board tasks — including
  when the user says "add a ticket", "add this to the board", "file a bug",
  "create a task", mentions kanban, backlog, or asks an agent to "remember to
  do X later". Also use it when a Scout sweep is about to create tasks, or
  when an existing ticket looks too vague to implement.
allowed-tools:
  - Bash(kanban-md *)
  - Bash(kbmd *)
  - Bash(find *)
  - Read
  - Grep
  - Glob
---

# Task Authoring for the Agent Farm

A ticket on this board is a CONTRACT between three parties that never talk
to each other live: the author, an implementer (fresh session, zero shared
memory), and QA (another fresh session). Everything they need must be IN the
ticket or pointed to BY the ticket.

## The quality bar

A ticket is ready when a competent engineer with no project memory could:

1. start working within 5 minutes (Context pointers are real `file:line`s),
2. know exactly when they're done (AC are observable and testable),
3. know what NOT to touch (Scope OUT), and
4. when QA could verify it mechanically (Verification = exact commands).

## Structure (mandatory sections)

Use `${CLAUDE_PLUGIN_ROOT}/templates/task-template.md` for features/chores and
`${CLAUDE_PLUGIN_ROOT}/templates/bug-template.md` for defects, filling every
section. The plugin ships these templates alongside its skills, so the paths
always resolve regardless of cwd or worktree.
Never create a task with a one-line body.

## Rules of thumb

- **Title**: imperative, specific. "Add Zod validation to /api/intake" not
  "improve validation".
- **One task = one mergeable PR.** If you can't describe the single PR it
  produces, split it (`--parent` links the children).
- **AC are behaviors, not activities.** "Tests added" is weak; "POST with
  invalid email returns 400 with code VALIDATION_ERROR (test: route.test.ts)"
  is strong.
- **Verification is QA's script.** List the exact commands; if a check is
  manual, write the precise steps and what a pass looks like.
- **UI tasks** must say so explicitly and note the expected visual scope —
  the farm routes them through `product/` §12 + frontend-design and the
  visual-e2e discipline depends on the declared scope.
- **Bugs require evidence** (output, stacktrace, file:line) and the
  failing-test-first AC. A suspected cause is a labeled hypothesis with a
  confidence number, never an instruction.
- **Dependencies**: if it can't start before another task ships, wire it:
  `--depends-on <id>` (pick skips blocked-by-dependency tasks).
- **Status**: human-curated work → `ready`; speculative/scout work →
  `backlog`. Priority `critical` is reserved for security/data-loss/prod-down.

## Anti-patterns (reject or repair these)

- "Refactor X to be cleaner" — no observable end state.
- AC that restate the title.
- Context section that says "see codebase".
- A bug whose only evidence is "user says it's broken".
- Ticket bundling a behavior change + a refactor + a doc update (split it).
