---
name: task-new
description: >
  Create a well-formed kanban-md task (feature or chore) with testable
  Acceptance Criteria, Scope IN/OUT, Verification commands and file:line
  Context pointers. Use whenever the user wants to add a task/ticket to the
  board, says "add this to the backlog", "create a task for…", "make a
  ticket", or when an agent needs to file a new non-bug work item. Invocable
  as /agent-farm:task-new <description>.
allowed-tools:
  - Bash(kanban-md *)
  - Bash(kbmd *)
  - Read
  - Grep
  - Glob
---

Create a new task on the kanban-md board for: $ARGUMENTS

Process:

1. Load the structure from the task template at
   `${CLAUDE_PLUGIN_ROOT}/templates/task-template.md` (the plugin ships this
   template alongside its skills, so the path always resolves regardless of
   cwd or worktree). Fill EVERY section of that template, and apply the
   `agent-farm:task-authoring` skill's quality bar.
2. Investigate the codebase briefly (graphify report, key files) so Context
   pointers are real file:line references, not guesses.
3. If $ARGUMENTS is too thin to write testable Acceptance Criteria, ask the
   minimum questions needed (max 3) before creating anything.
4. Decide whether this is UI work; if so note the `product/` §12 + expected
   visual scope in Risks/Notes.
5. Create it (run from repo root, board auto-detected, or pass --dir):
   `kanban-md create "<imperative title>" --status ready --priority <p> --tags <area> --body "<filled template>"`
   Human-initiated tasks go to `ready`. Default priority medium.
6. Show the created task (`kanban-md show <id>`).
