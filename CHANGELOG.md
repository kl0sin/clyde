# Changelog

All notable changes to Clyde are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and Clyde uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Sparkle reads each version's section from this file and shows it inside
the "Update available" sheet, so write entries for end users — not for
yourself.

## [Unreleased]

## [0.2.0] — 2026-04-11

Expanded hook integration, attention reliability, and error visibility.

### Attention & status fixes

- **"Needs Input" no longer vanishes after 60 seconds.** The old
  mtime-based timeout silently expired attention events even when the
  permission prompt was still active in the terminal. Attention now
  persists for as long as the owning Claude process is alive — cleaned
  up only when the user actually responds (PreToolUse / Stop) or the
  process dies.
- **Clicking a session row no longer clears "Needs Input."** Previously,
  `focusSession()` eagerly called `clearAttention()` on click — the
  badge vanished the instant you tapped the row, even though the prompt
  was still unanswered. Attention is now cleared exclusively by hook
  events.
- **Permission denial now clears attention instantly.** Registered the
  `PermissionDenied` hook so denying a permission prompt drops the
  "Needs Input" badge immediately instead of waiting for the next
  `Stop` event.

### Expanded hook integration (v15)

Registered 9 new Claude Code hook events, bringing the total from 9
to 18. Highlights:

- **StopFailure error surfacing.** When Claude hits a rate limit,
  billing error, server error, or output-token cap, the session now
  shows a red "Rate limited" / "Server error" / "Error" badge instead
  of silently sitting on "Working" forever. The error clears
  automatically on the next successful `Stop`.
- **CwdChanged live updates.** If the user `cd`s to a different
  project mid-session, the project name in Clyde updates in real time
  instead of staying stuck on the original `SessionStart` cwd.
- **SessionStart source field.** The activity timeline now
  distinguishes "Session started" from "Session resumed" and "Context
  compacted" based on the `source` field in the hook payload.
- **Elicitation as attention.** MCP tools that request user input
  (forms, dialogs) now trigger the same "Needs Input" badge and
  notification as permission prompts. Cleared on `ElicitationResult`.
- **SubagentStart / SubagentStop tracking.** When Claude spawns a
  subagent, the activity timeline logs "Subagent: Explore" (or
  whichever agent type) and "Subagent finished".
- **Notification, PreCompact, PostCompact** registered for
  diagnostics (log-only, no UI yet).

### Landing page

- Global ambient lighting layer (`html::before`) replaces per-section
  radial gradients that were clipped by `overflow: hidden`, eliminating
  visible horizontal seams between sections.
- Smooth scroll with `scroll-padding-top` so anchor links land below
  the sticky nav.
- Support card background fixed (`var(--surface)` → `var(--bg-card)`).
- Button icon gap fixed on `.cta-secondary`.
- Feature/install/support sections use gradient-fade slab backgrounds
  instead of hard-border slabs.

### Known limitations

- Still **not code-signed or notarized** — same Gatekeeper workaround
  as v0.1.0 (right-click → Open).

## [0.1.0] — 2026-04-09

First public release of Clyde — a friendly menu bar companion that
tracks every Claude Code session on your Mac in real time.

### Session tracking

- **Real-time state via native Claude Code hooks.** No polling, no
  daemon, no privileged helper. Clyde reacts to `SessionStart`,
  `UserPromptSubmit`, `Stop`, `PermissionRequest` and related hook
  events within milliseconds of Claude firing them.
- **Three mutually-exclusive states** surfaced per session: `ready`,
  `working`, `needs input`. Counters in the expanded header and the
  bottom summary bar never double-count a session that's both busy
  and waiting on permission — attention always wins.
- **Identifies Claude processes by their actual launch name**
  (`argv[0]`) rather than the kernel's exec-image basename. This is
  what lets the `-busy` markers survive poll ticks on real
  installations, where the binary lives under a version-named
  directory like `~/.claude/2.1.96/cli.js`.
