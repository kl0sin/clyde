# Usage Limits Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show the two Claude subscription windows (5-hour session, 7-day week) in Clyde's full panel and compact footer, fed by a status-line wrapper Clyde installs into Claude Code's `settings.json`.

**Architecture:** A bash wrapper registered as Claude Code's `statusLine` writes every payload it receives to `~/.clyde/usage/statusline.json` and passes stdin through to whatever status line the user already had. A `UsageLimitsStore` watches that directory and publishes a parsed `UsageLimits` value; `AppViewModel` exposes it to a `LimitsBand` in the full panel and a single `UsageMeter` in compact's footer. An installer beside `HookInstaller` owns the settings.json edit, the passthrough file, and the health check. The feature is opt-in through a Settings toggle; a dismissable advisory chip offers it once.

**Tech Stack:** Swift 5.9, SwiftUI, XCTest, bash. macOS 13+. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-09-10-usage-limits-design.md`

## Global Constraints

- Prose markdown (CHANGELOG, ROADMAP, docs) is not hard-wrapped: one paragraph or list item per line.
- No Claude attribution anywhere: no "Generated with Claude", no `Co-Authored-By: Claude`. Commits look human-written.
- Conventional commits: `feat(scope): …`, `test(scope): …`, `docs(scope): …`. Body explains why. Stage specific paths; never `git add -A`.
- `swift test` from the repo root must pass before every commit that touches Swift.
- The wrapper script is advisory: no `set -e`, always `exit 0`. A non-zero exit or empty output blanks the user's status line.
- UI copy: the windows are called **Session** (5 h) and **Week** (7 d); meters are labelled `5h` and `7d`. Percent is usage, never remaining.
- Colours come from `SessionTheme`: `attentionColor` from 80 %, `errorColor` at 100 % or on a live `rate_limit` stop. No new colours.
- Only Pro/Max produce `rate_limits`. Absence of data means absence of UI, never an empty bar.
- Tests never touch the real `~/.claude` or `~/.clyde`: use `AppPaths.homeOverride` (Swift) or `HOME=<tmp>` (bash).

---

## File structure

**Create**

- `Clyde/Models/UsageLimits.swift` — value types, parsing, level/staleness rules, reset and freshness text. Pure; no I/O.
- `Clyde/Resources/clyde-statusline.sh` — the status-line wrapper.
- `Clyde/Services/UsageLimitsInstaller.swift` — install/uninstall/health check for the wrapper and the `statusLine` slot; passthrough storage.
- `Clyde/Services/UsageLimitsStore.swift` — watches `~/.clyde/usage/`, publishes `UsageLimits?`.
- `Clyde/Models/UsageLimitsAlerts.swift` — decides which notifications fire between two snapshots. Pure.
- `Clyde/Models/UsageLimitsStatus.swift` — the three-state Settings status (mirror of `PermissionAnsweringStatus`).
- `Clyde/Views/Components/UsageMeter.swift` — label · bar · percentage, in three widths.
- `Clyde/Views/Components/LimitsBand.swift` — the full panel's collapsible band.
- `ClydeTests/UsageLimitsTests.swift`, `ClydeTests/StatusLineScriptTests.swift`, `ClydeTests/UsageLimitsInstallerTests.swift`, `ClydeTests/UsageLimitsStoreTests.swift`, `ClydeTests/UsageLimitsAlertsTests.swift`, `ClydeTests/UsageLimitsStatusTests.swift`.

**Modify**

- `Package.swift` — copy the new resource.
- `Clyde/Services/AppPaths.swift` — `usageDir`, `usageSnapshotFile`, `usagePassthroughFile`, `clydeStatusLineScript`.
- `Clyde/Services/HookInstaller.swift` — new `HealthIssue.usageLimitsAvailable` advisory; `healthCheck()` returns it last.
- `Clyde/ViewModels/AppViewModel.swift` — setting, store lifecycle, published limits, rate-limited flag, offer dismissal, notifications.
- `Clyde/Views/ExpandedView.swift` — the band above Activity.
- `Clyde/Views/CompactRootView.swift` — the session meter in the footer.
- `Clyde/Views/Components/AdvisoryViews.swift` — "Open Settings" button for the offer.
- `Clyde/Views/SettingsView.swift` — the toggle and status line.
- `Clyde/Services/NotificationService.swift` — a generic send.
- `ClydeTests/HookInstallerTests.swift` — neutralise the offer in `setUp`.
- `docs/hook-smoke-test.md`, `CHANGELOG.md`, `ROADMAP.md`.

---

### Task 1: `UsageLimits` model — parsing and rules

**Files:**
- Create: `Clyde/Models/UsageLimits.swift`
- Test: `ClydeTests/UsageLimitsTests.swift`

**Interfaces:**
- Produces:
  - `struct UsageWindow: Equatable { let usedPercentage: Double; let resetsAt: Date }`
  - `struct UsageLimits: Equatable` with `fiveHour: UsageWindow?`, `sevenDay: UsageWindow?`, `updatedAt: Date`, `sessionID: String?`, `modelName: String?`
  - `enum UsageLimits.Level: Equatable { case normal, warning, exhausted }`
  - `static func UsageLimits.parse(_ data: Data, modifiedAt: Date) -> UsageLimits?`
  - `func droppingExpiredWindows(now: Date) -> UsageLimits`
  - `var hasAnyWindow: Bool`
  - `static func level(for window: UsageWindow, rateLimited: Bool) -> Level`
  - `func isStale(now: Date, hasLiveSession: Bool) -> Bool`
  - `static func resetText(for window: UsageWindow, now: Date, level: Level) -> String`
  - `static func percentText(for window: UsageWindow, level: Level) -> String`
  - `func freshnessText(now: Date, sessionName: String?, stale: Bool) -> String`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import Clyde

final class UsageLimitsTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000) // 2027-01-15 08:00:00 UTC

    private func payload(_ rateLimits: String?) -> Data {
        let limits = rateLimits.map { ",\"rate_limits\": \($0)" } ?? ""
        return """
        {"session_id": "abc-123", "model": {"id": "claude-opus-5", "display_name": "Opus"}\(limits)}
        """.data(using: .utf8)!
    }

    // MARK: - Parsing

    func testParsesBothWindows() {
        let data = payload("""
        {"five_hour": {"used_percentage": 42.5, "resets_at": 1800004320},
         "seven_day": {"used_percentage": 18, "resets_at": 1800400000}}
        """)
        let limits = UsageLimits.parse(data, modifiedAt: now)
        XCTAssertEqual(limits?.fiveHour?.usedPercentage, 42.5)
        XCTAssertEqual(limits?.fiveHour?.resetsAt, Date(timeIntervalSince1970: 1_800_004_320))
        XCTAssertEqual(limits?.sevenDay?.usedPercentage, 18)
        XCTAssertEqual(limits?.sessionID, "abc-123")
        XCTAssertEqual(limits?.modelName, "Opus")
        XCTAssertEqual(limits?.updatedAt, now)
    }

    func testOneWindowMayBeAbsent() {
        let data = payload("""
        {"seven_day": {"used_percentage": 18, "resets_at": 1800400000}}
        """)
        let limits = UsageLimits.parse(data, modifiedAt: now)
        XCTAssertNil(limits?.fiveHour)
        XCTAssertNotNil(limits?.sevenDay)
        XCTAssertEqual(limits?.hasAnyWindow, true)
    }

    func testNoRateLimitsMeansNoValue() {
        XCTAssertNil(UsageLimits.parse(payload(nil), modifiedAt: now))
    }

    func testGarbageMeansNoValue() {
        XCTAssertNil(UsageLimits.parse("not json".data(using: .utf8)!, modifiedAt: now))
    }

    func testWindowWithoutBothFieldsIsIgnored() {
        let data = payload("""
        {"five_hour": {"used_percentage": 42.5}, "seven_day": {"resets_at": 1800400000}}
        """)
        XCTAssertNil(UsageLimits.parse(data, modifiedAt: now))
    }

    // MARK: - Expiry

    func testExpiredWindowIsDropped() {
        let limits = UsageLimits(
            fiveHour: UsageWindow(usedPercentage: 84, resetsAt: now.addingTimeInterval(-60)),
            sevenDay: UsageWindow(usedPercentage: 30, resetsAt: now.addingTimeInterval(3600)),
            updatedAt: now.addingTimeInterval(-3600), sessionID: nil, modelName: nil)
        let live = limits.droppingExpiredWindows(now: now)
        XCTAssertNil(live.fiveHour)
        XCTAssertNotNil(live.sevenDay)
    }

    // MARK: - Level

    func testLevelThresholds() {
        let w = { (p: Double) in UsageWindow(usedPercentage: p, resetsAt: self.now) }
        XCTAssertEqual(UsageLimits.level(for: w(79.9), rateLimited: false), .normal)
        XCTAssertEqual(UsageLimits.level(for: w(80), rateLimited: false), .warning)
        XCTAssertEqual(UsageLimits.level(for: w(100), rateLimited: false), .exhausted)
        XCTAssertEqual(UsageLimits.level(for: w(42), rateLimited: true), .exhausted)
    }

    // MARK: - Staleness

    func testStaleAfterThirtyMinutesWithoutALiveSession() {
        let limits = UsageLimits(fiveHour: nil, sevenDay: nil,
                                 updatedAt: now.addingTimeInterval(-31 * 60), sessionID: nil, modelName: nil)
        XCTAssertTrue(limits.isStale(now: now, hasLiveSession: false))
        XCTAssertFalse(limits.isStale(now: now, hasLiveSession: true))
        let fresh = UsageLimits(fiveHour: nil, sevenDay: nil,
                                updatedAt: now.addingTimeInterval(-29 * 60), sessionID: nil, modelName: nil)
        XCTAssertFalse(fresh.isStale(now: now, hasLiveSession: false))
    }

    // MARK: - Text

    func testResetTextCountsDownUnderADay() {
        let w = UsageWindow(usedPercentage: 42, resetsAt: now.addingTimeInterval(72 * 60))
        XCTAssertEqual(UsageLimits.resetText(for: w, now: now, level: .normal), "resets in 1h 12m")
        let soon = UsageWindow(usedPercentage: 100, resetsAt: now.addingTimeInterval(47 * 60))
        XCTAssertEqual(UsageLimits.resetText(for: soon, now: now, level: .exhausted), "resumes in 0h 47m")
    }

    func testResetTextNamesTheDayBeyondADay() {
        let w = UsageWindow(usedPercentage: 18, resetsAt: now.addingTimeInterval(25 * 3600))
        let text = UsageLimits.resetText(for: w, now: now, level: .normal)
        XCTAssertTrue(text.hasPrefix("resets "), text)
        XCTAssertFalse(text.contains(" in "), text)
    }

    func testPercentText() {
        let w = UsageWindow(usedPercentage: 42.6, resetsAt: now)
        XCTAssertEqual(UsageLimits.percentText(for: w, level: .normal), "43%")
        XCTAssertEqual(UsageLimits.percentText(for: w, level: .exhausted), "full")
    }

    func testFreshnessText() {
        let limits = UsageLimits(fiveHour: nil, sevenDay: nil,
                                 updatedAt: now.addingTimeInterval(-40), sessionID: "abc", modelName: "Opus")
        XCTAssertEqual(limits.freshnessText(now: now, sessionName: "clyde", stale: false),
                       "Updated 40s ago from the clyde session")
        let old = UsageLimits(fiveHour: nil, sevenDay: nil,
                              updatedAt: now.addingTimeInterval(-47 * 60), sessionID: nil, modelName: nil)
        XCTAssertEqual(old.freshnessText(now: now, sessionName: nil, stale: true),
                       "As of 47m ago · refreshes with the next Claude Code turn")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter UsageLimitsTests 2>&1 | tail -5`
