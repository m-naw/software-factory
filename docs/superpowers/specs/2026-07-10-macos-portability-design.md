# macOS Portability — Design Spec

**Date:** 2026-07-10
**Branch:** `feat/macos-portability`
**Status:** Draft for review

## Goal

Make the agent-farm (now software-factory) plugin fully platform-agnostic across Linux and macOS. A user
installing and running on macOS must get the same behavior as on Linux, out of the box,
with **no degradation** — same auto-restart, same timers, same boot/logout persistence,
same security enforcement. The platform is detected automatically and the correct
mechanism is selected; the user does not choose or configure per-OS.

### Non-goals

- No Windows support.
- No new hard runtime dependencies. The engine stays pure bash (per `CLAUDE.md`).
  Homebrew is *optional* — if `coreutils`/`gnu tools` are present they are used as a fast
  path, but stock macOS (bash 3.2, BSD userland) must work unaided.
- No behavioral change on Linux. Every Linux code path stays byte-for-byte equivalent
  unless a shared helper provably reproduces it.

### Success criteria

1. `engine/tests/run.sh` passes on both stock macOS (bash 3.2, BSD tools) and Linux.
2. A fresh `engine/install.sh` on macOS scaffolds the board/config and installs working
   launchd agents: workers auto-restart on crash, scout/janitor fire on their intervals,
   agents survive logout/reboot.
3. The guard hook's worktree-confinement check blocks `../`-escape and symlink-escape
   writes identically on both platforms.
4. `farmctl` verbs (`start`, `stop`, `scale`, `status`, `logs`, `scout-now`, `doctor`,
   `dash`) work on both platforms.
5. A `macos-latest` CI job runs the full suite green.

## Decisions locked with the user

- **Toolchain strategy:** zero-dependency, native BSD. Runtime detects GNU-vs-BSD and
  uses portable shims; prefers `gdate`/`gtimeout`/etc. when on PATH, else BSD-native.
- **Supervision:** full launchd parity (KeepAlive restart, StartInterval timers,
  RunAtLoad persistence). `farmctl` dispatches to `launchctl` or `systemctl` by OS.
- **macOS CI job:** yes — parity is CI-enforced, not merely claimed.

## Architecture overview

Three layers of change, in order of blast radius:

1. **Portability helpers** — a new block in `bin/farm-lib.sh` (the shared, sourced lib).
   Every runtime script already sources it, so helpers propagate for free. Each helper is
   a thin wrapper; where a decision is involved it splits into a pure decider + wrapper,
   per the repo's testability convention.
2. **Supervision abstraction** — a set of `sup_*` verbs (in `farm-lib.sh`) that `farmctl`
   and `install.sh` call instead of raw `systemctl`. Each verb dispatches on `farm_os`.
   launchd `.plist` templates added alongside the existing systemd units.
3. **Security canonicalizer** — inlined in `hooks/guard-bash.sh` (the guard must not depend
   on `farm-lib.sh`). Prefers `realpath -m`/`grealpath` when present (Linux keeps its exact
   current behavior — no regression) and falls back to a self-contained pure-bash
   canonicalizer only on stock macOS, differential-fuzzed against `realpath -m` in CI. Also
   fixes a macOS fail-OPEN in the merge gate and adds launchd service/plist tamper
   protection.

---

## Layer 1 — Portability helpers (`bin/farm-lib.sh`)

All helpers cache `farm_os` and prefer a GNU binary when present.

### `farm_os`
Returns `linux` or `macos` from `uname -s` (Darwin → `macos`), cached in a global on
first call. All other helpers branch on it.

### Date / time helpers
BSD `date` supports neither `-d` (arbitrary parse) nor `-Is`/`-I` (ISO output). Replace
every GNU-only `date` invocation with a helper:

| Helper | Replaces | Linux | macOS |
|---|---|---|---|
| `farm_now_iso` | `date -Is` | `date -Is` | `date +%Y-%m-%dT%H:%M:%S%z`, then insert `:` in the offset to match `-Is` byte-for-byte |
| `farm_epoch_to_iso <e>` | `date -d "@$e" -Is` | `date -d "@$e" -Is` | `date -r "$e" +…%z` + offset-colon fixup |
| `farm_iso_to_epoch <iso>` | `date -d "$iso" +%s` | `date -d "$iso" +%s` | normalize input, then `date -j -f <fmt> "$iso" +%s` |
| `farm_when_epoch <spec>` | `date -d "today\|tomorrow\|next <day> …"` | `date -d …` | `date -v` arithmetic |

