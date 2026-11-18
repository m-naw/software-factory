---
name: bug-new
description: >
  File a well-formed bug on the kanban-md board with reproduction steps,
  concrete evidence (command output / file:line / stacktrace) and a
  failing-test-first Acceptance Criterion. Use whenever the user reports
  something broken, says "file a bug", "log a defect", "this is broken",
  or when an agent discovers a reproducible defect. Invocable as
  /software-factory:bug-new <what is broken>.
allowed-tools:
  - Bash(kanban-md *)
  - Bash(kbmd *)
  - Bash(rtk *)
  - Read
  - Grep
  - Glob
---

File a bug on the kanban-md board for: $ARGUMENTS

Process:

1. Load the structure from the bug template at
   `${CLAUDE_PLUGIN_ROOT}/templates/bug-template.md` (the plugin ships this
   template alongside its skills, so the path always resolves regardless of
   cwd or worktree). Fill EVERY section of that template — do not invent
   your own.
2. Gather EVIDENCE yourself first: reproduce with a command, find the
   relevant file:line, capture the error output (rtk for noisy output). A
   bug without evidence is a rumor — if you cannot reproduce and the user
   cannot give concrete output, say so instead of filing.
3. Ask only for what you genuinely cannot obtain (exact repro, environment),
   max 3 questions.
4. Severity → priority: data loss / security / prod-down = critical; broken
   core flow = high; degraded UX or wrong edge case = medium; cosmetic = low.
5. Create it:
   `kanban-md create "<symptom-first title>" --status ready --priority <p> --tags bug,<area> --body "<filled template>"`
6. Show the created task.
