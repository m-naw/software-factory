#!/usr/bin/env bash
# engine/install.sh — end-to-end agent-farm setup on Ubuntu (Hetzner-friendly).
# Idempotent: safe to re-run after a plugin update.
#
# Installs: kanban-md (latest GitHub release), board with farm columns,
# kanban-md agent skills, systemd user units, CLAUDE.md farm governance,
# .gitignore entries, and (with --init-project) a per-project .agent-farm/ config.
# Requires: git, curl, jq, gh, tmux, claude (logged in).
#
# Usage:
#   engine/install.sh                       # target = CLAUDE_PROJECT_DIR or CWD git root
#   engine/install.sh --init-project <repo> # scaffold + set up the named target repo

set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# --init-project <repo> sets the target; else CLAUDE_PROJECT_DIR; else CWD's git root.
# --render-units-only renders supervision units (below) and exits — no deps
# check, no board, no launchctl/systemctl calls. Lets the render step be
# tested (macOS launchd plists in particular) without a live board or system
# supervisor.
REPO_ARG=""
RENDER_UNITS_ONLY=0
if [[ "${1:-}" == "--init-project" ]]; then REPO_ARG="${2:-}"; fi
if [[ "${1:-}" == "--render-units-only" ]]; then RENDER_UNITS_ONLY=1; fi
REPO_DIR="${REPO_ARG:-${CLAUDE_PROJECT_DIR:-$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || pwd)}}"
BOARD_DIR="$REPO_DIR/kanban"
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
LOG_DIR="$REPO_DIR/.agent-farm/state/logs"

# install.sh does NOT source farm-lib.sh (too heavy — it mkdir -p's state and
# reads farm.env). This tiny helper mirrors just enough of farm-lib.sh's
# farm_os() to branch systemd vs launchd, and honors FARM_OS_OVERRIDE so
# tests (and this file's own --render-units-only test) can force macOS on a
# Linux runner. Every OS branch below (units, PATH, deps) MUST go through
# this — never a bare `uname` — or FARM_OS_OVERRIDE is silently ignored.
_install_os() {
  if [[ -n "${FARM_OS_OVERRIDE:-}" ]]; then printf '%s' "$FARM_OS_OVERRIDE"
  elif [[ "$(uname -s)" == "Darwin" ]]; then printf '%s' macos
  else printf '%s' linux; fi
}
LAUNCHD_PREFIX="com.agent-farm"  # must match farm-lib.sh's LAUNCHD_PREFIX
if [[ "$(_install_os)" == "macos" ]]; then
  UNIT_DIR="${UNIT_DIR:-$HOME/Library/LaunchAgents}"
  PATH_LINE="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
else
  UNIT_DIR="${UNIT_DIR:-$HOME/.config/systemd/user}"
  PATH_LINE="/usr/local/bin:/usr/bin:/bin"
fi

