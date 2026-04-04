# Clyde — macOS Menu Bar App Design Spec

## Overview

Clyde is a native macOS app that monitors Claude Code sessions. It sits as a floating always-on-top widget showing a pixel art robot mascot whose animation state reflects whether any Claude Code session is actively processing. Clicking the widget expands it into a full window with session tabs for switching between terminal sessions.

**Target:** macOS 13 Ventura+
**Stack:** Swift, SwiftUI, MVVM
**Dependencies:** None (native Apple frameworks only)

---

## Architecture

Three-layer MVVM architecture:

### UI Layer (SwiftUI)
- `WidgetView` — collapsed state, shows Clyde + status text
- `ExpandedView` — tabs, session detail, status bar
- `ClydeAnimationView` — pixel art sprite with state-driven animations
- `SettingsView` — terminal selection, polling interval, notifications

### ViewModel Layer
- `AppViewModel` — manages window state (collapsed/expanded), global Clyde animation state
- `SessionListViewModel` — manages session list, tab selection, naming

### Services Layer
- `ProcessMonitor` — polls system processes, classifies busy/idle
- `TerminalLauncher` — manages terminal adapters, opens/focuses sessions
- `NotificationService` — macOS notifications on state changes

### Data Flow
```
Services → @Published → ViewModels → SwiftUI Views
```
All reactive via Combine/SwiftUI observation.

---

## Window Management

Single `NSPanel` with `.floating` + `.nonactivatingPanel` style flags.

