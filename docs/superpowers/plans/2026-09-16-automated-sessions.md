# Automated Sessions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Sessions that a program started (Agent SDK, scripted `claude -p`, a test suite) stop making sounds, stop filling the panel and the widget, and are counted in the summary bar instead — with a setting to show them anyway.

**Architecture:** The hook decides "headless" from whether the `claude` process's stdin is a terminal and from the `CLAUDE_CODE_ENTRYPOINT` it inherits, and writes `"headless": true` into `-info`. `ProcessMonitor` keeps tracking every session but publishes only the non-headless ones as `sessions`, plus an `automatedSessionCount`; a closure decides whether hidden sessions are shown. Every consumer reads `sessions` and is unchanged. The summary bar shows the count; a Settings toggle flips the closure.

**Tech Stack:** Swift 5.9, SwiftUI, XCTest, bash. macOS 13+.

**Spec:** `docs/superpowers/specs/2026-09-16-automated-sessions-design.md`

## Global Constraints

- Prose markdown is not hard-wrapped. No Claude attribution in commits. Conventional commits; stage specific paths.
- `swift test` passes before every Swift commit (664 tests at the branch base). Hook changes need the subprocess tests in `HookScriptTests` plus a manual pipe smoke test.
- Hook: bump `# clyde-hook-version:` to 46 and `HookInstaller.currentScriptVersion` to 46 in the same commit. Never `set -e`, always `exit 0`. The `-info` file stays byte-identical for ordinary sessions. Log fields are appended at the end of the line.
- Headless rule, verbatim: headless iff `CLAUDE_CODE_ENTRYPOINT` starts with `sdk`, OR the `claude` process's standard input (fd 0) is not a terminal device (`lsof -a -p <pid> -d 0 -Fn` → a name not starting with `/dev/tty`). Cleat sessions use only the entrypoint clause. The lookup runs only where `-info` is written.
- Tests never touch the real `~/.claude`/`~/.clyde` (`AppPaths.homeOverride`, temp `stateDir`, `HOME=<tmp>`).
- UI copy: summary bar trailing text `N sessions · M automated`; setting title "Show automated sessions".

---

### Task 1: The hook records `headless`

**Files:**
- Modify: `Clyde/Resources/clyde-hook.sh` (version stamp; a `HEADLESS` decision after `CLAUDE_PID` is resolved; `INFO_RUNTIME_FIELDS` gains the field; `log_event` appends `headless=true`)
- Modify: `Clyde/Services/HookInstaller.swift` (`currentScriptVersion = 46`)
- Test: `ClydeTests/HookScriptTests.swift`

**Interfaces:**
- Produces: `-info` JSON with `"headless": true` for headless sessions (absent otherwise); log line suffix ` headless=true`. Test seam: env `CLYDE_HOOK_STDIN` overrides the `lsof` lookup when set (values: a device name such as `/dev/ttys004`, or `pipe`).

- [ ] **Step 1: Write the failing tests**

Add to `ClydeTests/HookScriptTests.swift`. The file's `startHook(payload:home:)` sets `env["HOME"]`; add an optional `extraEnv: [String: String] = [:]` parameter to `startHook` and `runHook` that is merged into `env` before `task.environment = env` (existing callers unchanged). Then:

```swift
    // MARK: - Headless sessions

    private func infoJSON(sid: String, home: URL) throws -> [String: Any] {
        let url = home.appendingPathComponent(".clyde/state/\(sid)-info")
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func sessionStart(sid: String) -> String {
        #"{"session_id": "\#(sid)", "hook_event_name": "SessionStart", "cwd": "/tmp/x", "source": "startup"}"#
    }

    func testSDKEntrypointMarksTheSessionHeadless() throws {
        let home = tempHome(), sid = UUID().uuidString
        try runHook(payload: sessionStart(sid: sid), home: home,
                    extraEnv: ["CLAUDE_CODE_ENTRYPOINT": "sdk-py", "CLYDE_HOOK_STDIN": "/dev/ttys004"])
        XCTAssertEqual(try infoJSON(sid: sid, home: home)["headless"] as? Bool, true)
    }

    func testPipedStdinIsHeadless() throws {
        let home = tempHome(), sid = UUID().uuidString
        try runHook(payload: sessionStart(sid: sid), home: home,
                    extraEnv: ["CLAUDE_CODE_ENTRYPOINT": "cli", "CLYDE_HOOK_STDIN": "pipe"])
        XCTAssertEqual(try infoJSON(sid: sid, home: home)["headless"] as? Bool, true)
    }

    func testTerminalSessionIsNotHeadlessAndInfoIsUnchanged() throws {
        let home = tempHome(), sid = UUID().uuidString
        try runHook(payload: sessionStart(sid: sid), home: home,
                    extraEnv: ["CLAUDE_CODE_ENTRYPOINT": "cli", "CLYDE_HOOK_STDIN": "/dev/ttys004"])
        let json = try infoJSON(sid: sid, home: home)
        XCTAssertNil(json["headless"])
        XCTAssertEqual(Set(json.keys), ["session_id", "pid", "cwd", "started_at", "source"])
    }

    func testHeadlessIsLoggedAtTheEndOfTheLine() throws {
        let home = tempHome(), sid = UUID().uuidString
        try runHook(payload: sessionStart(sid: sid), home: home,
                    extraEnv: ["CLAUDE_CODE_ENTRYPOINT": "sdk-ts"])
        let log = try String(contentsOf: home.appendingPathComponent(".clyde/logs/hook.log"), encoding: .utf8)
        let line = try XCTUnwrap(log.split(separator: "\n").first { $0.contains(sid) })
        XCTAssertTrue(line.hasSuffix("source=startup headless=true"), String(line))
    }
```

If the process environment running the tests already carries `CLAUDE_CODE_ENTRYPOINT` (it does when `swift test` runs under Claude Code), the tests that omit it must clear it: in `startHook`, after merging `extraEnv`, remove `CLAUDE_CODE_ENTRYPOINT` from `env` when `extraEnv` does not set it.

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter HookScriptTests 2>&1 | tail -8` — the new tests fail on the missing `headless` key.

- [ ] **Step 3: Implement in the hook**

Bump line 2 to `# clyde-hook-version: 46`. In the handled-events header comment add `#   (SessionStart) -info also carries "headless": true when the session has no terminal (see HEADLESS below)`.

Right after the `CLAUDE_PID` resolution block ends (after the `if [ -z "$CLAUDE_PID" ] … exit 0; fi` guard), add:

```bash
# Whether a person is looking at this session. The interactive TUI
# needs a terminal on its stdin and has one; a session a program
# started — the Agent SDK, `claude -p` from a script, a test suite —
# reads from a pipe or /dev/null, and the SDK also exports
# CLAUDE_CODE_ENTRYPOINT=sdk-*. The process's *controlling* terminal
# was tried first and rejected: a server started from a terminal hands
# it down to every claude it spawns.
#
# lsof costs a few tens of milliseconds, so this runs only where -info
# is written. CLYDE_HOOK_STDIN is a test seam — a test runner may or
# may not own a terminal, so the tests say which case they mean.
detect_headless() {
    HEADLESS=""
    case "${CLAUDE_CODE_ENTRYPOINT:-}" in
        sdk*) HEADLESS=true; return 0 ;;
    esac
    [ -n "$CLEAT_RUNTIME" ] && return 0
    local stdin_name
    if [ -n "${CLYDE_HOOK_STDIN:-}" ]; then
        stdin_name=$CLYDE_HOOK_STDIN
    else
        stdin_name=$(lsof -a -p "$CLAUDE_PID" -d 0 -Fn 2>/dev/null | sed -n 's/^n//p' | head -n1)
    fi
    case "$stdin_name" in
        /dev/tty*) ;;
        *) HEADLESS=true ;;
    esac
    return 0
}
HEADLESS=""
```