Notes (each incorporates a spec-review finding):
- Each helper first tries `gdate` (GNU coreutils on Homebrew) and uses the GNU form if
  found; this keeps one well-tested path for brew users and confines the BSD arithmetic
  to the fallback.
- **`farm_now_iso` offset parity (review MINOR-7):** Linux `date -Is` emits `±HH:MM`; BSD
  `%z` emits `±HHMM` (no colon). The macOS path inserts the colon so both platforms emit
  the *identical* string — no Linux behavior change (Linux still literally runs `date -Is`),
  and no latent format drift for any consumer. `farm_epoch_to_iso` gets the same fixup.
- **`farm_iso_to_epoch` input normalization (review BLOCKER-1):** kanban `claimed_at`/
  `updated` timestamps are `Z`-suffixed (proven: jq `fromdateiso8601` at `farm-lib.sh:764`
  accepts only `…Z`). BSD `date -j -f` with `%z` parses **neither** a trailing `Z` nor a
  colon offset. The helper first normalizes the input — `Z`→`+0000`, and strips `:` from a
  `±HH:MM` offset — then picks the matching `-f` format (`…%z` when an offset is present,
  `…` without `%z` for a bare/Z-normalized UTC value). GNU `date -d` handles all forms
  natively, so the normalization is macOS-path-only. Unit-tested against the exact
  `…Z` form kanban actually emits.
- **`farm_when_epoch` same-weekday bug (review MAJOR-2):** it must parse `"today HH:MM"`,
  `"tomorrow HH:MM"`, and `"next <weekday> 00:00"` (the forms at `farm-lib.sh:247-251`).
  BSD `date -v<weekday>` resolves to the CURRENT week — so `-vfri` on a Friday yields
  *today*, whereas GNU `date -d "next fri"` always advances +7. Left unfixed, on the
  matching weekday the limit gate would compute a past epoch and never hold. The pure
  decider `_when_epoch_decide` special-cases "same weekday as today" → add `+7d`. The
  decider maps a `(spec, today-weekday)` pair to a `date` argv for the active platform and
  is unit-tested per spec form and per weekday-vs-today combination, without reading the
  live clock (weekday passed in).
- Portable `date` forms already in the code (`date +%s`, `date +%Y%m%d-%H%M%S`) are left
  untouched.

Call sites updated: `farm-lib.sh` log() and ~8 date sites; `farmctl:63,166`. The test
suite's own `date -Is` (`run.sh:2420`) is switched to the helper so the suite runs on mac.

### `farm_timeout <seconds> <cmd...>`
macOS has no `timeout`. Dispatch chain: `timeout` → `gtimeout` → pure-bash fallback
(`_bash_timeout`). **Process-group kill (review MAJOR-5):** `gh`/`git` spawn children
(credential helpers, git subprocesses), and the scout's `RuntimeMaxSec=3600` substitute
wraps a whole scout run — killing only the direct child would leak the tree that systemd's
cgroup kill reaps. The fallback runs the command in its **own process group**
(`set -m`/backgrounded so it becomes a group leader, or via `setsid` when available) and
on timeout sends `-TERM` then `-KILL` to the *negative pid* (whole group), then `wait`s
the child and cancels the killer subshell (no zombie). Exit code is non-zero on timeout
(143/124 is not depended on — every call site is `|| true` / `if !`-guarded: verified
`farm-lib.sh` 524,714,737,954,963,1302 and `farm-janitor.sh` 152–395). Replaces ~20 sites.

### `farm_stat_size <file>`
GNU `stat -c %s` vs BSD `stat -f %z`. Replaces `farmctl:98` (currently `|| echo "?"`
guarded; keep the guard).

### `farm_sed_inplace <script> <file>`
GNU `sed -i` vs BSD `sed -i ''`. Replaces `install.sh:177` (board escalation-status
migration). Implemented by passing an explicit empty backup suffix on BSD and cleaning up.

### Readable-log renderer (replaces `tail --pid`)
`farm-runner.sh:218` uses `tail -n +1 --pid="$CLAUDE_PID" -F` so the human-readable
renderer self-exits when claude dies. BSD `tail` has no `--pid`. Replacement requirement:
the renderer must still self-terminate when `CLAUDE_PID` exits, on both platforms, without
`--pid`, and must NOT become `$CLAUDE_PID`'s parent/child in a way that breaks the
lease-guard fencing invariant (the raw claude exec must stay the tracked pid).