### Collapsed State (~80x100pt)
- Dark rounded rectangle (background: #1a1a1a, border-radius: 14pt)
- Clyde pixel art sprite (48x48pt, rendered from 16x16 grid)
- Status text below: "2 active" / "all idle" / "sleeping"
- Draggable anywhere on screen
- Always-on-top via NSPanel `.floating`
- Click → animated expansion to full window

### Expanded State (~360x400pt, resizable)
- **Title bar:** mini Clyde icon + "Clyde" label + settings gear + collapse button
- **Tab bar:** horizontal scrollable tabs, one per session. Each tab shows:
  - Colored status dot (red = busy, green = idle)
  - Session name (auto-detected CWD basename, or user-assigned custom name)
  - "+" button at the end to create new session
- **Session detail panel:**
  - Status badge (BUSY/IDLE) with duration timer
  - Working directory (full path, monospace)
  - PID
- **Status bar (bottom):** aggregate summary — "2 sessions · 1 busy · 1 idle"

### Animation
Transition between collapsed and expanded uses `NSWindow.setFrame(_:display:animate:)` for smooth native resize animation.

### Interactions
| Action | Result |
|--------|--------|
| Click collapsed widget | Animate expand to full window |
| Click tab | Focus terminal window with that session (AppleScript) |
| Click "+" | Open new session in default terminal |
| Click "−" (collapse) | Animate shrink back to widget |
| Click "⚙" | Show settings view |
| Drag widget | Reposition on screen |

---

## Clyde Pixel Art Mascot

16x16 pixel grid rendered on SwiftUI `Canvas` with `image-rendering: pixelated` equivalent. White/light gray pixels on dark background (#1a1a1a).

### Robot Design
- Antenna (top center, green tip)
- Rectangular head with two square eyes, mouth
- Rectangular body, two arms, two legs

### Animation States

| State | Condition | Animation |
|-------|-----------|-----------|
| **BUSY** | >= 1 session is busy | Blinking eyes (every ~2s), animated mouth (3 frames), trembling arms (±1px), pulsing antenna (green ↔ bright green) |
| **IDLE** | All sessions idle | Static pose, smile, occasional blink every ~4s |
| **SLEEPING** | No sessions detected | Closed eyes, animated "zzz" floating beside head |

Animations driven by `TimelineView` with `withAnimation` for smooth transitions between states.

---

## Process Monitoring

`ProcessMonitor` service polls the system at a configurable interval (default: 3 seconds).

### Polling Pipeline

**Step 1 — Discover sessions:**
```bash
pgrep -x claude
```
Returns list of PIDs for all running `claude` processes.

**Step 2 — Classify status per PID:**
```bash
ps -p <PID> -o %cpu=
```
- CPU > 5% → **BUSY**
- CPU ≈ 0% for 2 consecutive reads (6s at default interval) → **IDLE**

The 2-read requirement prevents false idle detection during brief CPU pauses.

**Step 3 — Detect working directory:**
```bash
lsof -p <PID> -d cwd -Fn | grep '^n/' | head -1
```
Uses `lsof` with `-d cwd` flag to get the current working directory directly. The `-Fn` flag outputs just the filename for easy parsing.

**Step 4 — Diff with previous state:**
- New PID → new session, add tab automatically
- Missing PID → session ended, remove tab (with brief "ended" state)
- CPU change → update status; if BUSY → IDLE, trigger notification

**Step 5 — Aggregate global state:**
- Any PID busy → Clyde = BUSY (animated)
- All PIDs idle → Clyde = IDLE (static)
- No PIDs → Clyde = SLEEPING

### Implementation
Uses Swift `Process` to run shell commands. Timer via `Task.sleep` in an async loop. Results published via `@Published` properties on `ProcessMonitor`.

---

## Terminal Integration

### TerminalAdapter Protocol

```swift
protocol TerminalAdapter {
    var name: String { get }
    var bundleIdentifier: String { get }
    var isInstalled: Bool { get }
    
    func openNewSession() async throws
    func focusSession(parentPID: pid_t) async throws
}
```

Each supported terminal implements this protocol in a separate file.

### MVP Adapters

| Terminal | Bundle ID | Method |
|----------|-----------|--------|
| iTerm2 | `com.googlecode.iterm2` | AppleScript: `create tab`, `write text "claude"` |
| Terminal.app | `com.apple.Terminal` | AppleScript: `do script "claude"` |
| Warp | `dev.warp.Warp-Stable` | `open -a Warp` + AppleScript keystroke |
| Ghostty | `com.mitchellh.ghostty` | AppleScript: new tab + write text |

### Auto-Discovery

`TerminalLauncher` checks which terminals are installed using:
```swift
NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
```

Only installed terminals appear in settings. If no known terminal is found, a generic fallback uses `open -a` + `osascript`.

### Session-to-Terminal Mapping

To focus the correct terminal tab when clicking a session tab:
1. Get `claude` process PID
2. Look up parent PID (PPID) — this is the shell process in the terminal tab
3. Use PPID to identify the terminal window/tab via AppleScript
4. Activate and bring that tab to front

### Extensibility

Adding a new terminal requires only adding one Swift file implementing `TerminalAdapter`. No changes to existing code. `TerminalLauncher` auto-registers all conforming types.

---

## Notifications

### Trigger
Session state changes from BUSY → IDLE.

### Implementation
`UNUserNotificationCenter` with:
- **Title:** "Clyde"
- **Body:** "{session name} is ready"
- **Action on click:** Focus the terminal with that session

### Permissions
Request notification permission on first launch via `UNUserNotificationCenter.requestAuthorization`.

---

## Settings

Accessible via gear icon in expanded view title bar. Stored in `UserDefaults` / `@AppStorage`.

| Setting | Type | Default | Description |
|---------|------|---------|-------------|
| Default terminal | Dropdown | Auto-detected first installed | Which terminal to use for new sessions |
| Polling interval | Slider (1-10s) | 3s | How often to check process status |
| Notifications | Toggle | On | macOS notifications on BUSY→IDLE |
| Launch at login | Toggle | Off | Auto-start via `SMAppService` (macOS 13+) |

---

## MVP Scope

### Included
1. NSPanel floating widget — collapsed with Clyde + expanded with session tabs
2. Animated pixel art Clyde with 3 states (busy/idle/sleeping)
3. ProcessMonitor — pgrep + ps polling at configurable interval
4. Session tab bar — auto-detect CWD, custom naming, click to focus terminal
5. TerminalAdapter protocol with 4 adapters (iTerm2, Terminal.app, Warp, Ghostty) + auto-discovery
6. macOS notifications on BUSY → IDLE transitions
7. Settings — default terminal, polling interval, notifications, launch at login

### Excluded (v2+)
- Session history / logs
- Keyboard shortcuts
- Automatic session restart
- Custom terminal configuration (user-provided bundle ID)
- Menu bar icon (NSStatusItem) as alternative to floating widget

---

## File Structure

```
Clyde/
├── App/
│   ├── ClydeApp.swift              # @main, NSPanel setup
│   └── AppDelegate.swift           # Window lifecycle, floating panel config
├── Views/
│   ├── WidgetView.swift            # Collapsed widget
│   ├── ExpandedView.swift          # Full window with tabs
│   ├── ClydeAnimationView.swift    # Pixel art Canvas + animations
│   ├── SessionTabBar.swift         # Horizontal tab bar
│   ├── SessionDetailView.swift     # Per-session info panel
│   └── SettingsView.swift          # Settings panel
├── ViewModels/
│   ├── AppViewModel.swift          # Window state, global Clyde state
│   └── SessionListViewModel.swift  # Session management, tab selection
├── Services/
│   ├── ProcessMonitor.swift        # pgrep/ps polling
│   ├── TerminalLauncher.swift      # Adapter registry, dispatch
│   └── NotificationService.swift   # UNUserNotificationCenter wrapper
├── TerminalAdapters/
│   ├── TerminalAdapter.swift       # Protocol definition
│   ├── ITermAdapter.swift          # iTerm2
│   ├── TerminalAppAdapter.swift    # Terminal.app
│   ├── WarpAdapter.swift           # Warp
│   └── GhosttyAdapter.swift        # Ghostty
└── Models/
    ├── Session.swift               # Session data model (PID, status, CWD, name)
    └── ClydeState.swift            # Enum: busy, idle, sleeping
```