Call `detect_headless` at the top of the `SessionStart` branch and of the `UserPromptSubmit` branch (where `-info` is backfilled), before the `-info` write. `log_event` runs before those branches; have `log_event` print `headless=true` when `$HEADLESS` is set, which means the field appears on the log line only for events after detection — so instead call `detect_headless` *before* `log_event` when `HOOK_EVENT` is `SessionStart` (`[ "$HOOK_EVENT" = SessionStart ] && detect_headless`), and again lazily in the `UserPromptSubmit` branch. The always-on log then carries `headless=true` on `SessionStart` lines only, like `source`. In `log_event`, after the `SOURCE` line: `[ -n "$HEADLESS" ] && extra="$extra headless=true"`. Where `INFO_RUNTIME_FIELDS` is assembled, append after the cleat block:

```bash
if [ -n "$HEADLESS" ]; then
    INFO_RUNTIME_FIELDS="$INFO_RUNTIME_FIELDS, \"headless\": true"
fi
```

In `Clyde/Services/HookInstaller.swift` set `static let currentScriptVersion = 46`.

- [ ] **Step 4: Run tests, then the manual smoke test**

Run: `swift test --filter HookScriptTests 2>&1 | tail -5` then the full suite.

Smoke, from a terminal — expect no `headless` key (stdin of the fake claude is the terminal):
```bash
mkdir -p /tmp/clyde-h && echo '{"session_id":"smoke-1","hook_event_name":"SessionStart","cwd":"/tmp","source":"startup"}' | HOME=/tmp/clyde-h bash Clyde/Resources/clyde-hook.sh; cat /tmp/clyde-h/.clyde/state/smoke-1-info; tail -1 /tmp/clyde-h/.clyde/logs/hook.log
```
(The hook needs a `claude` ancestor to write anything; if run outside a Claude session, expect the `WARN no claude ancestor` line and put the assertion on the tests instead.)

- [ ] **Step 5: Commit**

```bash
git add Clyde/Resources/clyde-hook.sh Clyde/Services/HookInstaller.swift ClydeTests/HookScriptTests.swift
git commit -m "feat(hooks): mark sessions nobody is watching

A program that starts Claude Code feeds it a pipe instead of a terminal, and the Agent SDK says so in CLAUDE_CODE_ENTRYPOINT. The hook records that in -info so the app can stop treating a test suite's forty sessions like the one in the user's terminal. Looked up once per session, where -info is written."
```

---

### Task 2: `ProcessMonitor` publishes only what a person should see

**Files:**
- Modify: `Clyde/Models/Session.swift` (`var isHeadless: Bool = false` next to `runtime`)
- Modify: `Clyde/Services/ProcessMonitor.swift`
- Test: `ClydeTests/ProcessMonitorTests.swift`

**Interfaces:**
- Consumes: `-info` `headless` field.
- Produces: `ProcessMonitor.init(…, showsAutomatedSessions: @escaping () -> Bool = { UserDefaults.standard.bool(forKey: ProcessMonitor.showAutomatedSessionsKey) })`; `static let showAutomatedSessionsKey = "showAutomatedSessions"`; `@Published private(set) var sessions: [Session]` (published, filtered); `@Published private(set) var automatedSessionCount: Int`; `private(set) var trackedSessions: [Session]` (everything, internal); `func republish()` (re-derives after the setting flips); `HookInfo.headless: Bool`.

- [ ] **Step 1: Write the failing tests**

In `ClydeTests/ProcessMonitorTests.swift`, next to `writeCleatInfoFile`, add a helper that writes an `-info` with `"headless": true` for `getpid()` (look at how the cleat helper builds the file and mirror it, adding the key), then:

```swift
    // MARK: - Automated sessions

    func testHeadlessSessionIsTrackedButNotPublished() async {
        let dir = tempStateDir()
        let sid = UUID().uuidString
        _ = writeHeadlessInfoFile(in: dir, sessionId: sid)
        let monitor = ProcessMonitor(shell: emptyShell(), pollingInterval: 1, stateDir: dir,
                                     isLiveClaudeProcessCheck: { _ in true },
                                     showsAutomatedSessions: { false })
        await monitor.poll()
        XCTAssertEqual(monitor.sessions.count, 0)
        XCTAssertEqual(monitor.automatedSessionCount, 1)
        XCTAssertEqual(monitor.trackedSessions.first?.isHeadless, true)
        XCTAssertEqual(monitor.clydeState, .sleeping)
    }

    func testHeadlessSessionIsPublishedWhenTheSettingSaysSo() async {
        let dir = tempStateDir()
        _ = writeHeadlessInfoFile(in: dir, sessionId: UUID().uuidString)
        var show = false
        let monitor = ProcessMonitor(shell: emptyShell(), pollingInterval: 1, stateDir: dir,
                                     isLiveClaudeProcessCheck: { _ in true },
                                     showsAutomatedSessions: { show })
        await monitor.poll()
        XCTAssertEqual(monitor.sessions.count, 0)
        show = true
        monitor.republish()
        XCTAssertEqual(monitor.sessions.count, 1)
        XCTAssertEqual(monitor.automatedSessionCount, 0)
    }

    func testHeadlessSessionDoesNotAnnounceIdle() async {
        let dir = tempStateDir()
        let sid = UUID().uuidString
        let pid = writeHeadlessInfoFile(in: dir, sessionId: sid)
        // busy first, then idle — the transition that plays the sound
        try? "{\"session_id\": \"\(sid)\", \"pid\": \(pid), \"timestamp\": \(Int(Date().timeIntervalSince1970))}"
            .write(to: dir.appendingPathComponent("\(sid)-busy"), atomically: true, encoding: .utf8)
        let monitor = ProcessMonitor(shell: emptyShell(), pollingInterval: 1, stateDir: dir,
                                     isLiveClaudeProcessCheck: { _ in true },
                                     showsAutomatedSessions: { false })
        var announced = 0
        monitor.onSessionBecameIdle = { _ in announced += 1 }
        await monitor.poll()
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(sid)-busy"))
        await monitor.poll()
        XCTAssertEqual(monitor.trackedSessions.first?.status, .idle)
        XCTAssertEqual(announced, 0)
    }
```

Check the existing busy-marker format in this test file (there is a helper writing `-busy`; use it if present).

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter ProcessMonitorTests 2>&1 | tail -5` — compile errors on the new API.

- [ ] **Step 3: Implement**

`Session.swift`: add `/// True for a session no person is watching — see the hook's HEADLESS rule. Hidden from the published list unless the user asks.` `var isHeadless: Bool = false`.

`ProcessMonitor.swift`:
- `HookInfo` and `ParsedInfo` gain `let headless: Bool`; `readInfoFile` reads `(json["headless"] as? Bool) ?? false`; every place that constructs `HookInfo` from `ParsedInfo` passes it through.
- Rename the stored array: `@Published var sessions` becomes `private(set) var trackedSessions: [Session] = [] { didSet { republish() } }` — every internal read/write of `sessions` (25 sites, all inside the class) now uses `trackedSessions`. Add:

```swift
    /// What a person should see. `trackedSessions` minus the headless
    /// ones, unless the setting says to show them. Every consumer reads
    /// this; none of them has to know the distinction exists.
    @Published private(set) var sessions: [Session] = []
    /// Live headless sessions hidden from `sessions`. Zero while the
    /// setting shows them, since then they are in the list.
    @Published private(set) var automatedSessionCount: Int = 0

    static let showAutomatedSessionsKey = "showAutomatedSessions"
    private let showsAutomatedSessions: () -> Bool

    /// Re-derive the published list from what is tracked. Called from
    /// `trackedSessions`'s observer and after the setting flips.
    func republish() {
        let show = showsAutomatedSessions()
        let visible = show ? trackedSessions : trackedSessions.filter { !$0.isHeadless }
        if visible != sessions { sessions = visible }
        let hidden = show ? 0 : trackedSessions.filter { $0.isHeadless && !$0.isGhost }.count
        if hidden != automatedSessionCount { automatedSessionCount = hidden }
        let live = visible.filter { !$0.isGhost }
        let state: ClydeState = live.isEmpty ? .sleeping
            : (live.contains(where: { $0.status == .busy }) ? .busy : .idle)
        if state != clydeState { clydeState = state }
    }
```
   and delete the two inline `clydeState` computations (they now live in `republish()`).