**Process-group teardown (review MAJOR-4):** `RENDER_PID=$!` is the *subshell wrapper*
pid; inside it `tail -F | jq` are separate children. `tail -F` never EOFs on its own, so
`kill "$RENDER_PID"` alone leaves `tail`/`jq` reparented to init and leaking. The renderer
subshell is therefore started in its **own process group** (`setsid` when present, else
`set -m` group-leader), and both the reaper AND `cleanup()` (`farm-runner.sh:234`) kill the
**process group** (negative pid), not just `RENDER_PID`. Approach: keep `tail -F | jq` in
its backgrounded group, capture the group pid, and add a reaper that polls
`kill -0 "$CLAUDE_PID"` and tears the whole group down when claude is gone. Verified by a
test that starts a fake "claude" pid, kills it, and asserts BOTH the wrapper and its
`tail` child exit (no leaked follower).

### `$BASHPID` removal (bash 3.2 compat)
`farm-lib.sh:953` records the ci-watch subshell's own pid via `$BASHPID` (bash 4.0+;
empty on macOS stock bash 3.2), so the liveness lock can detect a dead watcher. Refactor
`spawn_ci_watch` so the **parent** records the backgrounded watcher's pid via `$!`
(portable to bash 3.2) instead of the child self-recording `$BASHPID`. For `( … ) &`,
the parent's `$!` equals the child subshell's `$BASHPID`, so the lock still holds the
watcher's pid and the `kill -0` liveness check (`farm-lib.sh:943`) is unchanged. No other
bash-4 feature is used anywhere in the codebase, so no Homebrew-bash requirement is
introduced. **Test update (review MINOR-8):** `run.sh:2404-2405` currently asserts the
literal `echo "$BASHPID" > "$lock"` string (and the F4-lock comment at :2378); both are
updated to the `$!`-based form so CI stays green.

---

## Layer 2 — Supervision abstraction

### `sup_*` verbs (in `farm-lib.sh`, dispatched by `farm_os`)

| Verb | systemd (Linux) | launchd (macOS) |
|---|---|---|
| `sup_enable_worker <role> <n>` | `systemctl --user enable --now claude-farm@<role>-<n>` | generate per-instance plist + `launchctl bootstrap gui/$UID <plist>` |
| `sup_disable_all_workers` | `systemctl --user stop/disable 'claude-farm@*'` | enumerate `com.agent-farm.worker.*` labels; `launchctl bootout gui/$UID/<label>` each |
| `sup_list_workers` | `systemctl --user list-units 'claude-farm@*'` | `launchctl list \| grep com.agent-farm.worker` |
| `sup_start_timers` | `systemctl --user enable --now claude-scout.timer claude-janitor.timer` | `launchctl bootstrap gui/$UID <scout/janitor plists>` |
| `sup_stop_all` | `systemctl --user stop 'claude-farm@*'` + timers | enumerate + `launchctl bootout gui/$UID/<label>` all `com.agent-farm.*` |
| `sup_scout_now` | `systemctl --user start claude-scout.service` | `launchctl kickstart gui/$UID/com.agent-farm.scout` |
| `sup_logs [unit]` | `journalctl --user -f -u …` | `tail -F` the plist's StandardOut/ErrorPath files |
| `sup_status` | `systemctl --user list-units …` | `launchctl list` + plist presence |
| `sup_doctor_units` | check `$UNIT_DIR/*.service` staleness | check `~/Library/LaunchAgents/*.plist` staleness |

Every current raw `systemctl`/`journalctl` call in `farmctl` and `install.sh` is routed
through these verbs. Linux verbs are the existing commands verbatim (no Linux behavior
change). The pure decider pattern is applied where a verb selects an argv, so the mapping
is unit-testable by forcing `farm_os`.

**launchctl domain-target syntax (review MAJOR-6):** modern `launchctl`
(`bootstrap`/`bootout`/`kickstart`/`enable`) requires a domain target, not a bare label or
glob. All macOS verbs use `gui/$(id -u)` for the domain and enumerate concrete labels
(launchd has no glob) — e.g. `bootstrap gui/$UID <plist>`, `bootout gui/$UID/<label>`,
`kickstart gui/$UID/com.agent-farm.scout`. Enumeration lists `~/Library/LaunchAgents/
com.agent-farm.*.plist` (or `launchctl list`) to derive labels for stop/boot-out.

### launchd plist templates (new, under `engine/launchd/`)

