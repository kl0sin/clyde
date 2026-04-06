# Clyde

A native macOS floating widget that monitors Claude Code sessions. Know at a glance when Claude is working, ready, or waiting for your input — without switching to the terminal.

## Features

- **Floating widget** — always-on-top, compact, with Clyde the mascot showing global state
- **Session monitor** — detects all running Claude Code sessions, shows which project each one belongs to
- **Smart state detection** — uses child process tree walk (not CPU heuristics) to reliably tell busy from idle
- **Click to focus** — click any session to jump to its terminal window (auto-detects iTerm2, Terminal.app, Warp, Ghostty)
- **Attention alerts** — installs a Claude Code hook that signals when permission is required
- **Custom sounds** — different sounds for "session ready" and "permission needed"
- **Menu bar icon** — alternative access point with dropdown session list

## Requirements

- macOS 13 Ventura or later
- Xcode 15+ (for building)
- Claude Code CLI installed

## Building

```bash
# Development build
swift build

# Release build with .app bundle
./scripts/build-app.sh release
```

The `.app` bundle is created at `.build/release/Clyde.app`.

## Installation

```bash
# Build and install
./scripts/build-app.sh release
cp -r .build/release/Clyde.app /Applications/
open /Applications/Clyde.app
```

## Usage

1. **Launch Clyde** — the floating widget appears in the top-right corner
2. **Click the widget** to expand the session list
3. **Double-click a session name** to rename it
4. **Click a session row** to focus its terminal window
5. **Right-click the widget** for context menu (Open, Settings, Quit)

### Settings

Open via the gear icon or right-click menu:

- **Monitoring** — polling interval (1–10 seconds)
- **Sound** — enable/disable + separate sounds for "ready" and "needs input"
- **Claude Integration** — one-click install/uninstall of the attention hook
- **About** — version info and quit

### Claude Hook Integration

When enabled, Clyde installs a bash script at `~/.claude/hooks/clyde-notify.sh` and adds it to your `~/.claude/settings.json` as a `PermissionRequest` hook. The hook writes event files to `~/.clyde/events/` which Clyde polls every second.

Safe to uninstall — the uninstaller cleans both the script and the settings entry while preserving your other hooks.

## Architecture

- **Swift + SwiftUI** (macOS 13+, no external dependencies)
- **MVVM** — View Models wrap services, Views observe via `@Published`
- **NSPanel** — borderless floating panel with custom 120fps animation
- **Services layer**:
  - `ProcessMonitor` — polls `pgrep -x claude` + `pgrep -P` for state
  - `AttentionMonitor` — watches `~/.clyde/events/` for hook signals
  - `HookInstaller` — merges hook into `~/.claude/settings.json`
  - `TerminalLauncher` — walks process tree, dispatches to per-terminal adapters
  - `NotificationService` — sounds and system notifications

## Development

```bash
# Run tests
swift test

# Run app in debug mode
swift build && ./.build/debug/Clyde
```

### Project structure

```
Clyde/
├── App/              # AppDelegate, ClydeApp, Info.plist
├── Models/           # Session, ClydeState
├── Services/         # ProcessMonitor, AttentionMonitor, TerminalLauncher, ...
├── TerminalAdapters/ # iTerm2, Terminal.app, Warp, Ghostty
├── ViewModels/       # AppViewModel, SessionListViewModel
└── Views/
    ├── Components/   # SessionRow, TitleBar, SummaryBar, ...
    ├── WidgetView, ExpandedView, ContentView, SettingsView, ClydeAnimationView
```

## License

TBD