- **Handles `claude --resume` correctly.** A resumed session reuses
  its original `session_id` but runs under a brand-new PID — Clyde
  reconciles the two by `session_id`, revives the ghost row in
  place, and never shows the old + new rows side by side. A
  one-tick deferral on pgrep-only PIDs hides the ~500 ms race
  between the new binary appearing in `pgrep` and the
  `SessionStart` hook firing, so the visual handoff is seamless.
- **Ghost rows** linger for ~5 minutes after a session ends, so a
  closed terminal still shows "ended Xm ago" in the list instead of
  snapping off the screen.

### Menu bar, widget & UI

- **Menu bar capsule** with a pixel-accurate Clyde silhouette plus a
  coloured count for the dominant state (green = ready,
  purple = working, blue = needs input). Two smaller ticks show the
  non-dominant state counts on the right.
- **Floating widget panel** — drag it anywhere on screen, it snaps
  to the nearest edge, and click to expand into the session list.
  Hide it entirely from Settings if you prefer menu-bar only.
- **Expanded panel** with per-session rows: custom rename
  (per-session or per-`session_id`), drag-to-reorder with persistent
  order, click-to-focus the host terminal, and a live activity
  timeline at the bottom.
- **Stable row numbering.** Idle rows keep their slot index even
  when a neighbour flips to `working` — no renumber jitter as
  sessions transition.
- **Clyde mascot animation** runs in every non-sleeping state now,
  not only idle. The widget and expanded-header mascots blink /
  glance ambiently whether you're working, idle, or waiting on a
  permission prompt, so the app always feels alive.
- **Attention alerts** — sound + macOS notification the moment a
  `PermissionRequest` fires. Never miss a prompt again.
- **Snooze** (15m / 30m / 1h / 2h) mutes all sounds and
  notifications for quiet hours. Menu bar shows a `zzz` badge with
  the remaining minutes while active.
- **Global hotkey** ⌃⌘C to toggle the expanded panel from anywhere.
- **Terminal adapters** for Terminal.app, Warp, and Ghostty —
  clicking a session in the list focuses the correct hosting
  terminal window regardless of which one launched Claude.

### Hook installation & self-healing

- **Auto-installs the hook script** into `~/.claude/hooks/` on first
  launch, with an explicit opt-out toggle in Settings. Users who
  decline never get re-prompted.
- **Self-heals on every launch.** Clyde's health check detects
  missing script files, unexecutable permissions, outdated script
  versions, missing event registrations in `settings.json`, and
  (new in 0.1.0) matcher-less `PreToolUse` / `PostToolUse` entries
  that Claude Code would otherwise reject as malformed.
- **Watches `~/.claude/settings.json`** via FSEvents and re-runs the
  install within ~300 ms when another tool (claude-visual and
  similar) rewrites the file end-to-end and drops Clyde's entries.
  Echo suppression prevents a reinstall loop on Clyde's own writes.
- **Legacy migration.** Existing users who installed an older build
  of Clyde (under the `clyde-notify.sh` filename) get automatically
  migrated to the canonical `clyde-hook.sh` on first launch of
  0.1.0 — the legacy file is deleted, the new script is written,
  and `settings.json` is rewritten to reference the canonical path.
- **Advisory hook script.** `clyde-hook.sh` no longer propagates
  intermediate failures — it runs without `set -e`, catches errors
  via an `ERR` trap, logs them to `~/.clyde/logs/hook.log`, and
  always exits 0. Claude Code will never again surface a "Stop
  hook error" line because of our script.
- **Coexists with other hook owners.** `settings.json` merges
  Clyde's entries alongside whatever else is registered per event
  (claude-visual, custom scripts, etc.) without clobbering them,
  and dedupes cleanly across reinstalls.

### Diagnostics & onboarding

