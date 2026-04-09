# Changelog

All notable changes to Clyde are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and Clyde uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Sparkle reads each version's section from this file and shows it inside
the "Update available" sheet, so write entries for end users — not for
yourself.

## [Unreleased]

## [0.1.0] — 2026-04-09

First public release of Clyde — a friendly menu bar companion that
tracks every Claude Code session on your Mac in real time.

### Highlights

- **Real-time session tracking** via Claude Code's native hooks. No
  polling, no daemon, no privileged helper. Clyde reacts to
  `UserPromptSubmit` / `Stop` / `PermissionRequest` / `SessionStart`
  within milliseconds.
- **Floating menu bar widget** with a dominant-state capsule — a
  single colour at a glance: green = ready, purple = working,
  blue = needs input.
- **Expanded session list** with drag-to-reorder, custom names, and
  click-to-focus the matching terminal window (Terminal.app, Warp,
  Ghostty).
- **Attention alerts** — sound + macOS notification the moment Claude
  asks for permission.
- **Activity timeline** of recent prompts, permissions and session
  lifecycle events.
- **Snooze** (15m / 30m / 1h / 2h) for quiet hours.
- **Global hotkey** ⌃⌘C to expand from anywhere.
- **Self-installing hook** — Clyde writes `clyde-hook.sh` into
  `~/.claude/hooks/` and self-heals when another tool (or the user)
  corrupts or removes its registration in `settings.json`.
- **Detects missing Claude Code** at startup and surfaces a helpful
  banner instead of silently failing.
- **Reveal hook log** button in Settings for easy diagnostics.
- **Supports the project** via GitHub Sponsors and Buy Me a Coffee
  links in Settings, README, and the landing page. Entirely optional
  — there's no paid tier and no telemetry.
- **Universal binary** (Apple Silicon + Intel), macOS 13 Ventura and
  later.

### Known limitations

- **Not yet code-signed or notarized.** On first launch macOS
  Gatekeeper will warn about an unidentified developer; right-click
  the app → **Open** to confirm the exception. Proper signing and
  notarization will land in a later release.
- **Sparkle auto-updates** are wired into the binary but the update
  channel is dormant until signed releases start publishing to the
  appcast. For now, grab new versions from GitHub Releases directly.

### Credits

Built in SwiftUI by [Mateusz Kłosiński](https://github.com/kl0sin).
Uses [Sparkle](https://sparkle-project.org/) (MIT) for future
in-app updates.