- `com.agent-farm.worker.plist.template` — per-worker; `%i`-equivalent filled by farmctl at
  scale time (label `com.agent-farm.worker.<role>-<n>`). **`KeepAlive` = boolean `true`
  (review MAJOR-3)** — this is the true analog of `Restart=always`; `KeepAlive={SuccessfulExit
  =false}` would be `Restart=on-failure` and would NOT restart a clean-exit runner loop.
  `ThrottleInterval` = 15 ≈ `RestartSec=15`. Plus `RunAtLoad=true`, `EnvironmentVariables`
  = `{NO_COLOR: 1}`, `StandardOutPath`/`StandardErrorPath` under the farm log dir,
  `ProgramArguments` = `[<FARM_BIN>/farm-runner.sh, <role>-<n>]`.
- `com.agent-farm.scout.plist.template` — `StartInterval` = 10800s (≈ `OnUnitInactiveSec=3h`),
  `RunAtLoad=false` (see first-fire note below); `RuntimeMaxSec=3600` has no launchd equal
  → the scout `ProgramArguments` invokes the scout through `farm_timeout 3600` (with the
  process-group kill above) so the 1h hard kill is preserved even for a hung child tree.
- `com.agent-farm.janitor.plist.template` — `StartInterval` = 1800s (≈ 30min),
  `RunAtLoad=true` (cheap; ≈ systemd `OnBootSec=5min` first-fire).