Expected: compile error, `UsageLimits` not found.

- [ ] **Step 3: Write the model**

```swift
import Foundation

/// One of the two rolling windows Claude Code meters a subscription in.
struct UsageWindow: Equatable {
    /// 0–100, as Claude Code reports it. Usage, not headroom.
    let usedPercentage: Double
    let resetsAt: Date
}

/// The two windows, as last reported by a status-line payload.
///
/// Four numbers and a timestamp. The timestamp is part of the data: the
/// status line only re-runs after an API response, so with no session
/// open these values stand still and the UI has to be able to say so.
struct UsageLimits: Equatable {
    let fiveHour: UsageWindow?
    let sevenDay: UsageWindow?
    /// When the snapshot was written — the file's mtime, not a field.
    let updatedAt: Date
    let sessionID: String?
    let modelName: String?

    enum Level: Equatable {
        case normal
        case warning
        case exhausted
    }

    static let warningThreshold: Double = 80
    static let staleAfter: TimeInterval = 30 * 60

    var hasAnyWindow: Bool { fiveHour != nil || sevenDay != nil }

    // MARK: - Parsing

    /// Reads the `rate_limits` object out of a whole status-line payload.
    /// Nil when there is none, or when neither window carries both of
    /// its fields — a half window is not worth drawing.
    static func parse(_ data: Data, modifiedAt: Date) -> UsageLimits? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rateLimits = root["rate_limits"] as? [String: Any] else {
            return nil
        }
        let fiveHour = window(from: rateLimits["five_hour"])
        let sevenDay = window(from: rateLimits["seven_day"])
        guard fiveHour != nil || sevenDay != nil else { return nil }
        let model = root["model"] as? [String: Any]
        return UsageLimits(
            fiveHour: fiveHour,
            sevenDay: sevenDay,
            updatedAt: modifiedAt,
            sessionID: root["session_id"] as? String,
            modelName: model?["display_name"] as? String
        )
    }

    private static func window(from any: Any?) -> UsageWindow? {
        guard let dict = any as? [String: Any],
              let used = number(dict["used_percentage"]),
              let resets = number(dict["resets_at"]) else {
            return nil
        }
        return UsageWindow(usedPercentage: used, resetsAt: Date(timeIntervalSince1970: resets))
    }

    private static func number(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let n = any as? NSNumber { return n.doubleValue }
        return nil
    }

    // MARK: - Rules

    /// Claude Code drops a window from the payload once its reset has
    /// passed. Between payloads this does the same, so a bar never
    /// shows the fill of a window that has already ended.
    func droppingExpiredWindows(now: Date) -> UsageLimits {
        UsageLimits(
            fiveHour: fiveHour.flatMap { $0.resetsAt > now ? $0 : nil },
            sevenDay: sevenDay.flatMap { $0.resetsAt > now ? $0 : nil },
            updatedAt: updatedAt,
            sessionID: sessionID,
            modelName: modelName
        )
    }

    static func level(for window: UsageWindow, rateLimited: Bool) -> Level {
        if rateLimited || window.usedPercentage >= 100 { return .exhausted }
        if window.usedPercentage >= warningThreshold { return .warning }
        return .normal
    }

    /// With a live session the numbers are at most one turn old. Without
    /// one, half an hour is where "current" stops being honest.
    func isStale(now: Date, hasLiveSession: Bool) -> Bool {
        if hasLiveSession { return false }
        return now.timeIntervalSince(updatedAt) >= Self.staleAfter
    }

    // MARK: - Text

    /// "resets in 1h 12m" under a day, "resets Sat 09:00" beyond it,
    /// and "resumes in …" when the window is spent, because the reset
    /// is then the moment work can continue.
    static func resetText(for window: UsageWindow, now: Date, level: Level) -> String {
        let remaining = max(0, window.resetsAt.timeIntervalSince(now))
        let verb = level == .exhausted ? "resumes" : "resets"
        if remaining < 24 * 3600 {
            let minutes = Int(remaining / 60)
            return "\(verb) in \(minutes / 60)h \(minutes % 60)m"
        }
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("EEE HH:mm")
        return "\(verb) \(formatter.string(from: window.resetsAt))"
    }

    static func percentText(for window: UsageWindow, level: Level) -> String {
        level == .exhausted ? "full" : "\(Int(window.usedPercentage.rounded()))%"
    }

    /// The line under the rows: where the numbers came from and how old
    /// they are. Without a live session they stop moving, and this is
    /// what tells the reader that.
    func freshnessText(now: Date, sessionName: String?, stale: Bool) -> String {
        let age = Self.age(now.timeIntervalSince(updatedAt))
        if stale {
            return "As of \(age) ago · refreshes with the next Claude Code turn"
        }
        if let sessionName {
            return "Updated \(age) ago from the \(sessionName) session"
        }
        return "Updated \(age) ago"
    }

    private static func age(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86_400 { return "\(s / 3600)h" }
        return "\(s / 86_400)d"
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter UsageLimitsTests 2>&1 | tail -5`
Expected: all tests in `UsageLimitsTests` pass.

- [ ] **Step 5: Commit**

```bash
git add Clyde/Models/UsageLimits.swift ClydeTests/UsageLimitsTests.swift
git commit -m "feat(limits): model the two subscription windows

Four numbers and a timestamp from the status-line payload, with the rules the UI needs: a window past its reset is dropped, 80% is a warning, 100% or a live rate_limit stop is exhausted, and half an hour without a session is stale. The timestamp is part of the value because the numbers only move when a session does."
```

---

### Task 2: The status-line wrapper script

**Files:**
- Create: `Clyde/Resources/clyde-statusline.sh`
- Modify: `Package.swift` (resources)
- Test: `ClydeTests/StatusLineScriptTests.swift`

**Interfaces:**
- Produces: a script that (1) writes stdin verbatim to `$HOME/.clyde/usage/statusline.json` atomically, (2) if `$HOME/.clyde/usage/passthrough` is non-empty, runs its contents with the same stdin and prints its output, (3) otherwise prints one line `<model> · 5h N% · 7d N%` (limits omitted when absent), (4) always exits 0. Version stamp line: `# clyde-statusline-version: 1`.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import Clyde

/// Drives the bundled `clyde-statusline.sh` as a real subprocess with a
/// sandboxed `$HOME`, the way `HookScriptTests` drives the hook. The
/// script is the producer half of the feature; `UsageLimitsStore` is
/// the consumer.
final class StatusLineScriptTests: XCTestCase {

    private static let scriptURL: URL = {
        URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Clyde/Resources/clyde-statusline.sh")
    }()

    private func tempHome() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clyde-statusline-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private let payload = """
    {"session_id": "abc-123", "model": {"id": "claude-opus-5", "display_name": "Opus"},
     "rate_limits": {"five_hour": {"used_percentage": 42.4, "resets_at": 1800004320},
                     "seven_day": {"used_percentage": 18, "resets_at": 1800400000}}}
    """