say()  { printf '\033[1;32m[farm-install]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[farm-install] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# Best-effort PATH for launchd's EnvironmentVariables dict: launchd-spawned
# processes get a minimal PATH (no login-shell PATH, same problem write_path_
# dropins solves for systemd), so bake in claude's and kanban-md's dirs when
# found, ahead of PATH_LINE (which already covers Homebrew + the OS default).
_macos_path_env() {
  local p="$PATH_LINE" d
  d="$(command -v kanban-md 2>/dev/null || true)"; [[ -n "$d" ]] && p="$(dirname "$d"):$p"
  d="$(command -v claude 2>/dev/null || true)";    [[ -n "$d" ]] && p="$(dirname "$d"):$p"
  printf '%s' "$p"
}

# Render supervision units into $UNIT_DIR — no enabling/loading. Shared by
# --render-units-only and the real macOS install path (step 5), which additionally
# bootstraps scout+janitor after calling this. The Linux/systemd install path
# (step 5, HAVE_SYSTEMD branch) renders inline and does NOT call this — kept
# byte-for-byte unchanged rather than refactored onto a shared helper.
render_units() {
  mkdir -p "$UNIT_DIR"
  if [[ "$(_install_os)" == "macos" ]]; then
    local t base path_env
    path_env="$(_macos_path_env)"
    for t in "$PLUGIN_ROOT"/engine/launchd/*.plist.template; do
      base="$(basename "$t" .template)"
      # @INSTANCE@ (worker template only) is intentionally left unsubstituted:
      # workers are per-instance and rendered later by 'farmctl scale', not here.
      sed -e "s|@REPO_DIR@|$REPO_DIR|g" \
          -e "s|@FARM_BIN@|$PLUGIN_ROOT/bin|g" \
          -e "s|@LOG_DIR@|$LOG_DIR|g" \
          -e "s|<key>NO_COLOR</key>|<key>PATH</key><string>${path_env}</string><key>NO_COLOR</key>|" \
          "$t" > "$UNIT_DIR/$base"
    done
  else
    local u
    for u in "$PLUGIN_ROOT"/engine/systemd/*; do
      sed -e "s|@REPO_DIR@|$REPO_DIR|g" -e "s|@FARM_BIN@|$PLUGIN_ROOT/bin|g" "$u" > "$UNIT_DIR/$(basename "$u")"
    done
  fi
}

if (( RENDER_UNITS_ONLY )); then
  render_units
  say "rendered units → $UNIT_DIR (--render-units-only: skipping deps/board/supervision — exiting)"
  exit 0
fi

# systemd user services do not inherit the login shell PATH; claude (nvm)
# and kanban-md (~/.local/bin) are invisible to them without this. Re-running
# install.sh refreshes the baked PATH after a node/nvm upgrade.
write_path_dropins() { # $1=unit_dir $2=farm_path
  local unit_dir="$1" farm_path="$2" u
  for u in claude-farm@ claude-scout claude-janitor; do
    mkdir -p "$unit_dir/${u}.service.d"
    printf '[Service]\nEnvironment=PATH=%s\n' "$farm_path" \
      > "$unit_dir/${u}.service.d/path.conf"
  done
}

# ---------------------------------------------------------------- 0. deps ---
say "checking dependencies"
MISSING=()
for c in git curl jq tar; do command -v "$c" >/dev/null || MISSING+=("$c"); done
command -v gh >/dev/null    || MISSING+=("gh (GitHub CLI)")
command -v tmux >/dev/null  || MISSING+=("tmux")
if ((${#MISSING[@]})); then
  echo "Missing: ${MISSING[*]}"
  echo "On Ubuntu: sudo apt-get install -y git curl jq tmux gh   # gh may need the GitHub apt repo"
  echo "On macOS: brew install git curl jq gh tmux"
  fail "install the missing dependencies and re-run"
fi
# `claude` is a RUN-time dependency (the workers exec it), NOT a scaffold-time
# one — nothing this installer writes needs the binary itself. Hard-failing on
# it broke plugin-before-claude installs on a fresh box: scaffolding must
# proceed; the farm just can't be STARTED until claude exists. The only
# claude-dependent artifact (the systemd PATH drop-in baking claude's dir) is
# guarded below and re-generated by the documented re-run after installing it.
HAVE_CLAUDE=1
command -v claude >/dev/null 2>&1 || HAVE_CLAUDE=0
(( HAVE_CLAUDE )) || say "WARNING: 'claude' (Claude Code) not found in PATH — scaffolding continues, but install Claude Code and RE-RUN this installer before starting the farm (workers exec 'claude'; the re-run also bakes its location into the systemd PATH drop-ins)."
gh auth status >/dev/null 2>&1 || say "WARNING: 'gh auth status' failed — run 'gh auth login' before starting the farm"

# systemd (Linux --user units) is how the farm supervises itself unattended
# (auto-restart, boot survival). It is NOT required to use the plugin at all:
# without it, everything below still scaffolds (board, skills, .agent-farm/
# config) — only step 5 (supervision units) is skipped. See step 5 for the
# manual/cron fallback message.
HAVE_SYSTEMD=1
command -v systemctl >/dev/null 2>&1 || HAVE_SYSTEMD=0
# macOS has no systemctl but DOES get unattended supervision via launchd (step 5,
# the `_install_os == macos` branch). Only a non-systemd LINUX truly falls back to
# the manual/cron path — so the "no supervision" NOTE must not fire on macOS.
if (( ! HAVE_SYSTEMD )); then
  if [[ "$(_install_os)" == "macos" ]]; then
    say "NOTE: macOS detected — 'systemctl' is Linux-only; unattended supervision will use launchd (step 5)."
  else
    say "NOTE: 'systemctl' not found (non-systemd Linux) — continuing without unattended supervision. Board/config scaffolding proceeds normally; see step 5 below for how to run the farm without systemd."
  fi
fi

# --------------------------------------------------------- 1. kanban-md -----
# Pinned to the version the farm is tested against (mirrors the CI pin in
# .github/workflows/farm-ci.yml). NOT `latest`: a future kanban-md release can
# silently change claim/fencing semantics the farm depends on, breaking fresh
# installs while CI (on the pin) stays green. Bump deliberately — update BOTH the
# version and the per-arch digest below, then run a live-board test.
KBMD_VERSION="0.33.0"
# sha256 of the release TARBALL (from the published
# kanban-md_${VER}_checksums.txt). An unchecksummed remote binary landing in
# ~/.local/bin is a supply-chain hole; verify before installing.
kbmd_sha256_for() { case "$1" in
  amd64) echo "9d98e774dec3ba5f26009bfee8e64f7857eb2c785c98d55b201ae68f1400ea5d" ;;
  arm64) echo "d817393aa74d8a3e6c0ade728faebb07d5b7d3c5e8298923f78251c0aa63f9eb" ;;
  *) return 1 ;;
esac; }
sha256_of() { # file → hex digest on stdout (portable: Linux sha256sum, macOS shasum)
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}';
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}';
  else return 2; fi
}

if command -v kanban-md >/dev/null; then
  say "kanban-md already installed: $(kanban-md --version 2>/dev/null || echo present)"
else
  say "installing pinned kanban-md ${KBMD_VERSION} release binary"
  # The pinned release asset is a LINUX tarball only. On macOS a Linux binary
  # would install but fail to exec, aborting `kanban-md init` below under set -e
  # — a half-installed, confusing state. Fail early with a clear message BEFORE
  # touching anything. If the operator installs kanban-md themselves, the
  # `command -v kanban-md` branch above skips this entirely and the rest of the
  # scaffolding proceeds normally (F-f).
  [[ "$(uname -s)" == "Darwin" ]] && fail "kanban-md auto-install supports Linux only (the pinned release asset is a linux tarball). On macOS, install kanban-md yourself — the reliable way is 'go install github.com/antopolskiy/kanban-md/cmd/kanban-md@v${KBMD_VERSION}' (note the /cmd/kanban-md package path; ensure \$(go env GOPATH)/bin is on PATH), or a darwin release build — then re-run this installer — it will detect it and continue with board/config scaffolding."
  ARCH="$(uname -m)"; case "$ARCH" in
    x86_64) GOARCH=amd64 ;;
    aarch64|arm64) GOARCH=arm64 ;;
    *) fail "unsupported arch: $ARCH" ;;
  esac
  WANT_SHA="$(kbmd_sha256_for "$GOARCH")" || fail "no pinned kanban-md checksum for arch: $GOARCH"
  URL="https://github.com/antopolskiy/kanban-md/releases/download/v${KBMD_VERSION}/kanban-md_${KBMD_VERSION}_linux_${GOARCH}.tar.gz"
  TMP="$(mktemp -d)"
  curl -fsSL "$URL" -o "$TMP/kbmd.tgz" || fail "download failed: $URL"
  GOT_SHA="$(sha256_of "$TMP/kbmd.tgz")" \
    || { rm -rf "$TMP"; fail "cannot verify kanban-md: no sha256sum/shasum on PATH. Install one and re-run."; }
  if [[ "$GOT_SHA" != "$WANT_SHA" ]]; then
    rm -rf "$TMP"
    fail "kanban-md checksum mismatch — refusing to install an unverified binary.
    url:      $URL
    expected: $WANT_SHA
    got:      $GOT_SHA
  If you deliberately bumped KBMD_VERSION, update the pinned digest in engine/install.sh."
  fi
  tar -xzf "$TMP/kbmd.tgz" -C "$TMP"
  mkdir -p "$BIN_DIR"
  install -m 0755 "$TMP/kanban-md" "$BIN_DIR/kanban-md"
  ln -sf "$BIN_DIR/kanban-md" "$BIN_DIR/kbmd"
  rm -rf "$TMP"
  case ":$PATH:" in *":$BIN_DIR:"*) : ;; *)
    say "NOTE: add to PATH →  echo 'export PATH=\"$BIN_DIR:\$PATH\"' >> ~/.bashrc" ;;
  esac
  export PATH="$BIN_DIR:$PATH"
  say "installed + verified kanban-md v${KBMD_VERSION} → $BIN_DIR/kanban-md"
fi

# ------------------------------------------------------------- 2. board -----
# One-time, idempotent migration for boards created before the 2026-07-09
# supervisor-agnostic rename (the escalation status used to name its consumer;
# see docs — `escalated` describes the STATE, not who handles it). kanban-md's
# `config set statuses` is read-only, but the column list lives in the board's
# config.yml, and (verified on a scratch board) `list --status <old>` still
# returns tickets carrying a status no longer in the config, and `move` accepts
# the new one — so: rename the column in config.yml, then sweep any lingering
# tickets across. Both steps no-op on a new or already-migrated board. The old
# name is assembled from two halves so the test suite's no-old-status grep
# guard stays absolute (this file is the ONLY place allowed to know it).
OLD_ESCALATION_STATUS="needs""-human"

# Mixed-version guard (review R2 finding): runners bake the status vocabulary
# at process start (farm-runner.sh role case), and this installer's
# daemon-reload alone does NOT re-exec them — so an old-code runner surviving
# the rename keeps moving tickets to the now-unlisted OLD status, which falls
# outside every janitor scan → silently orphaned tickets. When the migration
# actually changes something, restart any ACTIVE farm workers so no
# pre-rename process outlives the new vocabulary. Restarting mid-task is safe
# by design: the runner's cleanup() EXIT trap releases + requeues the
# in-flight ticket (the documented systemd-restart path). Best-effort: no
# systemd (CI/containers) or no active units → quiet no-op; a failed restart
# degrades to a WARNING naming the manual fix.
restart_active_farm_units() { # → always returns 0
  command -v systemctl >/dev/null 2>&1 || return 0
  local units u
  units="$(systemctl --user list-units 'claude-farm@*' --state=active --no-legend 2>/dev/null \
             | awk '{print $1}' || true)"
  [[ -z "$units" ]] && return 0
  for u in $units; do
    systemctl --user restart "$u" >/dev/null 2>&1 \
      && say "board migration: restarted $u (a pre-rename runner would keep writing the old status)" \
      || say "WARNING: could not restart $u — restart it manually (farmctl stop && farmctl start)"
  done
  return 0
}

migrate_escalation_status() { # board_dir  → always returns 0 (best-effort)
  local board="$1" cfg id migrated=0
  cfg="$board/config.yml"
  [[ -f "$cfg" ]] || return 0
  if grep -q "^\( *\)- name: ${OLD_ESCALATION_STATUS}\$" "$cfg" 2>/dev/null; then
    if [[ "$(uname -s)" == "Darwin" ]]; then
      sed -i '' "s/^\( *\)- name: ${OLD_ESCALATION_STATUS}\$/\1- name: escalated/" "$cfg" 2>/dev/null || true
    else
      sed -i "s/^\( *\)- name: ${OLD_ESCALATION_STATUS}\$/\1- name: escalated/" "$cfg" 2>/dev/null || true
    fi
    say "board migration: renamed '${OLD_ESCALATION_STATUS}' column → 'escalated' in $cfg"
    migrated=1
  fi
  for id in $(kanban-md --dir "$board" list --status "$OLD_ESCALATION_STATUS" --json 2>/dev/null \
                | jq -r '.[].id' 2>/dev/null || true); do
    if kanban-md --dir "$board" move "$id" escalated >/dev/null 2>&1; then
      say "board migration: task #$id ${OLD_ESCALATION_STATUS} → escalated"
      migrated=1
    else
      say "WARNING: could not migrate task #$id to 'escalated' — move it manually"
    fi
  done
  # Only a run that actually changed something restarts workers — the
  # idempotent re-run (nothing renamed, nothing moved) touches no unit.
  (( migrated )) && restart_active_farm_units
  return 0
}
if [[ -d "$BOARD_DIR" ]]; then
  say "board already exists at $BOARD_DIR — leaving statuses as-is"
  migrate_escalation_status "$BOARD_DIR"
else
  say "initializing board with farm columns"
  ( cd "$REPO_DIR" && kanban-md init --name "$(basename "$REPO_DIR")" \
      --statuses "backlog,ready,doing,review,shipped,escalated,archived" </dev/null )
fi
( cd "$REPO_DIR" && kanban-md config set claim_timeout 2h >/dev/null \
    && kanban-md config set defaults.status backlog >/dev/null )
say "claim_timeout=2h, defaults.status=backlog"

# ------------------------------------------------- 3. skills + gitignore ----
say "installing kanban-md agent skills (project-local)"
( cd "$REPO_DIR" && kanban-md skill install </dev/null ) || say "WARNING: 'kanban-md skill install' failed — run it manually"

touch "$REPO_DIR/.gitignore"
for entry in "kanban/" ".farm-worktrees/" ".agent-farm/state/"; do
  grep -qxF "$entry" "$REPO_DIR/.gitignore" || echo "$entry" >> "$REPO_DIR/.gitignore"
done
say ".gitignore updated (kanban/, .farm-worktrees/, .agent-farm/state/)"

# ------------------------------------------- 3b. .agent-farm project config -
# Scaffold the target repo's per-project config from plugin templates/defaults.
# Only writes files that don't exist — never clobbers a project's edits.
mkdir -p "$REPO_DIR/.agent-farm/prompts"
[[ -f "$REPO_DIR/.agent-farm/protected-paths.txt" ]] || { cp "$PLUGIN_ROOT/templates/project-protected-paths.txt" "$REPO_DIR/.agent-farm/protected-paths.txt"; say "seeded .agent-farm/protected-paths.txt (EDIT for your project's safety-critical paths)"; }
[[ -f "$REPO_DIR/.agent-farm/farm.env" ]] || { cp "$PLUGIN_ROOT/defaults/farm.env" "$REPO_DIR/.agent-farm/farm.env"; say "seeded .agent-farm/farm.env (set FARM_VERIFY_CMD for your stack)"; }
[[ -f "$REPO_DIR/.agent-farm/FARM.md" ]] || { cp "$PLUGIN_ROOT/defaults/FARM.md" "$REPO_DIR/.agent-farm/FARM.md"; say "seeded .agent-farm/FARM.md (the farm's operating constitution — edit to extend for your project)"; }
say "edit $REPO_DIR/.agent-farm/prompts/{scout,implementer,qa}.md to add your project's domain invariants (optional; defaults used otherwise)"

# --------------------------------------- 4. CLAUDE.md — no longer patched ---
# Farm governance is injected directly into every agent's system prompt from
# .agent-farm/FARM.md (see farm-runner.sh / farm-scout.sh --append-system-prompt-file).
# The installer no longer writes into the consuming repo's CLAUDE.md.
say "farm governance lives in .agent-farm/FARM.md (auto-injected into every farm agent). Optionally add a one-line pointer to it in your CLAUDE.md."

# ------------------------------------------------------------ 5. systemd ----
chmod +x "$PLUGIN_ROOT"/bin/farm-runner.sh "$PLUGIN_ROOT"/bin/farm-scout.sh \
         "$PLUGIN_ROOT"/bin/farm-janitor.sh "$PLUGIN_ROOT"/bin/farmctl \
         "$PLUGIN_ROOT"/bin/farm-conduct.sh \
         "$PLUGIN_ROOT"/hooks/guard-bash.sh

# HAVE_SUPERVISION tracks whether SOME unattended supervisor got installed
# (systemd on Linux, launchd on macOS) — used only for step 6's next-steps
# message below. HAVE_SYSTEMD itself keeps its Linux-only meaning and still
# gates the systemd branch exactly as before.
HAVE_SUPERVISION=0
if [[ "$(_install_os)" == "macos" ]]; then
  say "rendering launchd units → $UNIT_DIR"
  render_units
  say "launchd plists bake an absolute plugin path — re-run install.sh after any agent-farm plugin update (the old plugin dir is garbage-collected ~7 days later)."

  say "guard hook is provided by the agent-farm plugin (hooks.json) — ensure the plugin is enabled in $REPO_DIR/.claude/settings.json (enabledPlugins)."

  # daemon-reload/enable-linger have no launchd equivalent needed here: a
  # fresh 'launchctl bootstrap' below picks up the plist immediately, and
  # macOS GUI sessions persist across SSH disconnect without a linger
  # equivalent (the loginctl guard above is Linux-only by construction).
  if command -v launchctl >/dev/null 2>&1; then
    for _lbl in "$LAUNCHD_PREFIX".scout "$LAUNCHD_PREFIX".janitor; do
      launchctl bootout "gui/$(id -u)/$_lbl" >/dev/null 2>&1 || true
    done
    if launchctl bootstrap "gui/$(id -u)" "$UNIT_DIR/$LAUNCHD_PREFIX.scout.plist" "$UNIT_DIR/$LAUNCHD_PREFIX.janitor.plist" 2>/dev/null; then
      say "launchd scout+janitor jobs bootstrapped (gui/$(id -u)) — worker instances are bootstrapped per-instance by 'farmctl scale'"
      HAVE_SUPERVISION=1
    else
      say "WARNING: launchctl bootstrap failed — plists written to $UNIT_DIR but not loaded; run manually: launchctl bootstrap gui/\$(id -u) $UNIT_DIR/$LAUNCHD_PREFIX.scout.plist $UNIT_DIR/$LAUNCHD_PREFIX.janitor.plist"
    fi
  else
    say "WARNING: 'launchctl' not found on PATH — plists written to $UNIT_DIR but not loaded"
  fi
elif (( HAVE_SYSTEMD )); then
  say "installing systemd user units → $UNIT_DIR"
  mkdir -p "$UNIT_DIR"
  for u in "$PLUGIN_ROOT"/engine/systemd/*; do
    sed -e "s|@REPO_DIR@|$REPO_DIR|g" -e "s|@FARM_BIN@|$PLUGIN_ROOT/bin|g" "$u" > "$UNIT_DIR/$(basename "$u")"
  done
  say "systemd units bake an absolute plugin path — re-run install.sh after any agent-farm plugin update (the old plugin dir is garbage-collected ~7 days later)."

  say "guard hook is provided by the agent-farm plugin (hooks.json) — ensure the plugin is enabled in $REPO_DIR/.claude/settings.json (enabledPlugins)."

  # Without claude, dirname "$(command -v claude)" would silently bake "." into
  # every unit's PATH — write the drop-ins from what exists and let the
  # documented post-claude re-run fix them up.
  KBMD_DIR="$(dirname "$(command -v kanban-md)")"
  if (( HAVE_CLAUDE )); then
    CLAUDE_DIR="$(dirname "$(command -v claude)")"
    write_path_dropins "$UNIT_DIR" "$CLAUDE_DIR:$KBMD_DIR:/usr/local/bin:/usr/bin:/bin"
    say "PATH drop-ins written (claude: $CLAUDE_DIR, kanban-md: $KBMD_DIR)"
  else
    write_path_dropins "$UNIT_DIR" "$KBMD_DIR:/usr/local/bin:/usr/bin:/bin"
    say "PATH drop-ins written WITHOUT a claude dir (claude not installed yet) — re-run this installer after installing Claude Code or the workers will not find it"
  fi
  systemctl --user daemon-reload
  if command -v loginctl >/dev/null; then
    loginctl enable-linger "$USER" 2>/dev/null \
      && say "linger enabled — farm survives logout/SSH disconnect" \
      || say "WARNING: could not enable linger; run: sudo loginctl enable-linger $USER"
  fi
  HAVE_SUPERVISION=1
else
  # Reached only on a NON-systemd LINUX (macOS is handled by the launchd branch
  # above). No systemd here and launchd is macOS-only, so fall back to manual/cron.
  say "SKIPPING supervision install — no 'systemctl' on this non-systemd Linux (macOS uses launchd, handled separately)."
  say "guard hook is provided by the agent-farm plugin (hooks.json) — ensure the plugin is enabled in $REPO_DIR/.claude/settings.json (enabledPlugins)."
  say "No unattended supervision (auto-restart timers for runner/scout/janitor) without systemd. Run the farm manually instead:"
  say "  $PLUGIN_ROOT/bin/farm-runner.sh implementer-1     # foreground, one worker (repeat per instance/role)"
  say "  $PLUGIN_ROOT/bin/farm-janitor.sh                  # run periodically, e.g. via cron: */15 * * * * $PLUGIN_ROOT/bin/farm-janitor.sh"
  say "wire cron or a terminal multiplexer yourself (launchd plists ship for macOS only)."
fi

# ------------------------------------------------------------- 6. wrap-up ---
mkdir -p "$REPO_DIR/.agent-farm/state/logs"
if (( HAVE_SUPERVISION )); then
  NEXT_STEPS="  3. Start small:     $PLUGIN_ROOT/bin/farmctl start 1 1
  4. Watch:           $PLUGIN_ROOT/bin/farmctl dash      (tmux: board TUI + logs + stats)
  5. Scale up:        $PLUGIN_ROOT/bin/farmctl scale implementer 2
  6. Pause/resume:    $PLUGIN_ROOT/bin/farmctl pause | resume"
else
  NEXT_STEPS="  3. No supervisor active (systemd/launchd) — 'farmctl' (start/dash/scale/pause) needs one. Run workers directly: $PLUGIN_ROOT/bin/farm-runner.sh implementer-1"
fi
cat <<EOF

$(printf '\033[1;32m')Install complete.$(printf '\033[0m')

Next steps:
  1. Sanity-check Claude auth (subscription, not a stray API key):
       claude -p "say ok" --dangerously-skip-permissions
       env | grep -q ANTHROPIC_API_KEY && echo "WARNING: ANTHROPIC_API_KEY is set — it would override your subscription"
  2. Seed the board:  inside claude →  /task-new <description>   (or kanban-md create ...)
$NEXT_STEPS

Recommended: add $PLUGIN_ROOT/bin to PATH for bare 'farmctl'.

SAFETY CHECKLIST before first unattended night (details: plugin README.md):
  [ ] gh auth = dedicated machine user, fine-grained token, THIS repo only, no admin
  [ ] branch protection on main: required checks + (recommended) CODEOWNERS on
      migrations / auth / payments / .github/workflows / CODEOWNERS itself
  [ ] AWS creds (if present) = dedicated IAM user with Deny boundary on
      Delete*/Terminate*/iam:*/purchasing + AWS Budgets alert (see README)
  [ ] guard hook active: ask claude to run 'aws s3 ls' → must be blocked
EOF