**Timer first-fire (review MINOR-9, accepted):** systemd uses `OnBootSec` (scout ≈20min,
janitor ≈5min) for the first run. launchd `StartInterval` + `RunAtLoad=false` delays the
first fire a full interval. Janitor sets `RunAtLoad=true` (cheap, near-immediate — close to
its 5min). Scout keeps `RunAtLoad=false`, so its first run is +3h rather than +20min after
install/login — deliberately, to avoid a heavy scout pass at startup (matching the intent
of systemd's *delay*, differing only in magnitude). This is a minor timing nuance, not a
functional degradation; documented as accepted. `RandomizedDelaySec` jitter is likewise
approximated by `StartInterval` (accepted minor difference).

### Instance templating

systemd's `claude-farm@<instance>` template has no launchd analog. `farmctl scale` on
macOS renders one concrete plist per instance from the template into
`~/Library/LaunchAgents/` and bootstraps it; scaling down boots out and removes the
per-instance plists. On Linux, scale keeps using the `@`-templated unit unchanged.

---

## Layer 3 — Security canonicalizer (`hooks/guard-bash.sh`)

The guard is self-contained (must run even if `farm-lib.sh` is broken), so all of the below
is **inlined in the guard**, not sourced.

### Path canonicalizer (`guard-bash.sh:164-166`)

**Prefer the reference tool, fall back to pure-bash (review MAJOR-1c):** to avoid *lowering*
Linux onto a hand-rolled implementation, the canonicalizer uses `realpath -m` /
`grealpath -m` when present (Linux keeps its exact current behavior — **no regression**),
and only falls back to a pure-bash `_canon_path` on stock macOS where neither exists. The
pure-bash fallback is differential-fuzzed against `realpath -m` in CI (below) so the two
are proven equivalent over an adversarial corpus.

`_canon_path <path>` requirements (fallback path only):
1. Make absolute (prepend `$PWD` if relative).
2. **Single left-to-right component walk (review MAJOR-1a — critical).** Do NOT phase-
   separate symlink resolution from `..` collapse. Walk components one at a time building a
   resolved output; for each component: `.` → skip; `..` → pop the LAST already-resolved
   output component (never past `/`); otherwise append, then if the appended path is a
   symlink, resolve it (see 3) before continuing. This defeats the symlink+`..` interleave
   escape (`/wt/link/../secret` with `link→/outside` must canon to `/secret`, deny — a
   phase-separated impl would wrongly yield `/wt/secret`, allow).
3. **Symlink chains with a cycle cap (review MAJOR-1b).** Resolve each symlink with
   single-level `readlink` (portable, no `-f`) in a loop that re-resolves relative targets
   against the current resolved dir; cap iterations (e.g. 40) and on exceeding the cap
   **fail closed** (treat as an escape / deny) rather than spin — a symlink loop must never
   hang the PreToolUse hook.
4. Nonexistent tail components are kept lexically (matches `realpath -m` allowing paths
   that don't exist yet — the file being written may not exist).
5. No external GNU tool dependency in the fallback.

**Fail-closed compare (review MINOR-1d, accepted):** the final `case` compare stays
byte-sensitive while APFS/HFS+ are case/normalization-insensitive → a mismatch resolves to
*deny*, the safe direction. Documented, accepted.

Tests cover, on `_canon_path` directly (platform-independent) and via the guard end-to-end:
`../`-escape blocked, **symlink+`..` interleave escape blocked**, symlink-chain escape
blocked, symlink-loop → deny (no hang), in-worktree allowed, state-dir allowed, `/tmp`
allowed. Plus a **differential-fuzz test**: generate an adversarial path corpus and assert
`_canon_path` agrees with `realpath -m` on every input (skipped only where `realpath -m`
is unavailable).

### Merge gate fail-closed (`guard-bash.sh:70-71` — review BLOCKER-2)

Today: line 70 falls back to `dirname "$(readlink -f "$0")"` to locate
`defaults/protected-paths.txt`; BSD `readlink` lacks `-f`, so on macOS the fallback path is
wrong, `[[ -f "$PP_FILE" ]]` at :71 is false, and the **entire merge-check block is
skipped — `gh pr merge` on a protected surface is ALLOWED (fail-OPEN).** Two fixes:
1. Make the `$0`-relative resolution portable (a small `_script_dir` using `cd`/`pwd -P`,
   no `readlink -f`), and also fix the same `readlink -f` at the protected-paths lookup.
2. **Fail closed:** replace the silent `if [[ -f "$PP_FILE" ]]; then … fi` with an `else`
   that **denies the merge** when `protected-paths.txt` cannot be located — the merge gate
   must never be skipped merely because its policy file wasn't found. This matches the
   already-documented fail-closed stance at :59-61 and the blind-merge deny at :84-85.

### Service-tampering parity (`guard-bash.sh:129`)

Add a `launchctl` deny mirroring the `systemctl stop/disable/mask/kill` rule, covering the
supervisor-killers: `bootout|boot-out|unload|remove|stop|kill|disable` and
`kickstart …-k` (the `-k` form kills the running instance). Anchored exactly like the
systemctl rule. Domain-target forms (`bootout gui/$UID/<label>`) are caught by the
subcommand keyword.

### Plist self-tampering (review MAJOR-5)

The self-tampering rules at `:106` and `:125-127` protect the plugin's own rails
(`agent-farm/(hooks|bin|systemd)`, `guard-bash.sh`, workflows, etc.) but miss the macOS
supervision surface. Add:
- `launchd` to the plugin-source alternation at `:106` (so `agent-farm/(hooks|bin|systemd|
  launchd)` is read-only), and `engine/launchd/` coverage.
- `Library/LaunchAgents/com\.agent-farm` and `\.agent-farm.*\.plist` to the inverted
  name-match rule at `:125`, so an agent cannot rewrite its own runtime plist
  (`ProgramArguments`, drop `KeepAlive`) via a redirection or interpreter one-liner —
  parity with the Linux systemd-unit protection.

Note: `defaults/protected-paths.txt` is the *adopting-repo* merge-gate default
(`.github/workflows/*`, `CODEOWNERS`, `.claude/*`, `.agent-farm/*`) and does not enumerate
plugin-source dirs like `engine/systemd/` — so no `engine/launchd/*` entry is added there.
Plugin-source rails are protected by the guard self-tampering rules above, which is where
the `launchd` additions belong.

---

## Installer changes (`engine/install.sh`)

- Detect `farm_os`; branch the unit-install block: Linux writes systemd units to
  `$UNIT_DIR` (`~/.config/systemd/user`) as today; macOS renders launchd plists to
  `~/Library/LaunchAgents/` and `launchctl bootstrap`s the scout/janitor agents.
- Abstract `UNIT_DIR` per OS.
- PATH drop-ins: add `/opt/homebrew/bin` (Apple Silicon Homebrew) ahead of
  `/usr/local/bin`.
- Dependency-check hint: add a `brew install git curl jq tmux gh` line beside the existing
  apt hint (cosmetic; no package manager is invoked).
- kanban-md: keep the existing Darwin guard (`install.sh:102`); improve its message to
  point at `brew install` / `go install` for macOS.
- linger: `loginctl enable-linger` stays Linux-only (LaunchAgents persist per-user with no
  linger equivalent) — already guarded by `command -v loginctl`.

---

## Docs / skills / manifest

Make systemd-specific operator text OS-aware (say "systemd on Linux / launchd on macOS"):
- `skills/farm-orchestration/SKILL.md` (`journalctl`, `systemctl` mentions)
- `skills/agent-farm-init/SKILL.md` ("installs the systemd user units")
- `defaults/prompts/scout.md` + `templates/project-prompts/scout.md` ("systemd RuntimeMaxSec")
- `.claude-plugin/plugin.json` description/keywords

---

## Testing strategy

The existing suite (`engine/tests/run.sh`, no framework, pure bash) is extended, not
restructured.

1. **Helper unit tests** — every new helper tested on both code paths by forcing
   `farm_os` and stubbing the tool: `farm_now_iso` (offset-colon parity), `farm_epoch_to_iso`,
   `farm_iso_to_epoch` (incl. the exact `…Z` form kanban emits, and a `±HH:MM` offset),
   `_when_epoch_decide` (argv per spec form AND same-weekday→+7d for every weekday),
   `farm_timeout` (success, timeout kills the whole process group incl. a grandchild, GNU
   vs fallback), `farm_stat_size`, `farm_sed_inplace`.
2. **Canonicalizer tests** — `_canon_path` for `../`-escape, **symlink+`..` interleave
   escape**, symlink-chain escape, **symlink-loop → deny without hanging**, in-worktree,
   state-dir, `/tmp`; plus a **differential-fuzz** test asserting `_canon_path` matches
   `realpath -m` over an adversarial corpus (skipped where `realpath -m` absent). Run the
   guard end-to-end with `FARM_WORKTREE` set and assert deny/allow, as existing guard tests do.
3. **Merge-gate fail-closed test** — with `protected-paths.txt` unlocatable, assert
   `gh pr merge` is DENIED (not skipped). Preserves the fail-closed rail on macOS.
4. **Service-tampering tests** — assert `launchctl bootout/kickstart -k/disable …` is
   denied, and a redirection/interpreter write to a `com.agent-farm.*.plist` is denied.
5. **Supervision decider tests** — force `farm_os`, assert each `sup_*` verb selects the
   correct argv (systemctl vs `launchctl … gui/$UID/<label>`) without invoking either.
6. **Renderer self-exit test** — fake claude pid, kill it, assert BOTH the renderer wrapper
   and its `tail` child exit (no leaked follower), without `--pid`.
7. **Suite self-portability** — remove the suite's own `date -Is` / `sha256sum` /
   hardcoded-PATH assumptions, and update the `$BASHPID`→`$!` lock assertions
   (`run.sh:2378,2404-2405`), so it runs green on stock macOS.
8. **CI** — add a `macos-latest` job to `.github/workflows/farm-ci.yml` running
   `engine/tests/run.sh` and the shellcheck line. Keep the existing `ubuntu-latest` job.

All changes must keep `shellcheck -x -S warning` clean over the expanded file set
(including any new `engine/launchd/*` generator code if it lives in shell).

## Risks & mitigations

| Risk | Mitigation |
|---|---|
| BSD `date -v` weekday math differs from GNU `date -d "next <day>"` (same-weekday stays today) | `_when_epoch_decide` special-cases same-weekday→+7d; unit-tested per spec form × weekday (review MAJOR-2) |
| launchd restart semantics ≠ `Restart=always` | `KeepAlive=true` (bool) = always-restart; `ThrottleInterval=15` ≈ `RestartSec=15` (review MAJOR-3) |
| Pure-bash `_canon_path` diverges from `realpath -m` | Guard prefers `realpath -m`/`grealpath` when present (Linux unchanged — no regression); pure-bash used only on stock macOS and differential-fuzzed against `realpath -m` in CI; single left-to-right walk defeats symlink+`..` interleave; cycle cap fails closed (review MAJOR-1a/b/c) |
| `farm_timeout` fallback leaks a child tree or zombie killer | Process-group kill reaps grandchildren; killer `wait`ed/cancelled on normal completion; tested with a grandchild (review MAJOR-5) |
| Merge gate fails OPEN on macOS if `protected-paths.txt` unlocatable | Portable `$0`-dir resolution + explicit `else deny` — fail closed (review BLOCKER-2) |
| macOS CI runner flakiness/cost | Single job, same suite; can be marked non-required initially if needed |

## Out of scope / accepted differences

- Exact timer jitter (`RandomizedDelaySec`) and boot-delay (`OnBootSec`) semantics are
  approximated by `StartInterval` — same *function* (periodic execution), minor timing
  nuance only.
- Homebrew is never required; if absent, all fallbacks are native BSD.