- **Detects missing Claude Code** at startup. If `~/.claude/` is
  absent and `claude` isn't on `PATH`, Clyde surfaces a banner
  pointing users at
  [claude.com/claude-code](https://claude.com/claude-code) instead
  of silently trying (and failing) to install its hook.
- **Reveal hook log** button in Settings → Maintenance. Selects
  `~/.clyde/logs/hook.log` directly in Finder so users can drag the
  file into a bug report without navigating by hand.
- **Reveal Clyde data folder** button for inspecting state / events
  files by hand.
- **Copy diagnostic info** button that collects version, hook
  state, session count, and recent activity into the clipboard for
  easy sharing.
- **Reset tracking state** option for when Clyde itself needs a
  hard reset (wipes `~/.clyde/state` and `~/.clyde/events`).
- **Acknowledgements sheet** in Settings with the verbatim MIT
  license text for Sparkle, the only third-party dependency.
- **Onboarding flow** on first launch with a welcome screen and a
  clear explanation of why the notification permission is needed.

### Support & project

- **GitHub Sponsors** integration via `.github/FUNDING.yml`. The
  repo page renders a "Sponsor" button that points at one-time and
  monthly tiers.
- **Buy Me a Coffee** link alongside Sponsors for users who prefer
  a one-off tip without creating a GitHub account.
- **Support section** on the landing page, in the README, and in
  Settings → Support development — all three surfaces point at the
  same two links. Entirely optional; there's no paid tier and no
  telemetry.

### Build & release

- **Universal binary** (Apple Silicon + Intel), macOS 13 Ventura
  and later.
- **Self-contained Swift Package.** No Xcode project required —
  `swift run Clyde` builds and runs from a clean checkout.
- **Credential-aware release pipeline.** The GitHub Actions workflow
  detects whether Apple Developer / Sparkle secrets are present
  and, if not, produces an unsigned DMG + pre-release automatically
  instead of failing the run. The same workflow will start
  producing signed + notarized builds the moment the secrets are
  added, with zero edits.
- **Bundled Sparkle framework** ready for future auto-updates.

### Quality

- **60 unit tests** covering the hook installer, ProcessMonitor,
  AppViewModel, SessionListViewModel, terminal adapters, and
  integration paths. Suite runs deterministically — test isolation
  via `AppPaths.homeOverride` redirects every filesystem access
  through a throwaway temp home, so nothing under the developer's
  real `~/.claude/` is ever touched during `swift test`.
- **Regression coverage for every reliability fix** that shipped in
  0.1.0: matcher-less `PreToolUse` entries, legacy `clyde-notify.sh`
  migration, third-party hook coexistence, `proc_name` vs `argv[0]`
  identity, `claude --resume` ghost revival, and the pgrep-only
  deferral path.
- **Manual smoke test document** (`docs/hook-smoke-test.md`)
  covering six end-to-end scenarios that unit tests can't reach —
  fresh install, legacy migration, external rewriter, permission
  prompt mid-flight, session resume, and Stop-hook noise triage.
  All six pass against the 0.1.0 build.

### Known limitations

- **Not yet code-signed or notarized.** On first launch macOS
  Gatekeeper will say the app is "from an unidentified developer".
  Right-click `Clyde.app` → **Open** → confirm in the dialog.
  macOS remembers the exception so subsequent launches are clean.
  Proper signing and notarization will ship in a later release.
- **Sparkle auto-updates are dormant.** The framework ships in the
  binary and the appcast URL is wired up, but the update channel
  won't find new versions until signed releases start publishing
  to it. For now, grab new versions from
  [Releases](https://github.com/kl0sin/clyde/releases) directly.
- **Homebrew cask** is drafted in `Casks/clyde.rb` but not yet
  published to a dedicated tap repo. `brew install` support will
  land alongside signed releases.

### Credits

Built in SwiftUI by [Mateusz Kłosiński](https://github.com/kl0sin).
Uses [Sparkle](https://sparkle-project.org/) (MIT) for future
in-app updates.