    /// Runs the script; returns (exit status, stdout).
    private func run(payload: String, home: URL) throws -> (Int32, String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = [Self.scriptURL.path]
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = home.path
        task.environment = env
        let stdin = Pipe(), stdout = Pipe()
        task.standardInput = stdin
        task.standardOutput = stdout
        task.standardError = Pipe()
        try task.run()
        stdin.fileHandleForWriting.write(payload.data(using: .utf8)!)
        try? stdin.fileHandleForWriting.close()
        task.waitUntilExit()
        let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (task.terminationStatus, out.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func testWritesTheWholePayloadAsASnapshot() throws {
        let home = tempHome()
        let (status, _) = try run(payload: payload, home: home)
        XCTAssertEqual(status, 0)
        let snapshot = home.appendingPathComponent(".clyde/usage/statusline.json")
        let data = try Data(contentsOf: snapshot)
        let limits = UsageLimits.parse(data, modifiedAt: Date())
        XCTAssertEqual(limits?.fiveHour?.usedPercentage, 42.4)
        XCTAssertEqual(limits?.sessionID, "abc-123")
    }

    func testPrintsItsOwnLineWhenThereIsNoPassthrough() throws {
        let (status, out) = try run(payload: payload, home: tempHome())
        XCTAssertEqual(status, 0)
        XCTAssertEqual(out, "Opus · 5h 42% · 7d 18%")
    }

    func testOwnLineOmitsAbsentLimits() throws {
        let noLimits = #"{"session_id": "abc", "model": {"display_name": "Opus"}}"#
        let (_, out) = try run(payload: noLimits, home: tempHome())
        XCTAssertEqual(out, "Opus")
    }

    func testPassesStdinThroughToTheUsersCommand() throws {
        let home = tempHome()
        let usageDir = home.appendingPathComponent(".clyde/usage")
        try FileManager.default.createDirectory(at: usageDir, withIntermediateDirectories: true)
        try "sed -e 's/.*display_name\": \"\\([A-Za-z]*\\)\".*/theirs:\\1/'"
            .write(to: usageDir.appendingPathComponent("passthrough"), atomically: true, encoding: .utf8)
        let (status, out) = try run(payload: payload.replacingOccurrences(of: "\n", with: ""), home: home)
        XCTAssertEqual(status, 0)
        XCTAssertEqual(out, "theirs:Opus")
    }

    func testAFailingPassthroughStillExitsZero() throws {
        let home = tempHome()
        let usageDir = home.appendingPathComponent(".clyde/usage")
        try FileManager.default.createDirectory(at: usageDir, withIntermediateDirectories: true)
        try "exit 3".write(to: usageDir.appendingPathComponent("passthrough"), atomically: true, encoding: .utf8)
        let (status, _) = try run(payload: payload, home: home)
        XCTAssertEqual(status, 0)
    }

    func testGarbageInputStillExitsZero() throws {
        let (status, _) = try run(payload: "not json at all", home: tempHome())
        XCTAssertEqual(status, 0)
    }

    func testCarriesAVersionStamp() throws {
        let source = try String(contentsOf: Self.scriptURL, encoding: .utf8)
        XCTAssertTrue(source.contains("# clyde-statusline-version: \(UsageLimitsInstaller.currentScriptVersion)"))
    }
}
```

The last test references `UsageLimitsInstaller.currentScriptVersion`, which Task 3 defines. Until then, replace it with the literal `1` so this task compiles on its own; Task 3 switches it back.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter StatusLineScriptTests 2>&1 | tail -8`
Expected: FAIL — the script does not exist, `/bin/bash` exits 127 and the snapshot is missing.

- [ ] **Step 3: Write the script**

`Clyde/Resources/clyde-statusline.sh`:

```bash
#!/bin/bash
# clyde-statusline-version: 1
# Clyde status-line wrapper — copies what Claude Code tells the status
# line into ~/.clyde/usage/ so Clyde can show the subscription limits.
# Installed by Clyde. Safe to remove; Clyde's Settings restores your own
# status line command when the feature is turned off.
#
# Advisory, like the hook: never `set -e`, always exit 0. A status line
# that exits non-zero or prints nothing goes blank in the terminal.

USAGE_DIR="$HOME/.clyde/usage"
LOG_DIR="$HOME/.clyde/logs"
LOG="$LOG_DIR/statusline.log"
mkdir -p "$USAGE_DIR" "$LOG_DIR" 2>/dev/null || true

trap 'rc=$?; printf "[%s] clyde-statusline line %s exited %s\n" "$(date "+%Y-%m-%d %H:%M:%S")" "$LINENO" "$rc" >>"$LOG" 2>/dev/null; exit 0' ERR

INPUT=$(cat 2>/dev/null || echo "{}")

# The whole payload, atomically. Parsing is Clyde's job: this runs
# after every API response and cannot depend on jq being installed.
tmp=$(mktemp "$USAGE_DIR/.snapshot.XXXXXX" 2>/dev/null) || tmp=""
if [ -n "$tmp" ]; then
    if printf '%s\n' "$INPUT" > "$tmp" 2>/dev/null; then
        mv -f "$tmp" "$USAGE_DIR/statusline.json" 2>/dev/null || rm -f "$tmp"
    else
        rm -f "$tmp"
    fi
fi

# The user's own status line, if they had one before Clyde. Same stdin,
# their output. Its failures are its own; ours is still exit 0.
if [ -s "$USAGE_DIR/passthrough" ]; then
    THEIRS=$(cat "$USAGE_DIR/passthrough" 2>/dev/null)
    printf '%s' "$INPUT" | /bin/bash -c "$THEIRS" 2>/dev/null || true
    exit 0
fi

# No status line before Clyde: one line, the model and the two windows.
LINE=""
if command -v python3 >/dev/null 2>&1; then
    LINE=$(printf '%s' "$INPUT" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
parts = []
model = (d.get("model") or {}).get("display_name")
if model:
    parts.append(str(model))
rl = d.get("rate_limits") or {}
for key, label in (("five_hour", "5h"), ("seven_day", "7d")):
    w = rl.get(key) or {}
    p = w.get("used_percentage")
    if isinstance(p, (int, float)):
        parts.append("%s %d%%" % (label, int(round(p))))
print(" · ".join(parts))
' 2>/dev/null) || LINE=""
fi
if [ -z "$LINE" ]; then
    # No python3: the model name is enough to keep the line from going blank.
    LINE=$(printf '%s' "$INPUT" | tr -d '\n' \
        | grep -o '"display_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -n1 \
        | sed -E 's/.*"([^"]*)"$/\1/')
fi
printf '%s\n' "$LINE"
exit 0
```

Make it executable in the repo: `chmod +x Clyde/Resources/clyde-statusline.sh`.

Add the resource to `Package.swift`, next to the hook:

```swift
            resources: [
                .copy("Resources/clyde-hook.sh"),
                .copy("Resources/clyde-statusline.sh"),
                .copy("Assets/AppIcon.icns"),
            ],
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter StatusLineScriptTests 2>&1 | tail -8`
Expected: all pass. If `testPassesStdinThroughToTheUsersCommand` fails on the `sed` expression, check that the payload reached the command on one line (the test strips newlines for exactly this reason).

- [ ] **Step 5: Manual smoke test**

```bash
mkdir -p /tmp/clyde-sl-home
echo '{"model":{"display_name":"Opus"},"rate_limits":{"five_hour":{"used_percentage":42,"resets_at":1800004320}}}' \
  | HOME=/tmp/clyde-sl-home bash Clyde/Resources/clyde-statusline.sh; echo "exit=$?"
cat /tmp/clyde-sl-home/.clyde/usage/statusline.json
```
Expected: prints `Opus · 5h 42%`, `exit=0`, and the JSON echoed back.

- [ ] **Step 6: Commit**

```bash
git add Clyde/Resources/clyde-statusline.sh Package.swift ClydeTests/StatusLineScriptTests.swift
git commit -m "feat(limits): status-line wrapper that snapshots the payload

Copies what Claude Code hands the status line into ~/.clyde/usage/ and hands the same stdin on to whatever status line the user had. Prints a single model-and-limits line only when there was none. Advisory like the hook: a non-zero exit blanks the terminal's status line, so every path ends in exit 0."
```

---

### Task 3: `UsageLimitsInstaller` — the `statusLine` slot and the passthrough

**Files:**
- Create: `Clyde/Services/UsageLimitsInstaller.swift`
- Modify: `Clyde/Services/AppPaths.swift`
- Test: `ClydeTests/UsageLimitsInstallerTests.swift`
- Modify: `ClydeTests/StatusLineScriptTests.swift` (switch the literal `1` back to `UsageLimitsInstaller.currentScriptVersion`)

**Interfaces:**
- Consumes: `AppPaths.homeOverride`, `HookInstaller.lastSelfWriteAt` (shared echo suppressor for the settings.json watcher).
- Produces:
  - `AppPaths.usageDir`, `AppPaths.usageSnapshotFile`, `AppPaths.usagePassthroughFile`, `AppPaths.clydeStatusLineScript`
  - `enum UsageLimitsInstaller` with `static let currentScriptVersion = 1`, `static let settingKey = "showUsageLimits"`, `static let offerDismissedKey = "usageLimitsOfferDismissed"`
  - `enum Issue: Equatable { case notInstalled, scriptMissing, scriptVersionUnreadable, outdated(installed: Int, current: Int), displaced(by: String) }` with `var message: String`
  - `enum InstallError: LocalizedError, Equatable { case parseFailed, writeFailed(String), bundledScriptMissing }`
  - `static func isClydeStatusLineCommand(_ cmd: String) -> Bool`
  - `static func install() throws`, `static func uninstall() throws`, `static func healthCheck() -> Issue?`
  - `static var isEnabled: Bool` (reads `settingKey`), `static var offerOverride: Bool?`, `static func shouldOffer() -> Bool`

- [ ] **Step 1: Add the paths**

In `Clyde/Services/AppPaths.swift`, after `logsDir`:

```swift
    /// Status-line snapshots and the user's own status line command,
    /// kept outside settings.json so a hand edit there cannot lose it.
    static var usageDir: URL {
        clydeDir.appendingPathComponent("usage")
    }

    static var usageSnapshotFile: URL {
        usageDir.appendingPathComponent("statusline.json")
    }

    static var usagePassthroughFile: URL {
        usageDir.appendingPathComponent("passthrough")
    }
```

and after `clydeHookScript`:

```swift
    static var clydeStatusLineScript: URL {
        claudeHooksDir.appendingPathComponent("clyde-statusline.sh")
    }
```

- [ ] **Step 2: Write the failing tests**

```swift
import XCTest
@testable import Clyde

final class UsageLimitsInstallerTests: XCTestCase {
    private var tempHome: URL!

    override func setUp() async throws {
        tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("clyde-limits-installer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
        AppPaths.homeOverride = tempHome
    }

    override func tearDown() async throws {
        AppPaths.homeOverride = nil
        UsageLimitsInstaller.offerOverride = nil
        if let tempHome { try? FileManager.default.removeItem(at: tempHome) }
        tempHome = nil
    }

    private func writeSettings(_ object: [String: Any]) throws {
        try FileManager.default.createDirectory(at: AppPaths.claudeDir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: object)
        try data.write(to: AppPaths.claudeSettingsFile)
    }

    private func readSettings() throws -> [String: Any] {
        let data = try Data(contentsOf: AppPaths.claudeSettingsFile)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testInstallWritesScriptAndRegistersIt() throws {
        try UsageLimitsInstaller.install()

        XCTAssertTrue(FileManager.default.fileExists(atPath: AppPaths.clydeStatusLineScript.path))
        let attrs = try FileManager.default.attributesOfItem(atPath: AppPaths.clydeStatusLineScript.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.int16Value, 0o755)

        let statusLine = try XCTUnwrap(try readSettings()["statusLine"] as? [String: Any])
        XCTAssertEqual(statusLine["type"] as? String, "command")
        XCTAssertEqual(statusLine["command"] as? String, AppPaths.clydeStatusLineScript.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: AppPaths.usagePassthroughFile.path))
        XCTAssertNil(UsageLimitsInstaller.healthCheck())
    }

    func testInstallKeepsTheUsersStatusLineAsPassthrough() throws {
        try writeSettings(["statusLine": ["type": "command", "command": "~/bin/my-status.sh", "padding": 2],
                           "model": "opus"])

        try UsageLimitsInstaller.install()

        let settings = try readSettings()
        let statusLine = try XCTUnwrap(settings["statusLine"] as? [String: Any])
        XCTAssertEqual(statusLine["command"] as? String, AppPaths.clydeStatusLineScript.path)
        XCTAssertEqual(statusLine["padding"] as? Int, 2)
        XCTAssertEqual(settings["model"] as? String, "opus")
        XCTAssertEqual(try String(contentsOf: AppPaths.usagePassthroughFile, encoding: .utf8), "~/bin/my-status.sh")
    }

    func testReinstallDoesNotAdoptItselfAsPassthrough() throws {
        try writeSettings(["statusLine": ["type": "command", "command": "~/bin/my-status.sh"]])
        try UsageLimitsInstaller.install()
        try UsageLimitsInstaller.install()
        XCTAssertEqual(try String(contentsOf: AppPaths.usagePassthroughFile, encoding: .utf8), "~/bin/my-status.sh")
    }

    func testUninstallRestoresTheUsersStatusLine() throws {
        try writeSettings(["statusLine": ["type": "command", "command": "~/bin/my-status.sh", "padding": 2]])
        try UsageLimitsInstaller.install()

        try UsageLimitsInstaller.uninstall()

        let statusLine = try XCTUnwrap(try readSettings()["statusLine"] as? [String: Any])
        XCTAssertEqual(statusLine["command"] as? String, "~/bin/my-status.sh")
        XCTAssertEqual(statusLine["padding"] as? Int, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: AppPaths.clydeStatusLineScript.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: AppPaths.usagePassthroughFile.path))
    }

    func testUninstallRemovesTheSlotWhenThereWasNothingBefore() throws {
        try UsageLimitsInstaller.install()
        try UsageLimitsInstaller.uninstall()
        XCTAssertNil(try readSettings()["statusLine"])
    }

    func testUninstallLeavesAStatusLineThatIsNotOurs() throws {
        try UsageLimitsInstaller.install()
        try writeSettings(["statusLine": ["type": "command", "command": "~/bin/newer.sh"]])
        try UsageLimitsInstaller.uninstall()
        let statusLine = try XCTUnwrap(try readSettings()["statusLine"] as? [String: Any])
        XCTAssertEqual(statusLine["command"] as? String, "~/bin/newer.sh")
    }

    func testInstallRefusesUnparseableSettings() throws {
        try FileManager.default.createDirectory(at: AppPaths.claudeDir, withIntermediateDirectories: true)
        try "{ not json".write(to: AppPaths.claudeSettingsFile, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try UsageLimitsInstaller.install()) { error in
            XCTAssertEqual(error as? UsageLimitsInstaller.InstallError, .parseFailed)
        }
        XCTAssertEqual(try String(contentsOf: AppPaths.claudeSettingsFile, encoding: .utf8), "{ not json")
    }

    func testHealthCheckStates() throws {
        XCTAssertEqual(UsageLimitsInstaller.healthCheck(), .notInstalled)

        try UsageLimitsInstaller.install()
        XCTAssertNil(UsageLimitsInstaller.healthCheck())

        try FileManager.default.removeItem(at: AppPaths.clydeStatusLineScript)
        XCTAssertEqual(UsageLimitsInstaller.healthCheck(), .scriptMissing)

        try UsageLimitsInstaller.install()
        try writeSettings(["statusLine": ["type": "command", "command": "~/bin/newer.sh"]])
        XCTAssertEqual(UsageLimitsInstaller.healthCheck(), .displaced(by: "~/bin/newer.sh"))
    }

    func testHealthCheckDetectsAnOlderScript() throws {
        try UsageLimitsInstaller.install()
        let old = try String(contentsOf: AppPaths.clydeStatusLineScript, encoding: .utf8)
            .replacingOccurrences(of: "# clyde-statusline-version: \(UsageLimitsInstaller.currentScriptVersion)",
                                  with: "# clyde-statusline-version: 0")
        try old.write(to: AppPaths.clydeStatusLineScript, atomically: true, encoding: .utf8)
        XCTAssertEqual(UsageLimitsInstaller.healthCheck(),
                       .outdated(installed: 0, current: UsageLimitsInstaller.currentScriptVersion))
    }

    func testOfferFollowsTheSettingAndTheDismissal() {
        UsageLimitsInstaller.offerOverride = nil
        let defaults = UserDefaults(suiteName: "UsageLimitsInstallerTests")!
        defaults.removePersistentDomain(forName: "UsageLimitsInstallerTests")
        XCTAssertTrue(UsageLimitsInstaller.shouldOffer(defaults: defaults))
        defaults.set(true, forKey: UsageLimitsInstaller.settingKey)
        XCTAssertFalse(UsageLimitsInstaller.shouldOffer(defaults: defaults))
        defaults.set(false, forKey: UsageLimitsInstaller.settingKey)
        defaults.set(true, forKey: UsageLimitsInstaller.offerDismissedKey)
        XCTAssertFalse(UsageLimitsInstaller.shouldOffer(defaults: defaults))
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `swift test --filter UsageLimitsInstallerTests 2>&1 | tail -5`
Expected: compile error, `UsageLimitsInstaller` not found.

- [ ] **Step 4: Write the installer**

```swift
import Foundation

/// Installs the status-line wrapper and owns the one `statusLine` slot
/// in `~/.claude/settings.json`.
///
/// The slot is shared: whatever the user had there before is stored in
/// `~/.clyde/usage/passthrough` and run by the wrapper with the same
/// stdin, and put back when the feature is turned off. Kept outside
/// settings.json so a hand edit there cannot lose it.
enum UsageLimitsInstaller {

    /// MUST stay in sync with the `clyde-statusline-version` line at the
    /// top of `Clyde/Resources/clyde-statusline.sh`.
    static let currentScriptVersion = 1

    /// The Settings toggle. Off by default: a configured status line is
    /// visible in the terminal in a way the hook is not.
    static let settingKey = "showUsageLimits"
    /// Set when the user closes the one-time offer chip.
    static let offerDismissedKey = "usageLimitsOfferDismissed"

    enum Issue: Equatable {
        case notInstalled
        case scriptMissing
        case scriptVersionUnreadable
        case outdated(installed: Int, current: Int)
        /// Something else took the slot after Clyde did.
        case displaced(by: String)

        var message: String {
            switch self {
            case .notInstalled:
                return "The status line wrapper is not installed."
            case .scriptMissing:
                return "The status line wrapper is registered but its script is gone. Turn the setting off and on to reinstall it."
            case .scriptVersionUnreadable:
                return "The status line wrapper on disk carries no readable version. Turn the setting off and on to replace it."
            case .outdated(let installed, let current):
                return "The status line wrapper is outdated (v\(installed) → v\(current)). Turn the setting off and on to upgrade it."
            case .displaced(let command):
                return "Another status line replaced Clyde's (\(command)). Turn the setting off and on to adopt it and put Clyde's wrapper back in front."
            }
        }
    }

    enum InstallError: LocalizedError, Equatable {
        case parseFailed
        case writeFailed(String)
        case bundledScriptMissing

        var errorDescription: String? {
            switch self {
            case .parseFailed: return "Failed to parse existing ~/.claude/settings.json"
            case .writeFailed(let msg): return "Failed to write: \(msg)"
            case .bundledScriptMissing: return "The bundled status line script is missing from the app. Reinstall Clyde."
            }
        }
    }

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: settingKey)
    }