- `init` gains `showsAutomatedSessions: @escaping () -> Bool = { UserDefaults.standard.bool(forKey: ProcessMonitor.showAutomatedSessionsKey) }` as the last parameter.
- `isHeadless` is set wherever `runtime` is copied from `info` (the three branches of the update function: existing, revived, fresh).
- Both `onSessionBecameIdle?(…)` calls become conditional: `if !(session.isHeadless && !showsAutomatedSessions()) { onSessionBecameIdle?(session) }` — write a small private `func announcesIdle(_ s: Session) -> Bool` and use it at both sites.

`AppViewModelTests`/others that set `monitor.sessions = […]` directly (Task 5 of the limits plan did) must switch to a test-only path: add `func setTrackedSessionsForTesting(_ s: [Session])` … no — keep it simpler: make `trackedSessions` `internal private(set)` and give tests `func replaceTrackedSessions(_ sessions: [Session])` marked `/// Tests only.`; update the two call sites in `AppViewModelTests`.

- [ ] **Step 4: Run the full suite, commit**

Run: `swift test 2>&1 | tail -3`.

```bash
git add Clyde/Models/Session.swift Clyde/Services/ProcessMonitor.swift ClydeTests/ProcessMonitorTests.swift ClydeTests/AppViewModelTests.swift
git commit -m "feat(sessions): track every session, publish the ones a person is watching

Headless sessions stay tracked — liveness, ghosts, resume — but leave the published list, and a count of them is published beside it. Everything downstream reads the list and needed no change to stop showing, counting and announcing them. A closure decides whether they are shown, so the setting flips without a restart."
```

---

### Task 3: The setting and the summary bar

**Files:**
- Modify: `Clyde/ViewModels/AppViewModel.swift` (`@Published var showAutomatedSessions` persisting to `ProcessMonitor.showAutomatedSessionsKey`, `didSet` calls `processMonitor.republish()`)
- Modify: `Clyde/Views/SettingsView.swift` (toggle in the "Monitoring" section, before the poll interval row)
- Modify: `Clyde/Views/Components/SummaryBar.swift` (`var automatedCount: Int = 0`; trailing text)
- Modify: `Clyde/Views/ExpandedView.swift` (pass `automatedCount: appViewModel.processMonitor.automatedSessionCount`)
- Test: `ClydeTests/AppViewModelTests.swift`

- [ ] **Step 1: Failing test**

```swift
    func testShowAutomatedSessionsPersistsAndRepublishes() {
        let key = ProcessMonitor.showAutomatedSessionsKey
        UserDefaults.standard.removeObject(forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let vm = AppViewModel(processMonitor: ProcessMonitor())
        XCTAssertFalse(vm.showAutomatedSessions)
        vm.showAutomatedSessions = true
        XCTAssertTrue(UserDefaults.standard.bool(forKey: key))
    }
```

- [ ] **Step 2: Implement**

`AppViewModel`:
```swift
    /// Off by default: sessions started by programs stay out of the
    /// panel, the counts and the sounds. On, they are ordinary sessions.
    @Published var showAutomatedSessions: Bool = UserDefaults.standard
        .bool(forKey: ProcessMonitor.showAutomatedSessionsKey) {
        didSet {
            guard showAutomatedSessions != oldValue else { return }
            UserDefaults.standard.set(showAutomatedSessions, forKey: ProcessMonitor.showAutomatedSessionsKey)
            processMonitor.republish()
        }
    }
```

`SettingsView.swift`, inside `SettingsSection(title: "Monitoring")`, as the first child of its `VStack`:
```swift
                Toggle(isOn: $appViewModel.showAutomatedSessions) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show automated sessions")
                            .font(.system(size: 12))
                            .foregroundStyle(.white)
                        Text("Sessions started by programs rather than from a terminal — the Agent SDK, `claude -p` in a script, a test suite. Off keeps them out of the panel, the counts and the sounds.")
                            .font(.system(size: 10))
                            .foregroundStyle(Color(white: 0.45))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)
```

`SummaryBar`: add `var automatedCount: Int = 0` after `idleCount`; replace the trailing `Text("\(sessionCount) \(sessionCount == 1 ? "session" : "sessions")")` block with one that appends ` · \(automatedCount) automated` when `automatedCount > 0`, and show it even when `sessionCount == 0` if `automatedCount > 0` (then the text is just `\(automatedCount) automated`, next to the existing "Waiting for sessions..." line). Extend `summaryAccessibilityLabel` accordingly. `ExpandedView` passes `automatedCount:`.

