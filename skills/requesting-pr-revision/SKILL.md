---
name: requesting-pr-revision
description: Use when a kanban task that ALREADY has a PR must go back for more implementer work — QA found issues needing the implementer (not an in-place fix), a §12 / operator design review or any reviewer requests changes on an open/draft PR, or a task is stranded in review/escalated/doing and needs rework on its existing branch. Symptoms include "send #N back", "request changes", "bounce to ready", "revise the PR", a draft PR awaiting changes, or an implementer who picked it up before with no clear instructions.
---

# Requesting PR Revision

## Overview

When a task already has a PR but needs more implementer work, it must return to `ready` as a **clean, claimable** item carrying **structured, PR-specific change-requests** — so the next implementer revises the SAME branch with zero ambiguity and the board doesn't strand it.

This skill exists because of two real, repeatable failures:

1. A leftover **`blocked` flag** silently stranded the task in `ready` — implementers never claim a blocked task, so it sat untouched while an implementer idled.
2. **Ad-hoc notes** ("fix the design") left the implementer guessing and risked losing the PR link.

## When to use

- QA found issues that need the IMPLEMENTER (not a QA in-place fix).
- A §12 operator design review, or any operator/reviewer feedback, requests changes on an OPEN/DRAFT PR.
- A task is stuck in review/escalated/doing and needs rework on its existing PR branch.

**When NOT to use:**

- A task with **no PR yet** (use `agent-farm:task-authoring` / `agent-farm:task-new`).
- A **`decompose`- or `capstone`-tagged** task (these are PR-less review tasks handled by qa.md's short-circuits — bouncing them to `ready` ping-pongs forever).
- A genuine **decision/escalation** → `escalated` WITH a reason, do not bounce to `ready`.
- Changes QA can **fix in place**.
- A **MERGED** PR → file a NEW follow-up task; never re-open landed work.

## Claim discipline (read first — the board enforces this)

If YOU currently hold the claim (e.g. a QA agent acting on the task it is reviewing), **every `edit`/`move` on that task MUST include `--claim "<AGENT_NAME>"`** (your name from `farm_context`) or the board rejects the mutation — EXCEPT `--release`, which must be standalone (never combined with `--claim`). Release the claim **LAST**.

If the task is **unclaimed** (e.g. an orchestrator acting on an unclaimed `review`/`escalated` task), omit `--claim` on every call and skip the final `--release`. Never steal or hold someone else's live claim — if another agent holds it and its runner log is still growing, stop.

Below, `[--claim "<AGENT_NAME>"]` means "include only if you hold the claim."

## The procedure — do ALL steps, in order

All `kanban-md` calls need `--dir "<BOARD_DIR>"`. `<ID>` = task id, `<N>` = PR number.

1. **Resolve the PR fresh** (numbers race across parallel agents): `gh pr list --head <branch>` or the task's `pr-<N>` tag. **Confirm state with `gh pr view <N> --json state,mergedAt`.** OPEN → continue. MERGED → STOP, file a new follow-up task. CLOSED → decide reopen vs. new PR.
2. **One atomic claimed edit** — structure + PR-link + unblock together, so the task is never left half-done:
   ```
   kanban-md --dir <dir> edit <ID> -t \
     --append-body "<change-request — template below>" \
     --add-tag pr-<N> --unblock [--claim "<AGENT_NAME>"]
   ```
   (`-t` = timestamp the appended note. `--unblock` clears the silent-stranding flag even if you don't think it's set. `--add-tag pr-<N>` guarantees the implementer revises the existing PR.)
3. **Move to `ready`:** `kanban-md --dir <dir> move <ID> ready [--claim "<AGENT_NAME>"]`.
4. **Release the claim LAST** (only if you held it): `kanban-md --dir <dir> edit <ID> --release` (standalone — no `--claim`).
5. **VERIFY** (you are not done until this passes): `kanban-md --dir <dir> show <ID> --json` → assert `status: ready`, **`blocked: null`**, `claimed_by: null`, the `pr-<N>` tag present, and the change-request visible in the body. If `blocked` is not `null`, the task is unclaimable — redo step 2's `--unblock`.

## Change-request template (PR-specific, unambiguous)

```
REVISION REQUESTED on PR #<N> — revise the SAME branch; do NOT open a new PR.
Source: <QA | §12 operator review | reviewer>.
Why back: <one line>.
Changes (each = what + exact file:line + acceptance):
  1. <change> — <file:line> — done when <testable condition>.
  2. ...
Keep (do NOT regress): <parts already approved — e.g. capstone-passed areas>.
Verify: <commands, e.g. npm run check; npm run test -- <suite>>.
Then: hand back to QA (move to review) as usual.
```

## Common mistakes

| Mistake                                            | Consequence                                                                       | Fix                                                                      |
| -------------------------------------------------- | --------------------------------------------------------------------------------- | ------------------------------------------------------------------------ |
| Skipping `--unblock`                               | Task sits in `ready` forever — no implementer claims a blocked task             | Always unblock; verify `blocked: null` in step 5                         |
| Omitting `--claim` while you hold the claim        | Board rejects the `edit`/`move` — procedure silently fails                        | Add `--claim "<AGENT_NAME>"` to every claimed mutation (not `--release`) |
| Releasing the claim before unblock/move            | Re-opens a stranding window; mutations run unowned                                | Release LAST, after the move                                             |
| Vague change-request ("fix the design")            | Implementer guesses, re-does it wrong                                             | Cite `file:line` + a testable "done when" per change                     |
| Not re-tagging `pr-<N>` / not saying "same branch" | Implementer opens a NEW PR; the old one orphans                                   | Re-add the `pr-<N>` tag and state "revise the SAME branch"               |
| Bouncing a MERGED task                             | Re-implements landed work, duplicate PR                                           | Check PR state first; if MERGED, file a new follow-up task               |

## Quick reference (claim-holder form; drop `--claim` if unclaimed)

| Step                               | Command                                                                                                     |
| ---------------------------------- | ----------------------------------------------------------------------------------------------------------- |
| confirm PR open                    | `gh pr view <N> --json state,mergedAt`                                                                      |
| structure + tag + unblock (atomic) | `kanban-md --dir <dir> edit <ID> -t --append-body "<cr>" --add-tag pr-<N> --unblock --claim "<AGENT_NAME>"` |
| to ready                           | `kanban-md --dir <dir> move <ID> ready --claim "<AGENT_NAME>"`                                              |
| release (last, standalone)         | `kanban-md --dir <dir> edit <ID> --release`                                                                 |
| verify                             | `kanban-md --dir <dir> show <ID> --json` → status / blocked / claimed_by / tags                             |
