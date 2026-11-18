---
name: agent-farm-init
description: Scaffold farm config + governance into the current repo. Run once per project after installing the software-factory plugin.
---

# agent-farm-init

Set up the agent farm in this repo.

## Step 0 (macOS only) — ensure kanban-md is installed

On **Linux**, `install.sh` downloads + checksum-verifies the pinned `kanban-md` for you; skip this
step. On **macOS** it deliberately will not (the pinned release asset is a Linux tarball and there
is no checksummed macOS binary), so `kanban-md` must be on `PATH` **before** you run `install.sh` —
otherwise it stops with an "install kanban-md yourself" message.

You (the agent running this skill) should handle this on macOS, not punt to the human:

1. If `command -v kanban-md` already resolves → nothing to do.
2. Else if `command -v go` is available → install the pinned version from source (Go verifies the
   download via its module checksum database). Read the pin from the installer so it never drifts:

   ```bash
   KBMD_VER="$(grep -oE 'KBMD_VERSION="[0-9.]+"' "${CLAUDE_PLUGIN_ROOT}"/engine/install.sh | grep -oE '[0-9.]+' | head -1)"
   go install "github.com/antopolskiy/kanban-md/cmd/kanban-md@v${KBMD_VER}"   # note the /cmd/kanban-md path
   export PATH="$(go env GOPATH)/bin:$PATH"                                    # so install.sh below finds it
   kanban-md --version || true   # a source build reports 'dev' — cosmetic, nothing gates on it
   ```

   Tell the user to persist `export PATH="$(go env GOPATH)/bin:$PATH"` in their shell profile
   (e.g. `~/.zshrc`) so `farmctl`/`kanban-md` stay on PATH for interactive use in future sessions.
   (The installer separately bakes the resolved `kanban-md` dir into the launchd units, so the
   supervised scout/janitor/worker find it regardless.)
3. Else (no `go` and no `kanban-md`) → ask the user to install Go (`brew install go`) and re-run
   this skill, or to install `kanban-md` another way (a darwin release build), then re-run.

## Install

    "${CLAUDE_PLUGIN_ROOT}"/engine/install.sh --init-project "$CLAUDE_PROJECT_DIR"

On Linux this installs kanban-md + the board; on macOS it detects the kanban-md from Step 0 and
scaffolds the board. Either way it seeds `.agent-farm/{protected-paths.txt,farm.env,prompts/,FARM.md}`
and installs the systemd user units (Linux) or launchd agents (macOS). Farm governance lives in
`.agent-farm/FARM.md` (the operating constitution, seeded from the plugin's `defaults/FARM.md`) and
is injected into every farm agent's system prompt at runtime — the installer does not edit the
consuming repo's `CLAUDE.md`.

## Before starting the farm

1. Edit `.agent-farm/protected-paths.txt` — list THIS project's safety-critical paths (auth, payments, migrations, data-deletion, …). These gate auto-merge + force higher-tier review.
2. Set `FARM_VERIFY_CMD` / `FARM_TEST_CMD` in `.agent-farm/farm.env` for your stack (default: `npm run check` / `npm run test`).
3. Optionally fill `.agent-farm/prompts/{scout,implementer,qa}.md` with your domain invariants (copy from the plugin's `templates/project-prompts/` as a starting point).
4. Ensure `software-factory@software-factory` is in `.claude/settings.json` `enabledPlugins`.
5. For full workflow depth, install the `superpowers` and `frontend-design` plugins (the
   farm's prompts use them if present; `FARM.md`'s baseline rules bind regardless).

Operate the farm with `farmctl start|stop|scale|status|pause|dash`.