- [ ] **Step 3: Full suite, commit**

```bash
git add Clyde/ViewModels/AppViewModel.swift Clyde/Views/SettingsView.swift Clyde/Views/Components/SummaryBar.swift Clyde/Views/ExpandedView.swift ClydeTests/AppViewModelTests.swift
git commit -m "feat(ui): say how many sessions are hidden, and a switch to show them

The summary bar counts automated sessions beside the ones on screen, so a quiet panel during a test run is not mistaken for a broken hook. The switch in Monitoring makes them ordinary sessions again, sounds included."
```

---

### Task 4: Docs, scenario, changelog, roadmap

**Files:**
- Modify: `scripts/dev/scenarios.sh` (new `automated-sessions` scenario in the list and the `case`)
- Modify: `CHANGELOG.md`, `ROADMAP.md`, `docs/hook-smoke-test.md`

- [ ] **Step 1: Scenario**

Add to the `list` block: `note "automated-sessions the panel must stay quiet while a script runs claude -p in parallel"`. Add a case:

```bash
automated-sessions)
    say "Three headless sessions in parallel, then one from the terminal"
    note "Watch the widget: it must not change, and no sound must play."
    for i in 1 2 3; do
        claude -p "reply with the single word ok" < /dev/null > /dev/null 2>&1 &
    done
    sleep 20
    note "Expected: full panel summary bar says '· 3 automated' while they run; no rows; no sound."
    note "Now run in this terminal:  claude -p 'reply with the single word ok'"
    note "Expected: an ordinary row appears and the ready sound plays once."
    note "Settings › General › Monitoring › Show automated sessions turns the hidden ones into rows."
    ;;
```

- [ ] **Step 2: Changelog** — under `## [Unreleased]` `### Fixed` (add the heading if absent), one line:

`- Sessions started by programs — the Agent SDK, `claude -p` from a script, a test suite — no longer fill the panel, the widget and the ready sound. They are tracked but hidden; the full panel's summary bar counts them ("3 sessions · 6 automated"), and Settings › General › Monitoring › Show automated sessions brings them back as ordinary sessions. Interactive sessions, including `claude -p` typed into a terminal, are unaffected.`

- [ ] **Step 3: Roadmap** — in the v0.10.0 phase add `- [x] Sessions started by programs are tracked but hidden: the hook marks a session whose stdin is not a terminal (or whose entrypoint is sdk-*) headless, the monitor publishes only the rest plus a count, the summary bar shows the count, a Monitoring switch shows them. From a field report of 45 ready sounds in three minutes. Spec: `docs/superpowers/specs/2026-09-16-automated-sessions-design.md` !hi #hooks #ux` and a follow-up `- [ ] The review window counts automated sessions as work; decide whether history should carry the headless flag too !lo #qa`.

- [ ] **Step 4: Smoke test** — append scenario 10 to `docs/hook-smoke-test.md` mirroring the scenario above (setup, steps, expect), one line per item.

- [ ] **Step 5: Commit**

```bash
git add scripts/dev/scenarios.sh CHANGELOG.md ROADMAP.md docs/hook-smoke-test.md
git commit -m "docs(sessions): scenario for the parallel headless run, changelog, roadmap"
```

---

## Self-review

Spec coverage: signal → Task 1; hide/count/announce → Task 2; summary bar and setting → Task 3; verification and docs → Task 4. History untouched by design. Attention-from-headless: covered by `AttentionMonitor.onAttentionNeeded` looking up `processMonitor.sessions` (published) — add one assertion to Task 2's first test if cheap: `XCTAssertNil(monitor.sessions.first { $0.pid == pid })` is already implied. Type consistency: `showsAutomatedSessions` (closure, init label), `showAutomatedSessionsKey`, `republish()`, `trackedSessions`, `automatedSessionCount`, `isHeadless`, `automatedCount:` (SummaryBar) used consistently across tasks.