    /// Test override for `shouldOffer()`. Production never sets it.
    nonisolated(unsafe) static var offerOverride: Bool?

    /// Whether the panel should carry the one-time "Clyde can show your
    /// limits" chip: only while the feature is off and the chip has
    /// never been closed.
    static func shouldOffer(defaults: UserDefaults = .standard) -> Bool {
        if let override = offerOverride { return override }
        if defaults.bool(forKey: settingKey) { return false }
        return !defaults.bool(forKey: offerDismissedKey)
    }

    static func isClydeStatusLineCommand(_ cmd: String) -> Bool {
        cmd.contains("clyde-statusline.sh")
    }

    static func loadScript() throws -> String {
        guard let url = Bundle.module.url(forResource: "clyde-statusline", withExtension: "sh"),
              let contents = try? String(contentsOf: url, encoding: .utf8) else {
            ClydeLog.hooks.error("Bundled clyde-statusline.sh resource is missing")
            throw InstallError.bundledScriptMissing
        }
        return contents
    }

    // MARK: - Settings I/O

    private static func readSettings() throws -> [String: Any] {
        guard let data = try? Data(contentsOf: AppPaths.claudeSettingsFile), !data.isEmpty else {
            return [:]
        }
        guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            ClydeLog.hooks.error("settings.json is unparseable — refusing to overwrite it")
            throw InstallError.parseFailed
        }
        return parsed
    }

    private static func writeSettings(_ settings: [String: Any]) throws {
        do {
            try FileManager.default.createDirectory(at: AppPaths.claudeDir, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: AppPaths.claudeSettingsFile, options: .atomic)
            // The settings.json watcher in AppViewModel suppresses the
            // echo of Clyde's own writes by this timestamp; ours count.
            HookInstaller.lastSelfWriteAt = Date()
        } catch {
            throw InstallError.writeFailed(error.localizedDescription)
        }
    }

    private static func configuredCommand(in settings: [String: Any]) -> String? {
        (settings["statusLine"] as? [String: Any])?["command"] as? String
    }

    // MARK: - Install / uninstall

    static func install() throws {
        var settings = try readSettings()

        try FileManager.default.createDirectory(at: AppPaths.claudeHooksDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: AppPaths.usageDir, withIntermediateDirectories: true)
        let script = try loadScript()
        do {
            try script.write(to: AppPaths.clydeStatusLineScript, atomically: true, encoding: .utf8)
        } catch {
            throw InstallError.writeFailed(error.localizedDescription)
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                               atPath: AppPaths.clydeStatusLineScript.path)

        var statusLine = settings["statusLine"] as? [String: Any] ?? [:]
        if let theirs = configuredCommand(in: settings), !isClydeStatusLineCommand(theirs) {
            // Theirs goes behind ours. Overwrites an older stored
            // command on purpose: a user who changed status lines while
            // the feature was off means the new one.
            try theirs.write(to: AppPaths.usagePassthroughFile, atomically: true, encoding: .utf8)
        } else if configuredCommand(in: settings) == nil {
            try? FileManager.default.removeItem(at: AppPaths.usagePassthroughFile)
        }
        statusLine["type"] = "command"
        statusLine["command"] = AppPaths.clydeStatusLineScript.path
        settings["statusLine"] = statusLine
        try writeSettings(settings)
        ClydeLog.hooks.info("Status line wrapper installed")
    }

    static func uninstall() throws {
        var settings = try readSettings()
        if let configured = configuredCommand(in: settings), isClydeStatusLineCommand(configured) {
            var statusLine = settings["statusLine"] as? [String: Any] ?? [:]
            if let theirs = try? String(contentsOf: AppPaths.usagePassthroughFile, encoding: .utf8),
               !theirs.isEmpty {
                statusLine["command"] = theirs
                settings["statusLine"] = statusLine
            } else {
                settings["statusLine"] = nil
            }
            try writeSettings(settings)
        }
        // Only once settings.json no longer points at it.
        try? FileManager.default.removeItem(at: AppPaths.clydeStatusLineScript)
        try? FileManager.default.removeItem(at: AppPaths.usagePassthroughFile)
        try? FileManager.default.removeItem(at: AppPaths.usageSnapshotFile)
        ClydeLog.hooks.info("Status line wrapper uninstalled")
    }

    // MARK: - Health

    static func installedScriptVersion() -> Int? {
        guard let source = try? String(contentsOf: AppPaths.clydeStatusLineScript, encoding: .utf8) else {
            return nil
        }
        for line in source.split(separator: "\n").prefix(5) {
            if let range = line.range(of: "# clyde-statusline-version: ") {
                return Int(line[range.upperBound...].trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }

    static func healthCheck() -> Issue? {
        let settings = (try? readSettings()) ?? [:]
        let configured = configuredCommand(in: settings)
        let scriptExists = FileManager.default.fileExists(atPath: AppPaths.clydeStatusLineScript.path)

        if let configured, !isClydeStatusLineCommand(configured) {
            return scriptExists ? .displaced(by: configured) : .notInstalled
        }
        guard configured != nil else { return .notInstalled }
        guard scriptExists else { return .scriptMissing }
        guard let version = installedScriptVersion() else { return .scriptVersionUnreadable }
        if version < currentScriptVersion {
            return .outdated(installed: version, current: currentScriptVersion)
        }
        return nil
    }
}
```

- [ ] **Step 5: Point the script test at the constant**

In `ClydeTests/StatusLineScriptTests.swift`, `testCarriesAVersionStamp` uses `UsageLimitsInstaller.currentScriptVersion` (replace the literal `1` from Task 2).

- [ ] **Step 6: Run the tests to verify they pass**

Run: `swift test --filter "UsageLimitsInstallerTests|StatusLineScriptTests" 2>&1 | tail -8`
Expected: all pass.

- [ ] **Step 7: Commit**

```bash
git add Clyde/Services/UsageLimitsInstaller.swift Clyde/Services/AppPaths.swift ClydeTests/UsageLimitsInstallerTests.swift ClydeTests/StatusLineScriptTests.swift
git commit -m "feat(limits): installer for the status-line slot

statusLine is a single slot in settings.json, so the installer stores whatever was there in ~/.clyde/usage/passthrough, puts Clyde's wrapper in front of it, and restores it on uninstall. Kept outside settings.json so a hand edit cannot lose the user's own command. Refuses an unparseable settings.json the way HookInstaller does."
```

---

### Task 4: `UsageLimitsStore` — watching the snapshot

**Files:**
- Create: `Clyde/Services/UsageLimitsStore.swift`
- Test: `ClydeTests/UsageLimitsStoreTests.swift`

**Interfaces:**
- Consumes: `UsageLimits.parse(_:modifiedAt:)`, `droppingExpiredWindows(now:)`, `AppPaths.usageDir`, `AppPaths.usageSnapshotFile`, `UsageLimitsInstaller.settingKey`.
- Produces: `@MainActor final class UsageLimitsStore: ObservableObject` with `@Published private(set) var limits: UsageLimits?`, `init(directory: URL = AppPaths.usageDir, isEnabled: @escaping () -> Bool = { UserDefaults.standard.bool(forKey: UsageLimitsInstaller.settingKey) })`, `func start()`, `func stop()`, `func scan(now: Date = Date())`.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import Clyde

@MainActor
final class UsageLimitsStoreTests: XCTestCase {
    private var dir: URL!
    private var enabled = true

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clyde-limits-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        enabled = true
    }

    override func tearDown() async throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    private func makeStore() -> UsageLimitsStore {
        UsageLimitsStore(directory: dir, isEnabled: { [unowned self] in self.enabled })
    }

    private func writeSnapshot(fiveHourResetsAt: TimeInterval) throws {
        let json = """
        {"session_id": "abc", "model": {"display_name": "Opus"},
         "rate_limits": {"five_hour": {"used_percentage": 42, "resets_at": \(Int(fiveHourResetsAt))},
                         "seven_day": {"used_percentage": 18, "resets_at": \(Int(fiveHourResetsAt + 86_400 * 3))}}}
        """
        try json.write(to: dir.appendingPathComponent("statusline.json"), atomically: true, encoding: .utf8)
    }

    func testScanReadsTheSnapshot() throws {
        try writeSnapshot(fiveHourResetsAt: Date().timeIntervalSince1970 + 3600)
        let store = makeStore()
        store.scan()
        XCTAssertEqual(store.limits?.fiveHour?.usedPercentage, 42)
        XCTAssertEqual(store.limits?.sessionID, "abc")
    }

    func testNoSnapshotMeansNoLimits() {
        let store = makeStore()
        store.scan()
        XCTAssertNil(store.limits)
    }

    func testDisabledMeansNoLimitsEvenWithASnapshot() throws {
        try writeSnapshot(fiveHourResetsAt: Date().timeIntervalSince1970 + 3600)
        enabled = false
        let store = makeStore()
        store.scan()
        XCTAssertNil(store.limits)
    }

    func testAnExpiredWindowIsDroppedOnScan() throws {
        try writeSnapshot(fiveHourResetsAt: Date().timeIntervalSince1970 - 60)
        let store = makeStore()
        store.scan()
        XCTAssertNil(store.limits?.fiveHour)
        XCTAssertNotNil(store.limits?.sevenDay)
    }

    func testUpdatedAtIsTheFilesModificationTime() throws {
        try writeSnapshot(fiveHourResetsAt: Date().timeIntervalSince1970 + 3600)
        let store = makeStore()
        store.scan()
        let mtime = try XCTUnwrap(try FileManager.default
            .attributesOfItem(atPath: dir.appendingPathComponent("statusline.json").path)[.modificationDate] as? Date)
        XCTAssertEqual(store.limits?.updatedAt, mtime)
    }

    func testAReplacedFileIsPickedUpByTheWatcher() async throws {
        let store = makeStore()
        store.start()
        defer { store.stop() }
        XCTAssertNil(store.limits)

        try writeSnapshot(fiveHourResetsAt: Date().timeIntervalSince1970 + 3600)
        // The wrapper renames a temp file into place; atomic write does the same.
        let deadline = Date().addingTimeInterval(3)
        while store.limits == nil && Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(store.limits?.fiveHour?.usedPercentage, 42)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter UsageLimitsStoreTests 2>&1 | tail -5`
Expected: compile error, `UsageLimitsStore` not found.

- [ ] **Step 3: Write the store**

```swift
import Foundation
import Combine

/// Watches `~/.clyde/usage/` for the snapshot the status-line wrapper
/// writes, and publishes the parsed windows.
///
/// Modelled on `PermissionRequestStore`: a directory watcher for the
/// immediate reaction — the wrapper renames a temp file into place,
/// which the directory sees — plus a slow timer, because a window
/// expiring produces no filesystem event.
@MainActor
final class UsageLimitsStore: ObservableObject {

    /// The last snapshot, minus any window whose reset has passed. Nil
    /// when the feature is off, nothing has been written yet, or the
    /// payload carried no `rate_limits` (an API key, a session before
    /// its first response).
    @Published private(set) var limits: UsageLimits?

    private let directory: URL
    private let isEnabled: () -> Bool
    private var dirSource: DispatchSourceFileSystemObject?
    private var dirFD: Int32 = -1
    private var expiryTimer: Timer?

    init(directory: URL = AppPaths.usageDir,
         isEnabled: @escaping () -> Bool = {
             UserDefaults.standard.bool(forKey: UsageLimitsInstaller.settingKey)
         }) {
        self.directory = directory
        self.isEnabled = isEnabled
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        expiryTimer?.invalidate()
        dirSource?.cancel()
    }

    func start() {
        stop()
        startDirectoryWatcher()
        // A window ends on a clock. Thirty seconds keeps a spent window
        // from lingering long after Claude Code would have dropped it.
        expiryTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.scan() }
        }
        scan()
    }

    func stop() {
        expiryTimer?.invalidate()
        expiryTimer = nil
        dirSource?.cancel()
        dirSource = nil
    }

    func scan(now: Date = Date()) {
        guard isEnabled() else {
            if limits != nil { limits = nil }
            return
        }
        let file = directory.appendingPathComponent("statusline.json")
        guard let data = try? Data(contentsOf: file),
              let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                  .contentModificationDate,
              let parsed = UsageLimits.parse(data, modifiedAt: modified) else {
            if limits != nil { limits = nil }
            return
        }
        let live = parsed.droppingExpiredWindows(now: now)
        let next: UsageLimits? = live.hasAnyWindow ? live : nil
        if next != limits { limits = next }
    }

    private func startDirectoryWatcher() {
        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else {
            ClydeLog.hooks.error("Failed to open usage dir for watching")
            return
        }
        dirFD = fd
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: DispatchQueue.main
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in self?.scan() }
        }
        source.setCancelHandler { [weak self] in
            if let fd = self?.dirFD, fd >= 0 {
                close(fd)
                self?.dirFD = -1
            }
        }
        source.resume()
        dirSource = source
    }
}
```

`ClydeLog.hooks` is the existing logger category in `Clyde/Services/Logger.swift`; reuse it rather than adding one.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter UsageLimitsStoreTests 2>&1 | tail -8`
Expected: all pass. If the watcher test is flaky, the `.write` mask on the directory fd is what catches the rename into it; check the `eventMask`.

- [ ] **Step 5: Commit**

```bash
git add Clyde/Services/UsageLimitsStore.swift ClydeTests/UsageLimitsStoreTests.swift
git commit -m "feat(limits): store that watches the status-line snapshot

A directory watcher for the rename the wrapper does, and a thirty-second timer for the one event a filesystem never reports: a window's reset time passing. Publishes nothing while the feature is off, so nothing downstream has to check the setting."
```

---

### Task 5: AppViewModel wiring, the setting, and the offer chip

**Files:**
- Modify: `Clyde/ViewModels/AppViewModel.swift`
- Modify: `Clyde/Services/HookInstaller.swift` (`HealthIssue`, `healthCheck()`)
- Modify: `Clyde/Views/Components/AdvisoryViews.swift`
- Modify: `ClydeTests/HookInstallerTests.swift` (`setUp`)
- Test: `ClydeTests/HookInstallerTests.swift` (two new tests), `ClydeTests/AppViewModelTests.swift` (one new test)

**Interfaces:**
- Consumes: `UsageLimitsStore`, `UsageLimitsInstaller`, `UsageLimits`.
- Produces on `AppViewModel`:
  - `let usageStore: UsageLimitsStore`
  - `@Published private(set) var usageLimits: UsageLimits?`
  - `@Published var showUsageLimits: Bool` (persists to `UsageLimitsInstaller.settingKey`; installs/uninstalls)
  - `@Published private(set) var usageInstallError: String?`
  - `var hasRateLimitedSession: Bool`
  - `var usageIsStale: Bool`
  - `func usageSessionName(for limits: UsageLimits) -> String?`
- Produces on `HookInstaller.HealthIssue`: `case usageLimitsAvailable`, `var opensSettings: Bool`.

- [ ] **Step 1: Write the failing tests**

Append to `ClydeTests/HookInstallerTests.swift`:

```swift
    func testOfferIsAChipBehindEveryRealIssue() throws {
        UsageLimitsInstaller.offerOverride = true
        // Not installed outranks the offer.
        XCTAssertEqual(HookInstaller.healthCheck(), .notInstalled)
        try HookInstaller.install()
        XCTAssertEqual(HookInstaller.healthCheck(), .usageLimitsAvailable)
        UsageLimitsInstaller.offerOverride = false
        XCTAssertNil(HookInstaller.healthCheck())
    }

    func testOfferIsDismissableAndOpensSettings() {
        let issue = HookInstaller.HealthIssue.usageLimitsAvailable
        XCTAssertEqual(issue.presentation, .chip)
        XCTAssertTrue(issue.isDismissable)
        XCTAssertFalse(issue.isActionable)
        XCTAssertTrue(issue.opensSettings)
        XCTAssertEqual(issue.dismissalIdentity, "usageLimitsAvailable")
        XCTAssertEqual(issue.chipLabel, "Limits")
    }
```

And in the same file's `setUp`, after `HookInstaller.inputMonitoringTrustedOverride = true`:

```swift
        // The limits offer is a chip that would otherwise sit behind
        // every "fully healthy" assertion. Tests that cover the offer
        // flip this on themselves.
        UsageLimitsInstaller.offerOverride = false
```

and in `tearDown`: `UsageLimitsInstaller.offerOverride = nil`.

Append to `ClydeTests/AppViewModelTests.swift` (look at the file's existing `makeViewModel`-style helper and use it; if none exists, `AppViewModel(processMonitor: ProcessMonitor(stateDir: <temp>))` with the temp-dir pattern from `ProcessMonitorTests`):

```swift
    @MainActor
    func testRateLimitedSessionIsExhausted() {
        let monitor = ProcessMonitor()
        let vm = AppViewModel(processMonitor: monitor)
        var s = Session(pid: 4242, workingDirectory: "/tmp/x", status: .busy)
        s.errorReason = "rate_limit"
        monitor.sessions = [s]
        XCTAssertTrue(vm.hasRateLimitedSession)
        s.errorReason = nil
        monitor.sessions = [s]
        XCTAssertFalse(vm.hasRateLimitedSession)
    }
```

If `ProcessMonitor.sessions` is not settable from tests, check `ProcessMonitorTests` for the `-error` file route (`stateDir` + writing `<sid>-error`) and drive it that way instead.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter "HookInstallerTests|AppViewModelTests" 2>&1 | tail -5`
Expected: compile error on `usageLimitsAvailable` / `hasRateLimitedSession`.

- [ ] **Step 3: Add the advisory to `HealthIssue`**

In `Clyde/Services/HookInstaller.swift`, add the case at the end of `enum HealthIssue`:

```swift
        case usageLimitsAvailable               // feature is off and the user has not yet declined it
```

Then extend each switch. `presentation`: add `.usageLimitsAvailable` to the `.chip` list. `chipLabel`: `case .usageLimitsAvailable: return "Limits"`. `bannerTitle`: `case .usageLimitsAvailable: return "Clyde can show your Claude limits"`. `bannerMessage`:

```swift
            case .usageLimitsAvailable:
                return "See how much of the 5-hour session and the 7-day week is used, and when each resets. Clyde installs a status line wrapper in Claude Code for this; a status line hides most of the terminal footer's keyboard hints. Turn it on in Settings."
```

`isActionable`: `.usageLimitsAvailable` returns `false` (add to the first case list). `isDismissable`: add to the `true` list. `dismissalIdentity`: `case .usageLimitsAvailable: return "usageLimitsAvailable"`. Add a new property after `isShortcutPermission`:

```swift
        /// True for the advisory whose action is a Clyde setting rather
        /// than a System Settings pane: the detail card carries an
        /// "Open Settings" button.
        var opensSettings: Bool {
            switch self {
            case .usageLimitsAvailable: return true
            default: return false
            }
        }
```

At the very end of `healthCheck()`, immediately before its final `return nil`:

```swift
        // Lowest priority of all: an offer, not a fault. Only when
        // everything above is healthy is the panel quiet enough for it.
        if UsageLimitsInstaller.shouldOffer() {
            return .usageLimitsAvailable
        }
```

In `AppViewModel.ensureHookHealthy()`, the `switch issue` that sets `shouldAutoInstall` must cover the new case:

```swift
            case .usageLimitsAvailable:
                // An offer. Nothing to install until the user says so.
                shouldAutoInstall = false
```

- [ ] **Step 4: The detail card's button**

In `Clyde/Views/Components/AdvisoryViews.swift`, `AdvisoryDetail.body`, extend the trailing `if issue.isShortcutPermission { … } else if let url … { … }` chain with a branch before the URL one:

```swift
            } else if issue.opensSettings {
                Button("Open Settings") {
                    NotificationCenter.default.post(name: .clydeOpenSettings, object: nil)
                    onClose()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(TextColor.primary)
                .padding(.horizontal, Spacing.xs)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: Radius.small)
                        .fill(Color.white.opacity(0.12))
                )
                .padding(.top, 2)
```

- [ ] **Step 5: Wire the view model**

In `Clyde/ViewModels/AppViewModel.swift`:

Next to `let permissionStore = PermissionRequestStore()`:

```swift
    let usageStore = UsageLimitsStore()

    /// The two subscription windows, or nil when there is nothing to
    /// show: feature off, no snapshot yet, or a plan that has none.
    @Published private(set) var usageLimits: UsageLimits?

    /// The install error from the last toggle, for Settings to show.
    @Published private(set) var usageInstallError: String?

    /// Off by default. On installs the status line wrapper; off
    /// uninstalls it and puts the user's own status line back.
    @Published var showUsageLimits: Bool = UserDefaults.standard
        .bool(forKey: UsageLimitsInstaller.settingKey) {
        didSet {
            guard showUsageLimits != oldValue else { return }
            UserDefaults.standard.set(showUsageLimits, forKey: UsageLimitsInstaller.settingKey)
            usageInstallError = nil
            do {
                if showUsageLimits {
                    try UsageLimitsInstaller.install()
                } else {
                    try UsageLimitsInstaller.uninstall()
                }
            } catch {
                usageInstallError = error.localizedDescription
                ClydeLog.hooks.error("Usage limits toggle failed: \(error.localizedDescription, privacy: .public)")
            }
            usageStore.scan()
            // Turning it on retires the offer chip; off may bring it back.
            refreshHookHealth()
        }
    }

    /// A live session that Claude Code stopped with `rate_limit` is the
    /// account-level "exhausted" fact, whatever the percentage says.
    var hasRateLimitedSession: Bool {
        processMonitor.sessions.contains { !$0.isGhost && $0.errorReason == "rate_limit" }
    }

    var usageIsStale: Bool {
        guard let usageLimits else { return false }
        return usageLimits.isStale(now: Date(), hasLiveSession: hasLiveSessions)
    }

    /// The session whose status line wrote the snapshot, by display
    /// name, so the footer can say where the numbers came from.
    func usageSessionName(for limits: UsageLimits) -> String? {
        guard let id = limits.sessionID else { return nil }
        return processMonitor.sessions.first { $0.sessionId == id }?.displayName
    }
```

`hasLiveSessions` already exists on `AppViewModel` (used by `ExpandedRootView`).

Next to `startPermissionStore()`:

```swift
    private func startUsageStore() {
        usageStore.start()
        usageStore.$limits
            .receive(on: RunLoop.main)
            .sink { [weak self] limits in self?.usageLimits = limits }
            .store(in: &cancellables)
    }
```

and call `startUsageStore()` right after `startPermissionStore()` inside `start()`.

In `dismissCurrentBanner()`, after `dismissedBannerIdentities.insert(identity)`:

```swift
        // The offer is one-time across launches, unlike the health
        // advisories that come back on relaunch.
        if issue == .usageLimitsAvailable {
            UserDefaults.standard.set(true, forKey: UsageLimitsInstaller.offerDismissedKey)
        }
```

- [ ] **Step 6: Run the full suite**

Run: `swift test 2>&1 | tail -5`
Expected: all pass, including the two new `HookInstallerTests` and the `AppViewModelTests` addition. Any test that asserted `healthCheck()` returns nil on a healthy install and did not go through `setUp` now needs `UsageLimitsInstaller.offerOverride = false`; fix at the call site.

- [ ] **Step 7: Commit**

```bash
git add Clyde/ViewModels/AppViewModel.swift Clyde/Services/HookInstaller.swift Clyde/Views/Components/AdvisoryViews.swift ClydeTests/HookInstallerTests.swift ClydeTests/AppViewModelTests.swift
git commit -m "feat(limits): setting, store lifecycle and the one-time offer

The toggle installs or removes the wrapper and the store follows it. The offer rides the advisory chip the panel already has, at the lowest priority the health check knows, and its dismissal persists — a feature the user declined once should not ask again on every launch."
```

---

### Task 6: `UsageMeter` and the full panel's `LimitsBand`

**Files:**
- Create: `Clyde/Views/Components/UsageMeter.swift`
- Create: `Clyde/Views/Components/LimitsBand.swift`
- Modify: `Clyde/Views/ExpandedView.swift`

**Interfaces:**
- Consumes: `UsageLimits`, `UsageWindow`, `UsageLimits.Level`, `SessionTheme`, `TextColor`, `Spacing`, `Radius`, `Rule`.
- Produces:
  - `struct UsageMeter: View` with `init(label: String?, window: UsageWindow, level: UsageLimits.Level, stale: Bool, barWidth: CGFloat, showsValue: Bool = true)`
  - `static func UsageMeter.color(for level: UsageLimits.Level) -> Color`
  - `struct LimitsBand: View` with `init(limits: UsageLimits, rateLimited: Bool, stale: Bool, sessionName: String?)`; expansion persisted under `@AppStorage("limitsBandExpanded")`.

- [ ] **Step 1: The meter**

```swift
import SwiftUI

/// Label · bar · percentage. One component in three widths: the full
/// panel's band, compact's footer, and the band's opened rows use it
/// with different bars and the same words.
struct UsageMeter: View {
    /// "5h" / "7d". Nil when the footer is too crowded for words.
    let label: String?
    let window: UsageWindow
    let level: UsageLimits.Level
    let stale: Bool
    let barWidth: CGFloat
    var showsValue: Bool = true

    static func color(for level: UsageLimits.Level) -> Color {
        switch level {
        case .normal:    return Color.white.opacity(0.55)
        case .warning:   return SessionTheme.attentionColor
        case .exhausted: return SessionTheme.errorColor
        }
    }

    var body: some View {
        let fill = Self.color(for: level)
        HStack(spacing: 4) {
            if let label {
                Text(label)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(TextColor.tertiary)
            }
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.10))
                Capsule().fill(fill)
                    .frame(width: barWidth * CGFloat(min(100, max(0, window.usedPercentage)) / 100))
            }
            .frame(width: barWidth, height: 4)
            if showsValue {
                Text(UsageLimits.percentText(for: window, level: level))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(level == .normal ? TextColor.secondary : fill)
            }
        }
        .opacity(stale ? 0.55 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        let name = label == "7d" ? "Week" : "Session"
        return "\(name) \(UsageLimits.percentText(for: window, level: level)) used"
    }
}
```

- [ ] **Step 2: The band**

```swift
import SwiftUI

/// The two subscription windows, above Activity, in Activity's own
/// language: a header row that is the whole thing when closed, and two
/// rows with the resets when open.
struct LimitsBand: View {
    let limits: UsageLimits
    let rateLimited: Bool
    let stale: Bool
    let sessionName: String?

    @AppStorage("limitsBandExpanded") private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func level(_ window: UsageWindow, isSession: Bool) -> UsageLimits.Level {
        UsageLimits.level(for: window, rateLimited: isSession && rateLimited)
    }

    var body: some View {
        // Countdowns move; a periodic clock keeps them honest without
        // the store having to publish for a minute passing.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(spacing: 0) {
                header
                if expanded {
                    rows(now: context.date)
                }
            }
        }
        .background(Color.white.opacity(0.02))
        .overlay(
            Rectangle().frame(height: Rule.thickness).foregroundStyle(Rule.band),
            alignment: .top
        )
    }

    private var header: some View {
        Button(action: {
            if reduceMotion { expanded.toggle() } else {
                withAnimation(.easeInOut(duration: 0.22)) { expanded.toggle() }
            }
        }) {
            HStack(spacing: 8) {
                Image(systemName: "gauge.with.needle")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color(white: 0.5))
                Text("Limits")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(white: 0.7))
                if let w = limits.fiveHour {
                    UsageMeter(label: "5h", window: w, level: level(w, isSession: true),
                               stale: stale, barWidth: 44)
                }
                if let w = limits.sevenDay {
                    UsageMeter(label: "7d", window: w, level: level(w, isSession: false),
                               stale: stale, barWidth: 44)
                }
                Spacer(minLength: 4)
                Image(systemName: expanded ? "chevron.down" : "chevron.up")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color(white: 0.45))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Claude usage limits")
        .accessibilityHint(expanded ? "Tap to collapse" : "Tap to expand")
    }

    private func rows(now: Date) -> some View {
        VStack(spacing: 0) {
            if let w = limits.fiveHour {
                row(name: "Session", window: w, level: level(w, isSession: true), now: now)
            }
            if let w = limits.sevenDay {
                if limits.fiveHour != nil {
                    Rectangle().fill(Rule.row).frame(height: Rule.thickness).padding(.leading, 34)
                }
                row(name: "Week", window: w, level: level(w, isSession: false), now: now)
            }
            Text(limits.freshnessText(now: now, sessionName: sessionName, stale: stale))
                .font(.system(size: 9.5))
                .foregroundStyle(TextColor.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 34)
                .padding(.trailing, 14)
                .padding(.top, 4)
                .padding(.bottom, 8)
        }
    }

    private func row(name: String, window: UsageWindow, level: UsageLimits.Level, now: Date) -> some View {
        let fill = UsageMeter.color(for: level)
        return HStack(spacing: 12) {
            Text(name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(TextColor.secondary)
                .frame(width: 58, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.10))
                    Capsule().fill(fill)
                        .frame(width: geo.size.width * CGFloat(min(100, max(0, window.usedPercentage)) / 100))
                }
            }
            .frame(height: 5)
            Text(UsageLimits.percentText(for: window, level: level))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(level == .normal ? TextColor.primary : fill)
                .frame(width: 34, alignment: .trailing)
            Text(UsageLimits.resetText(for: window, now: now, level: level))
                .font(.system(size: 10, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(level == .exhausted ? fill : TextColor.tertiary)
                .frame(width: 118, alignment: .trailing)
        }
        .padding(.leading, 34)
        .padding(.trailing, 14)
        .padding(.vertical, 7)
        .opacity(stale ? 0.55 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name) \(UsageLimits.percentText(for: window, level: level)) used, \(UsageLimits.resetText(for: window, now: now, level: level))")
    }
}
```

- [ ] **Step 3: Place it in the full panel**

In `Clyde/Views/ExpandedView.swift`, between `Spacer(minLength: 0)` and `ActivityTimelineView(...)`:

```swift
            if let limits = appViewModel.usageLimits, limits.hasAnyWindow {
                LimitsBand(limits: limits,
                           rateLimited: appViewModel.hasRateLimitedSession,
                           stale: appViewModel.usageIsStale,
                           sessionName: appViewModel.usageSessionName(for: limits))
            }
```

- [ ] **Step 4: Build and look**

Run: `swift build 2>&1 | tail -3` — expect a clean build.

Then a live look, following the memory note that the dev build is ad-hoc signed: `swift run Clyde`, open Settings, turn on "Show Claude usage limits", start a `claude` session on this Max account and send one prompt. Expect the band above Activity with both meters; click it and expect the two rows and the freshness line. Turn the setting off and expect the band gone and `~/.claude/settings.json` without a `statusLine` key (or with the previous one).

- [ ] **Step 5: Commit**

```bash
git add Clyde/Views/Components/UsageMeter.swift Clyde/Views/Components/LimitsBand.swift Clyde/Views/ExpandedView.swift
git commit -m "feat(limits): the Limits band above Activity

One meter component, and a band in Activity's own language: a header row that is the whole thing when closed, two rows with the resets when open, and a line saying where and when the numbers came from — because without a live session they stop moving."
```

---

### Task 7: The session meter in compact's footer

**Files:**
- Modify: `Clyde/Views/CompactRootView.swift`
- Test: `ClydeTests/CompactModeTests.swift`

**Interfaces:**
- Consumes: `UsageMeter`, `AppViewModel.usageLimits`, `hasRateLimitedSession`, `usageIsStale`.
- Produces: `static func CompactRootView.footerMeterLabel(countsShown: Int, advisory: Bool) -> String?` — nil when the footer must drop the label.

- [ ] **Step 1: Write the failing test**

Append to `ClydeTests/CompactModeTests.swift`:

```swift
    // MARK: - Footer meter

    /// The same crowding rule that turns the pills into dots takes the
    /// meter's label; the bar and the figure stay.
    func testFooterMeterKeepsItsLabelUntilCrowded() {
        XCTAssertEqual(CompactRootView.footerMeterLabel(countsShown: 2, advisory: false), "5h")
        XCTAssertNil(CompactRootView.footerMeterLabel(countsShown: 3, advisory: false))
        XCTAssertNil(CompactRootView.footerMeterLabel(countsShown: 2, advisory: true))
        XCTAssertEqual(CompactRootView.footerMeterLabel(countsShown: 1, advisory: true), "5h")
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter CompactModeTests 2>&1 | tail -5`
Expected: compile error, `footerMeterLabel` not found.

- [ ] **Step 3: Implement**

In `Clyde/Views/CompactRootView.swift`, add next to `isCrowded`:

```swift
    /// What the footer's meter is allowed to say. The words go under the
    /// same crowding the pills give theirs up under.
    static func footerMeterLabel(countsShown: Int, advisory: Bool) -> String? {
        let crowded = countsShown > 2 || (advisory && countsShown > 1)
        return crowded ? nil : "5h"
    }
```

In `footer`, between the advisory chip block and the Expand `Button`:

```swift
            // Only the session window: it is the one that changes within
            // a sitting and ends a task mid-turn. The week is a hover and
            // a mode away. Two labelled meters here came to 440 points.
            if let window = appViewModel.usageLimits?.fiveHour {
                Rectangle()
                    .fill(Rule.band)
                    .frame(width: Rule.thickness, height: 14)
                UsageMeter(
                    label: Self.footerMeterLabel(
                        countsShown: counts.count,
                        advisory: appViewModel.hookHealthIssue?.presentation == .chip),
                    window: window,
                    level: UsageLimits.level(for: window, rateLimited: appViewModel.hasRateLimitedSession),
                    stale: appViewModel.usageIsStale,
                    barWidth: 28
                )
                .help(appViewModel.usageLimits?.sevenDay.map {
                    "Week \(UsageLimits.percentText(for: $0, level: UsageLimits.level(for: $0, rateLimited: false))) used"
                } ?? "Session window")
            }
```

`Spacer(minLength: Spacing.xs)` already sits before the advisory chip; the meter and the Expand button stay on the right of it.

- [ ] **Step 4: Run the tests, then look**

Run: `swift test --filter CompactModeTests 2>&1 | tail -5` — expect pass.
Run `swift run Clyde`, switch to compact with the feature on, and check: the meter sits between the pills and Expand; with three states showing, the `5h` label disappears and the bar stays; the window height is unchanged.

- [ ] **Step 5: Commit**

```bash
git add Clyde/Views/CompactRootView.swift ClydeTests/CompactModeTests.swift
git commit -m "feat(limits): the session window in compact's footer

Only the five-hour window: it is the one that changes within a sitting and the one that ends a task mid-turn; the week is a hover and a mode away. Two labelled meters beside two pills and the way back measured 440 points in a 400-point window. Under the same crowding that turns the pills into dots, the label goes and the bar stays."
```

---

### Task 8: Notifications at 80 % and on reset

**Files:**
- Create: `Clyde/Models/UsageLimitsAlerts.swift`
- Modify: `Clyde/Services/NotificationService.swift`
- Modify: `Clyde/ViewModels/AppViewModel.swift`
- Test: `ClydeTests/UsageLimitsAlertsTests.swift`

**Interfaces:**
- Produces:
  - `struct UsageLimitsAlerts` with `enum Alert: Equatable { case sessionNearLimit(resetsAt: Date), sessionBackAfterReset }`, `var warnedResetsAt: Date?`, `var wasExhausted: Bool`, `mutating func alerts(for limits: UsageLimits?, rateLimited: Bool) -> [Alert]`
  - `NotificationService.sendUsageNotification(identifier: String, body: String)`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import Clyde

final class UsageLimitsAlertsTests: XCTestCase {
    private let reset = Date(timeIntervalSince1970: 1_800_004_320)

    private func limits(_ percent: Double, resetsAt: Date? = nil) -> UsageLimits {
        UsageLimits(fiveHour: UsageWindow(usedPercentage: percent, resetsAt: resetsAt ?? reset),
                    sevenDay: UsageWindow(usedPercentage: 30, resetsAt: reset.addingTimeInterval(86_400)),
                    updatedAt: Date(), sessionID: nil, modelName: nil)
    }

    func testWarnsOnceWhenTheSessionCrossesEighty() {
        var alerts = UsageLimitsAlerts()
        XCTAssertEqual(alerts.alerts(for: limits(79), rateLimited: false), [])
        XCTAssertEqual(alerts.alerts(for: limits(81), rateLimited: false), [.sessionNearLimit(resetsAt: reset)])
        XCTAssertEqual(alerts.alerts(for: limits(90), rateLimited: false), [])
    }

    func testANewWindowWarnsAgain() {
        var alerts = UsageLimitsAlerts()
        _ = alerts.alerts(for: limits(85), rateLimited: false)
        let next = reset.addingTimeInterval(5 * 3600)
        XCTAssertEqual(alerts.alerts(for: limits(85, resetsAt: next), rateLimited: false),
                       [.sessionNearLimit(resetsAt: next)])
    }

    func testTheWeekDoesNotWarn() {
        var alerts = UsageLimitsAlerts()
        let weekOnly = UsageLimits(fiveHour: nil,
                                   sevenDay: UsageWindow(usedPercentage: 95, resetsAt: reset),
                                   updatedAt: Date(), sessionID: nil, modelName: nil)
        XCTAssertEqual(alerts.alerts(for: weekOnly, rateLimited: false), [])
    }

    func testAnnouncesTheResetAfterExhaustion() {
        var alerts = UsageLimitsAlerts()
        XCTAssertEqual(alerts.alerts(for: limits(100), rateLimited: false), [.sessionNearLimit(resetsAt: reset)])
        // Still exhausted: nothing new.
        XCTAssertEqual(alerts.alerts(for: limits(100), rateLimited: true), [])
        // The window turned over.
        XCTAssertEqual(alerts.alerts(for: limits(3, resetsAt: reset.addingTimeInterval(5 * 3600)), rateLimited: false),
                       [.sessionBackAfterReset])
    }

    func testAWindowThatSimplyVanishesAfterExhaustionAlsoAnnounces() {
        var alerts = UsageLimitsAlerts()
        _ = alerts.alerts(for: limits(100), rateLimited: false)
        XCTAssertEqual(alerts.alerts(for: nil, rateLimited: false), [.sessionBackAfterReset])
    }

    func testStartingExhaustedDoesNotAnnounceAReset() {
        var alerts = UsageLimitsAlerts()
        XCTAssertEqual(alerts.alerts(for: nil, rateLimited: false), [])
        XCTAssertEqual(alerts.alerts(for: limits(10), rateLimited: false), [])
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter UsageLimitsAlertsTests 2>&1 | tail -5`
Expected: compile error, `UsageLimitsAlerts` not found.

- [ ] **Step 3: Write the decision logic**

```swift
import Foundation

/// Which notifications a change in the limits earns. Pure and small so
/// the "once per window" rule can be tested without a notification
/// centre.
///
/// Two alerts only. The week crossing 80% is not one: a bar that has
/// been blue since Wednesday is not news on Thursday.
struct UsageLimitsAlerts: Equatable {
    enum Alert: Equatable {
        case sessionNearLimit(resetsAt: Date)
        case sessionBackAfterReset
    }

    /// The reset time of the window already warned about. A new window
    /// has a new reset time, which is what makes it warn again.
    var warnedResetsAt: Date?
    /// Whether the last snapshot was spent, so the next one that is
    /// not can say so.
    var wasExhausted = false

    mutating func alerts(for limits: UsageLimits?, rateLimited: Bool) -> [Alert] {
        var result: [Alert] = []
        let window = limits?.fiveHour
        let level = window.map { UsageLimits.level(for: $0, rateLimited: rateLimited) } ?? .normal
        let exhausted = window != nil && level == .exhausted

        if let window, level != .normal, warnedResetsAt != window.resetsAt {
            warnedResetsAt = window.resetsAt
            result.append(.sessionNearLimit(resetsAt: window.resetsAt))
        }
        if wasExhausted && !exhausted {
            result.append(.sessionBackAfterReset)
        }
        wasExhausted = exhausted
        return result
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter UsageLimitsAlertsTests 2>&1 | tail -5`
Expected: all pass.

- [ ] **Step 5: Send them**

In `Clyde/Services/NotificationService.swift`, after `sendNotification(for:)`:

```swift
    /// A notification that is about the account rather than a session.
    /// Same switches, same snooze, no PID to open on click.
    func sendUsageNotification(identifier: String, body: String) {
        guard systemNotificationsEnabled, isAuthorized, !isSnoozed else { return }
        let content = UNMutableNotificationContent()
        content.title = "Clyde"
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
```

In `AppViewModel`, add a stored `private var usageAlerts = UsageLimitsAlerts()` next to `usageStore`, and change the sink in `startUsageStore()` to:

```swift
        usageStore.$limits
            .receive(on: RunLoop.main)
            .sink { [weak self] limits in
                guard let self else { return }
                self.usageLimits = limits
                for alert in self.usageAlerts.alerts(for: limits, rateLimited: self.hasRateLimitedSession) {
                    switch alert {
                    case .sessionNearLimit(let resetsAt):
                        let window = UsageWindow(usedPercentage: 0, resetsAt: resetsAt)
                        let when = UsageLimits.resetText(for: window, now: Date(), level: .normal)
                        self.notificationService.sendUsageNotification(
                            identifier: "usage-session-\(Int(resetsAt.timeIntervalSince1970))",
                            body: "Claude session window is nearly used up — \(when)")
                    case .sessionBackAfterReset:
                        self.notificationService.sendUsageNotification(
                            identifier: "usage-session-reset",
                            body: "Claude session window has reset — you can continue")
                    }
                }
            }
            .store(in: &cancellables)
```

- [ ] **Step 6: Run the full suite and commit**

Run: `swift test 2>&1 | tail -3` — expect pass.

```bash
git add Clyde/Models/UsageLimitsAlerts.swift ClydeTests/UsageLimitsAlertsTests.swift Clyde/Services/NotificationService.swift Clyde/ViewModels/AppViewModel.swift
git commit -m "feat(limits): notify once at 80% and once on the reset

Keyed by the window's reset time, so a warning fires once per window and not on every turn past the threshold, and a spent window announces itself when it turns over. The week never notifies: a bar that has been blue since Wednesday is not news on Thursday."
```

---

### Task 9: The Settings toggle and its status line

**Files:**
- Create: `Clyde/Models/UsageLimitsStatus.swift`
- Modify: `Clyde/Views/SettingsView.swift`
- Test: `ClydeTests/UsageLimitsStatusTests.swift`

**Interfaces:**
- Produces: `enum UsageLimitsStatus: Equatable { case off, blocked(String), waiting, working(Date) }` with `static func resolve(enabled: Bool, issue: UsageLimitsInstaller.Issue?, installError: String?, lastSnapshot: Date?) -> UsageLimitsStatus` and `var message: String`; `struct UsageLimitsStatusLine: View`.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import Clyde

final class UsageLimitsStatusTests: XCTestCase {
    func testOffIsOffWhateverElseIsWrong() {
        XCTAssertEqual(UsageLimitsStatus.resolve(enabled: false, issue: .scriptMissing, installError: "x", lastSnapshot: nil), .off)
    }

    func testAnInstallErrorBlocks() {
        XCTAssertEqual(UsageLimitsStatus.resolve(enabled: true, issue: nil, installError: "Failed to write", lastSnapshot: nil),
                       .blocked("Failed to write"))
    }

    func testAHealthIssueBlocks() {
        XCTAssertEqual(UsageLimitsStatus.resolve(enabled: true, issue: .displaced(by: "x.sh"), installError: nil, lastSnapshot: nil),
                       .blocked(UsageLimitsInstaller.Issue.displaced(by: "x.sh").message))
    }

    func testHealthyWithNothingYetIsWaiting() {
        XCTAssertEqual(UsageLimitsStatus.resolve(enabled: true, issue: nil, installError: nil, lastSnapshot: nil), .waiting)
    }

    func testASnapshotMeansWorking() {
        let date = Date()
        XCTAssertEqual(UsageLimitsStatus.resolve(enabled: true, issue: nil, installError: nil, lastSnapshot: date), .working(date))
    }

    func testMessagesSayWhereTheNumbersAre() {
        XCTAssertTrue(UsageLimitsStatus.off.message.contains("/usage"))
        XCTAssertTrue(UsageLimitsStatus.waiting.message.contains("Pro or Max"))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter UsageLimitsStatusTests 2>&1 | tail -5`
Expected: compile error.

- [ ] **Step 3: Write the status**

```swift
import Foundation

/// Whether the limits are actually arriving — as opposed to merely
/// switched on. The same shape as `PermissionAnsweringStatus`, for the
/// same reason: a switch says what was asked for, not what is happening.
enum UsageLimitsStatus: Equatable {
    case off
    case blocked(String)
    case waiting
    case working(Date)

    static func resolve(enabled: Bool,
                        issue: UsageLimitsInstaller.Issue?,
                        installError: String?,
                        lastSnapshot: Date?) -> UsageLimitsStatus {
        guard enabled else { return .off }
        if let installError { return .blocked(installError) }
        if let issue { return .blocked(issue.message) }
        guard let lastSnapshot else { return .waiting }
        return .working(lastSnapshot)
    }

    var message: String {
        switch self {
        case .off:
            return "Off — the limits are in Claude Code under /usage, as always."
        case .blocked(let reason):
            return "Not working — \(reason)"
        case .waiting:
            return "On, but nothing has arrived yet. The numbers come with the first response of a Claude Code session on a Pro or Max plan."
        case .working(let date):
            return "Working — last update \(Self.relative(date))."
        }
    }

    private static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
```

- [ ] **Step 4: The Settings section**

In `Clyde/Views/SettingsView.swift`, `GeneralSettingsTab`, directly after the `SettingsSection(title: "Permission requests") { … }` block:

```swift
        SettingsSection(title: "Claude usage limits") {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Toggle(isOn: $appViewModel.showUsageLimits) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show Claude usage limits")
                            .font(.system(size: 12))
                            .foregroundStyle(.white)
                        Text("The 5-hour session and the 7-day week, with their resets, in the panel. Clyde installs a status line wrapper in Claude Code for this and keeps any status line you already have behind it. A configured status line hides most of the terminal footer's keyboard hints.")
                            .font(.system(size: 10))
                            .foregroundStyle(Color(white: 0.45))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)
                .accessibilityHint("Shows how much of each Claude subscription window is used")

                UsageLimitsStatusLine(status: usageLimitsStatus)
            }
        }
```

In the `private extension GeneralSettingsTab` at the bottom of the file, next to `permissionAnsweringStatus`:

```swift
    var usageLimitsStatus: UsageLimitsStatus {
        UsageLimitsStatus.resolve(enabled: appViewModel.showUsageLimits,
                                  issue: appViewModel.showUsageLimits ? UsageLimitsInstaller.healthCheck() : nil,
                                  installError: appViewModel.usageInstallError,
                                  lastSnapshot: appViewModel.usageLimits?.updatedAt)
    }
```

And after `PermissionAnsweringStatusLine`:

```swift
/// One line saying what the limits switch is actually doing.
struct UsageLimitsStatusLine: View {
    let status: UsageLimitsStatus

    private var icon: String {
        switch status {
        case .off:      return "moon.zzz"
        case .blocked:  return "exclamationmark.triangle.fill"
        case .waiting:  return "clock"
        case .working:  return "checkmark.circle.fill"
        }
    }

    private var tint: Color {
        switch status {
        case .off:      return Color(white: 0.45)
        case .blocked:  return SessionTheme.attentionColor
        case .waiting:  return Color(white: 0.55)
        case .working:  return SessionTheme.readyColor.opacity(0.9)
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
            Text(status.message)
                .font(.system(size: 10))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(tint)
        .accessibilityElement(children: .combine)
    }
}
```

- [ ] **Step 5: Run the suite, look, commit**

Run: `swift test 2>&1 | tail -3` — expect pass.
Run `swift run Clyde`, open Settings › General: the section reads "Off — …" before, "On, but nothing has arrived yet …" right after switching on, "Working — last update …" after a Claude Code turn. Switch off: the status line wrapper is gone from `~/.claude/settings.json`.

```bash
git add Clyde/Models/UsageLimitsStatus.swift ClydeTests/UsageLimitsStatusTests.swift Clyde/Views/SettingsView.swift
git commit -m "feat(limits): the setting, and what it is actually doing

Off says where the numbers are instead, on-but-blocked names the fault, on-but-nothing-yet says what has to happen first, and working says when the last update came. The sentence under the switch names the one visible side effect in the terminal, because that is the reason the switch is off by default."
```

---

### Task 10: Docs, changelog, roadmap, and the live check

**Files:**
- Modify: `docs/hook-smoke-test.md`
- Modify: `CHANGELOG.md`
- Modify: `ROADMAP.md`

- [ ] **Step 1: Smoke-test scenario**

Append to `docs/hook-smoke-test.md` (one paragraph or list item per line, no hard wraps):

```markdown
---

## Scenario 9 — Usage limits status line

**Goal:** the status-line wrapper installs behind an existing status line, snapshots arrive, and turning the feature off restores the terminal exactly.

**Setup:** note whether `~/.claude/settings.json` has a `statusLine` key and what its `command` is. If it has none, add a throwaway one so the passthrough path is exercised: `{"statusLine": {"type": "command", "command": "echo mine"}}`.

**Steps:**
1. `swift run Clyde`, open Settings › General, switch on "Show Claude usage limits".
2. Check `~/.claude/settings.json`: `statusLine.command` is `~/.claude/hooks/clyde-statusline.sh`; `~/.clyde/usage/passthrough` contains the previous command.
3. Open a `claude` session on a Pro or Max login and send one prompt.
4. Check the terminal: the status line still shows what the previous command printed (`mine`).
5. Check `~/.clyde/usage/statusline.json`: it exists and contains `rate_limits`.
6. In Clyde, open the full panel: the Limits band sits above Activity with both meters. Click it: two rows and an "Updated … from the … session" line. Switch to compact: a `5h` meter beside Expand.
7. Switch the setting off. `~/.claude/settings.json` has the previous `statusLine` back (or none if there was none); the wrapper script and `~/.clyde/usage/` are gone; the band and the meter are gone.

**Expect:** no "status line" error in the Claude Code TUI at any point; every wrapper invocation exits 0 (`~/.clyde/logs/statusline.log` stays empty).
```

- [ ] **Step 2: Changelog**

Under `## [Unreleased]` in `CHANGELOG.md`:

```markdown
### Added

- Claude usage limits in the panel: how much of the 5-hour session and the 7-day week is used and when each resets, as a Limits band above Activity in the full panel and a session meter in the compact footer. Blue from 80%, red when a window is spent, dimmed when the numbers are more than half an hour old with no session to refresh them. One notification when the session window passes 80%, one when a spent window resets. Off by default: Clyde reads the numbers from a Claude Code status line wrapper, and a configured status line hides most of the terminal footer's keyboard hints. Any status line you already had keeps running behind it and is put back when the setting is turned off. Pro and Max plans only — Claude Code reports the windows for nothing else.
```

- [ ] **Step 3: Roadmap**

In `ROADMAP.md`, tick the v0.10.0 item and replace its text with what was done:

```markdown
- [x] Limits band above Activity and a session meter in compact's footer, fed by a status-line wrapper installed behind the user's own status line and restored on uninstall. Opt-in, offered once by chip. Two notifications: 80% of the session window, and its reset after exhaustion. Spec: `docs/superpowers/specs/2026-09-10-usage-limits-design.md` !hi #ux #hooks
```

Add, as a fresh line in the same phase, the follow-up the spec names as a risk:

```markdown
- [ ] Live for a working day on a Max plan before release: do the numbers track `/usage`, does the 80% notification land once and not on every turn, what does the terminal look like to someone who had no status line before. The last of those decides whether the toggle stays off by default !hi #qa
```

- [ ] **Step 4: Commit**

```bash
git add docs/hook-smoke-test.md CHANGELOG.md ROADMAP.md
git commit -m "docs(limits): smoke-test scenario, changelog entry, roadmap tick

The scenario exercises the passthrough path on purpose: a wrapper that silently swallows the user's own status line is the failure worth catching by hand. The roadmap keeps the day-long live check as its own line, because that is what decides the toggle's default."
```

- [ ] **Step 5: The live day**

Not a commit. Per the spec's verification section and the project's "verify live, not just with tests" rule: keep the feature on for a working day on the Max account, with `/usage` as the reference. Note in the roadmap follow-up whatever disagrees.

---

## Self-review

**Spec coverage.** Data source and installer → Tasks 2–3. Model, expiry, staleness, levels → Task 1. Store → Task 4. Full panel band, expanded rows, freshness line, remembered open state → Task 6. Compact session-only meter with the crowding rule → Task 7. Widget unchanged → no task, by design. Colour and thresholds → `UsageMeter.color(for:)` in Task 6 and `UsageLimits.level` in Task 1. Notifications → Task 8. Settings toggle, three-state status, uninstall restoring the user's command → Tasks 3, 5, 9. Opt-in with a one-time advisory → Task 5. Verification (unit, smoke, live) → every task's step 4 plus Task 10.

**Placeholders.** None: every code step is complete. The only conditional instruction is Task 5 step 1's note on driving `ProcessMonitor.sessions`, which names the alternative route (`ProcessMonitorTests`' `-error` file pattern).

**Type consistency.** `UsageLimits.level(for:rateLimited:)`, `percentText(for:level:)`, `resetText(for:now:level:)`, `freshnessText(now:sessionName:stale:)` are used with those exact labels in Tasks 6, 7 and 8. `UsageLimitsInstaller.settingKey`, `offerDismissedKey`, `offerOverride`, `shouldOffer(defaults:)`, `Issue.message` match between Tasks 3, 5 and 9. `AppViewModel.usageLimits`, `hasRateLimitedSession`, `usageIsStale`, `usageSessionName(for:)`, `usageInstallError`, `showUsageLimits` match between Tasks 5, 6, 7 and 9. `UsageMeter(label:window:level:stale:barWidth:)` matches Tasks 6 and 7.
