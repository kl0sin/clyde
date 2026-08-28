# Session Review Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give Clyde a durable, local history of hook events and a review window that answers where the day went, how long sessions waited on the human, and what Claude actually did.

**Architecture:** The hook appends one JSON line per event to a spool file. Clyde claims the spool by renaming it, ingests it into SQLite inside a single transaction, and deletes it. All statistics are window queries over the event table — nothing is pre-aggregated. A dedicated review window reads the store; the panel is untouched.

**Tech Stack:** Swift, SwiftUI, system `libsqlite3` via `import SQLite3`, XCTest.

**Spec:** `docs/superpowers/specs/2026-08-28-session-review-design.md`

## Global Constraints

- macOS 13 Ventura minimum. No API newer than 13.0.
- **No new package dependencies.** The repo has exactly one (Sparkle). SQLite comes from the system via `import SQLite3`.
- **Never store conversation content.** Only what the panel already renders: tool name, its ≤40-character summary, plan counters, subagent types, command name, worktree name, project path.
- The hook must never block and never exit non-zero. No `set -e`, always `exit 0`, every write failure ignored.
- Hook script changes require bumping `# clyde-hook-version:` **and** `HookInstaller.currentScriptVersion` to the same number.
- Files created `0600`, matching existing state markers. No network access anywhere in this feature.
- Prose markdown (CHANGELOG, ROADMAP) is not hard-wrapped — one long line per paragraph and per list item.
- Commits: conventional style, no Claude attribution or co-author trailers.
- Run `swift test` before every commit that touches Swift.

---

## File Structure

| File | Responsibility |
|---|---|
| `Clyde/Models/HistoryEvent.swift` | Value types: one stored event, and the stats structs the queries return. No behaviour. |
| `Clyde/Services/HistorySpool.swift` | Parsing a spool line into `HistoryEvent`. Pure, no file IO — so it is trivially testable. |
| `Clyde/Services/HistoryStore.swift` | Owns the SQLite handle: schema, insert, claim-and-ingest, size/count/clear. |
| `Clyde/Services/HistoryStats.swift` | Read-only queries over the store: day/week totals, per-project rows, event listing. |
| `Clyde/Views/ReviewWindow.swift` | The review UI. |
| `Clyde/Resources/clyde-hook.sh` | Appends spool lines. Bumped to v36. |
| `Clyde/Services/HookInstaller.swift` | `currentScriptVersion` → 36. |
| `Clyde/App/AppDelegate.swift` | Ingestion schedule + menu entry that opens the window. |
| `Clyde/Views/SettingsView.swift` | History size, event count, oldest date, "Clear history". |
| `ClydeTests/HistoryStoreTests.swift` | Ingestion, crash recovery, malformed input, clearing. |
| `ClydeTests/HistoryStatsTests.swift` | The arithmetic: working time, waiting time, turns, per-project grouping. |
| `ClydeTests/HookScriptTests.swift` | Spool lines appear with the right fields; existing markers unaffected. |

`HistoryStore` and `HistoryStats` are split deliberately: writing is about file handover and transactions, reading is about SQL over a stable schema. They fail for different reasons and are read by different people.

---

### Task 1: Hook writes the spool

**Files:**
- Modify: `Clyde/Resources/clyde-hook.sh`
- Modify: `Clyde/Services/HookInstaller.swift` (`currentScriptVersion`)
- Test: `ClydeTests/HookScriptTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `~/.clyde/history/spool.jsonl`, one JSON object per line with keys `ts` (integer, epoch seconds), `event`, `session_id`, `cwd`, and optionally `tool`, `summary`, `agent_type`, `command`, `worktree`, `stop_reason`.

- [ ] **Step 1: Write the failing tests**

Add to `ClydeTests/HookScriptTests.swift`:

```swift
    // MARK: - History spool

    private func spoolLines(in home: URL) -> [[String: Any]] {
        let url = home.appendingPathComponent(".clyde/history/spool.jsonl")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap {
            guard let data = $0.data(using: .utf8) else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
    }

    func testSpoolRecordsAToolCallWithItsSummary() throws {
        let home = tempHome()
        let sid = "spool-0001"

        try runHook(payload: #"{"hook_event_name":"PreToolUse","session_id":"\#(sid)","cwd":"/repo","tool_name":"Bash","tool_use_id":"toolu_s1","tool_input":{"command":"swift test"}}"#, home: home)

        let lines = spoolLines(in: home)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0]["event"] as? String, "PreToolUse")
        XCTAssertEqual(lines[0]["session_id"] as? String, sid)
        XCTAssertEqual(lines[0]["cwd"] as? String, "/repo")
        XCTAssertEqual(lines[0]["tool"] as? String, "Bash")
        XCTAssertEqual(lines[0]["summary"] as? String, "swift test")
        XCTAssertNotNil(lines[0]["ts"] as? Int)
    }

    /// Turn boundaries are what every duration in the review is computed
    /// from, so they have to land in the spool even though they write no
    /// tool summary.
    func testSpoolRecordsTurnBoundaries() throws {
        let home = tempHome()
        let sid = "spool-0002"

        try runHook(payload: #"{"hook_event_name":"UserPromptSubmit","session_id":"\#(sid)","cwd":"/repo"}"#, home: home)
        try runHook(payload: #"{"hook_event_name":"Stop","session_id":"\#(sid)","cwd":"/repo","last_assistant_message":"done"}"#, home: home)

        XCTAssertEqual(spoolLines(in: home).map { $0["event"] as? String },
                       ["UserPromptSubmit", "Stop"])
    }

    /// The spool must never carry message bodies — that decision was made
    /// in v0.7.0 and the store does not get to reopen it.
    func testSpoolNeverCarriesTheAssistantMessage() throws {
        let home = tempHome()
        let sid = "spool-0003"

        try runHook(payload: #"{"hook_event_name":"Stop","session_id":"\#(sid)","cwd":"/repo","last_assistant_message":"secret sentence"}"#, home: home)

        let text = try String(contentsOf: home.appendingPathComponent(".clyde/history/spool.jsonl"), encoding: .utf8)
        XCTAssertFalse(text.contains("secret sentence"))
    }

    /// The spool is additive: every existing marker keeps working.
    func testSpoolWritingDoesNotDisturbStateMarkers() throws {
        let home = tempHome()
        let sid = "spool-0004"

        try runHook(payload: #"{"hook_event_name":"UserPromptSubmit","session_id":"\#(sid)","cwd":"/repo"}"#, home: home)

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: home.appendingPathComponent(".clyde/state/\(sid)-busy").path))
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter Spool`
Expected: FAIL — the four spool tests report zero lines / missing file; `testSpoolWritingDoesNotDisturbStateMarkers` passes already (it guards existing behaviour).

- [ ] **Step 3: Add the spool writer to the hook**

In `Clyde/Resources/clyde-hook.sh`, change the version stamp on line 2 to `# clyde-hook-version: 36`, add `HISTORY_DIR="$HOME/.clyde/history"` next to the other directory constants near line 47, add `"$HISTORY_DIR"` to the existing `mkdir -p` on line 49, and insert this helper next to `atomic_write`:

```sh
# Append one structured line to the history spool. Deliberately a plain
# append, not an atomic-write: O_APPEND writes below the pipe buffer are
# atomic, so parallel hooks cannot interleave, and Clyde claims the file
# by renaming it rather than truncating it. Any failure is ignored — the
# spool is a convenience, the user's session is not.
spool_append() {
    local extra=$1
    printf '{"ts": %s, "event": "%s", "session_id": "%s", "cwd": "%s"%s}\n' \
        "$TIMESTAMP" "$HOOK_EVENT" "$ESC_SID" "$ESC_CWD" "$extra" \
        >>"$HISTORY_DIR/spool.jsonl" 2>/dev/null || true
}
```

Then call it once **after the main dispatch's closing `esac` (line 1140), immediately before the final `exit 0`**. That placement is deliberate: `TOOL_SUMMARY` is assigned inside the `PreToolUse` branch at line 926, so a call placed before the dispatch would spool an empty summary for every tool call. The early `exit 0` at line 567 (no `claude` ancestor in the process tree) skips the spool as well, which is correct — that path skips every other state write too.

```sh
# History spool. Built from fields already extracted above, so this adds
# no parsing work. Note what is absent: last_assistant_message never
# reaches the spool — the -lastmsg marker is a live preview, not history.
SPOOL_EXTRA=""
if [ -n "$TOOL_NAME" ]; then
    ESC_TOOL=$(printf '%s' "$TOOL_NAME" | sed 's/\\/\\\\/g; s/"/\\"/g')
    SPOOL_EXTRA="$SPOOL_EXTRA, \"tool\": \"$ESC_TOOL\""
fi
if [ -n "${TOOL_SUMMARY:-}" ]; then
    # Escape freshly rather than reusing ESC_SUMMARY: that variable is
    # reassigned at line 948 to carry an Agent's description, so by the end
    # of the dispatch it may not be this tool's summary at all.
    ESC_TSUM=$(printf '%s' "$TOOL_SUMMARY" | sed 's/\\/\\\\/g; s/"/\\"/g')
    SPOOL_EXTRA="$SPOOL_EXTRA, \"summary\": \"$ESC_TSUM\""
fi
spool_append "$SPOOL_EXTRA"
```

Do not call `compute_tool_summary` again in this block — it is already computed once in the `PreToolUse` branch, and that helper shells out to python3.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter Spool`
Expected: PASS, 4 tests.

- [ ] **Step 5: Bump the installer's version constant**

In `Clyde/Services/HookInstaller.swift`, change `static let currentScriptVersion = 35` to `36`.

- [ ] **Step 6: Run the full suite**

Run: `swift test`
Expected: PASS, no regressions.

- [ ] **Step 7: Commit**

```bash
git add Clyde/Resources/clyde-hook.sh Clyde/Services/HookInstaller.swift ClydeTests/HookScriptTests.swift
git commit -m "feat(hooks): spool every event for the session history"
```

---

### Task 2: Event model and spool parsing

**Files:**
- Create: `Clyde/Models/HistoryEvent.swift`
- Create: `Clyde/Services/HistorySpool.swift`
- Test: `ClydeTests/HistoryStoreTests.swift`

**Interfaces:**
- Consumes: the spool line format from Task 1.
- Produces: `struct HistoryEvent { let ts: Date; let event: String; let sessionID: String; let project: String; let tool: String?; let summary: String? }` and `enum HistorySpool { static func parse(line: String) -> HistoryEvent? }`.

- [ ] **Step 1: Write the failing test**

Create `ClydeTests/HistoryStoreTests.swift`:

```swift
import XCTest
@testable import Clyde

final class HistoryStoreTests: XCTestCase {

    func testParsesAToolEventLine() {
        let line = #"{"ts": 1787660000, "event": "PreToolUse", "session_id": "s1", "cwd": "/repo", "tool": "Bash", "summary": "swift test"}"#

        let event = HistorySpool.parse(line: line)

        XCTAssertEqual(event?.event, "PreToolUse")
        XCTAssertEqual(event?.sessionID, "s1")
        XCTAssertEqual(event?.project, "/repo")
        XCTAssertEqual(event?.tool, "Bash")
        XCTAssertEqual(event?.summary, "swift test")
        XCTAssertEqual(event?.ts, Date(timeIntervalSince1970: 1787660000))
    }

    /// A shell-written file can always be cut mid-line by a full disk, so
    /// a broken line must be a skipped line, never a thrown error.
    func testReturnsNilForATruncatedLine() {
        XCTAssertNil(HistorySpool.parse(line: #"{"ts": 178766000"#))
        XCTAssertNil(HistorySpool.parse(line: ""))
    }

    /// Missing optional fields are normal: turn boundaries carry no tool.
    func testParsesAnEventWithoutToolFields() {
        let line = #"{"ts": 1787660000, "event": "Stop", "session_id": "s1", "cwd": "/repo"}"#

        let event = HistorySpool.parse(line: line)

        XCTAssertEqual(event?.event, "Stop")
        XCTAssertNil(event?.tool)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter HistoryStoreTests`
Expected: FAIL to compile — `HistorySpool` and `HistoryEvent` do not exist.

- [ ] **Step 3: Write the model and parser**

Create `Clyde/Models/HistoryEvent.swift`:

```swift
import Foundation

/// One hook event as persisted in the history store. Deliberately carries
/// only what the panel already renders — never message content.
struct HistoryEvent: Equatable {
    let ts: Date
    let event: String
    let sessionID: String
    /// The session's cwd at the time. Grouping key for the per-project view.
    let project: String
    let tool: String?
    let summary: String?
}
```

Create `Clyde/Services/HistorySpool.swift`:

```swift
import Foundation

/// Parsing for the hook's spool format. Pure by design: the file handover
/// lives in HistoryStore, so the format itself can be tested without touching
/// the filesystem.
enum HistorySpool {
    static func parse(line: String) -> HistoryEvent? {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ts = json["ts"] as? Int,
              let event = json["event"] as? String,
              let sessionID = json["session_id"] as? String else { return nil }

        return HistoryEvent(
            ts: Date(timeIntervalSince1970: TimeInterval(ts)),
            event: event,
            sessionID: sessionID,
            project: (json["cwd"] as? String) ?? "",
            tool: json["tool"] as? String,
            summary: json["summary"] as? String
        )
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter HistoryStoreTests`
Expected: PASS, 3 tests.

- [ ] **Step 5: Commit**

```bash
git add Clyde/Models/HistoryEvent.swift Clyde/Services/HistorySpool.swift ClydeTests/HistoryStoreTests.swift
git commit -m "feat(history): event model and spool line parsing"
```

---

### Task 3: The store — schema and inserts

**Files:**
- Create: `Clyde/Services/HistoryStore.swift`
- Test: `ClydeTests/HistoryStoreTests.swift`

**Interfaces:**
- Consumes: `HistoryEvent` from Task 2.
- Produces: `final class HistoryStore` with `init(directory: URL) throws`, `func insert(_ events: [HistoryEvent]) throws`, `func eventCount() -> Int`, `func oldestEventDate() -> Date?`, `func databaseSizeBytes() -> Int64`, `func clear() throws`, and `var databaseURL: URL`.

- [ ] **Step 1: Write the failing test**

Append to `ClydeTests/HistoryStoreTests.swift`:

```swift
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clyde-history-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func event(_ name: String, at seconds: Int, session: String = "s1",
                       project: String = "/repo", tool: String? = nil) -> HistoryEvent {
        HistoryEvent(ts: Date(timeIntervalSince1970: TimeInterval(seconds)), event: name,
                     sessionID: session, project: project, tool: tool, summary: nil)
    }

    func testInsertedEventsAreCounted() throws {
        let store = try HistoryStore(directory: tempDir())

        try store.insert([event("UserPromptSubmit", at: 100), event("Stop", at: 160)])

        XCTAssertEqual(store.eventCount(), 2)
        XCTAssertEqual(store.oldestEventDate(), Date(timeIntervalSince1970: 100))
    }

    func testStoreReopensExistingDatabase() throws {
        let dir = tempDir()
        let first = try HistoryStore(directory: dir)
        try first.insert([event("Stop", at: 100)])

        let second = try HistoryStore(directory: dir)

        XCTAssertEqual(second.eventCount(), 1)
    }

    func testClearEmptiesTheStore() throws {
        let store = try HistoryStore(directory: tempDir())
        try store.insert([event("Stop", at: 100)])

        try store.clear()

        XCTAssertEqual(store.eventCount(), 0)
        XCTAssertNil(store.oldestEventDate())
    }

    /// Retention is manual, so Settings has to be able to show what the
    /// history is costing. A store with rows must report a non-zero size.
    func testDatabaseSizeIsReported() throws {
        let store = try HistoryStore(directory: tempDir())
        try store.insert([event("Stop", at: 100)])

        XCTAssertGreaterThan(store.databaseSizeBytes(), 0)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter HistoryStoreTests`
Expected: FAIL to compile — `HistoryStore` does not exist.

- [ ] **Step 3: Write the store**

Create `Clyde/Services/HistoryStore.swift`:

```swift
import Foundation
import SQLite3

/// Durable, local history of hook events. Backed by the system SQLite —
/// no package dependency, and the schema is two tables.
///
/// Retention is deliberately unbounded (the user clears it by hand), which
/// is exactly why this is an indexed database rather than a flat file: a
/// day view must not re-read a year of events every time it opens.
final class HistoryStore {

    enum StoreError: Error {
        case openFailed(String)
        case statementFailed(String)
    }

    private var db: OpaquePointer?
    let databaseURL: URL

    init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        databaseURL = directory.appendingPathComponent("history.sqlite")

        guard sqlite3_open(databaseURL.path, &db) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(db)
            db = nil
            throw StoreError.openFailed(message)
        }

        // Same posture as the state markers: readable by this user only.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: databaseURL.path)
        try exec("""
            CREATE TABLE IF NOT EXISTS events (
              id INTEGER PRIMARY KEY,
              ts INTEGER NOT NULL,
              event TEXT NOT NULL,
              session_id TEXT NOT NULL,
              project TEXT NOT NULL,
              tool TEXT,
              summary TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_events_ts ON events(ts);
            CREATE INDEX IF NOT EXISTS idx_events_project_ts ON events(project, ts);
            CREATE TABLE IF NOT EXISTS ingested_files (
              name TEXT PRIMARY KEY,
              ingested_at INTEGER NOT NULL
            );
            """)
    }

    deinit { sqlite3_close(db) }

    func insert(_ events: [HistoryEvent]) throws {
        guard !events.isEmpty else { return }
        try exec("BEGIN")
        do {
            try insertWithinTransaction(events)
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Insert without opening a transaction — used by the ingest path,
    /// which needs the events and the claimed filename to commit together.
    func insertWithinTransaction(_ events: [HistoryEvent]) throws {
        var stmt: OpaquePointer?
        let sql = "INSERT INTO events (ts, event, session_id, project, tool, summary) VALUES (?,?,?,?,?,?)"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.statementFailed(lastError())
        }
        defer { sqlite3_finalize(stmt) }

        for event in events {
            sqlite3_reset(stmt)
            sqlite3_bind_int64(stmt, 1, Int64(event.ts.timeIntervalSince1970))
            bindText(stmt, 2, event.event)
            bindText(stmt, 3, event.sessionID)
            bindText(stmt, 4, event.project)
            if let tool = event.tool { bindText(stmt, 5, tool) } else { sqlite3_bind_null(stmt, 5) }
            if let summary = event.summary { bindText(stmt, 6, summary) } else { sqlite3_bind_null(stmt, 6) }
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw StoreError.statementFailed(lastError())
            }
        }
    }

    func eventCount() -> Int {
        scalarInt("SELECT COUNT(*) FROM events") ?? 0
    }

    func oldestEventDate() -> Date? {
        guard let ts = scalarInt("SELECT MIN(ts) FROM events"), ts > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(ts))
    }

    func databaseSizeBytes() -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: databaseURL.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }

    func clear() throws {
        try exec("DELETE FROM events; DELETE FROM ingested_files; VACUUM;")
    }

    // MARK: - Internals shared with HistoryStats

    func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw StoreError.statementFailed(lastError())
        }
    }

    func scalarInt(_ sql: String) -> Int? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    func handle() -> OpaquePointer? { db }

    private func lastError() -> String {
        db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
    }

    private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        // SQLITE_TRANSIENT: SQLite copies the bytes, so the Swift string
        // is free to die before the statement runs.
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, index, value, -1, transient)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter HistoryStoreTests`
Expected: PASS, 7 tests.

- [ ] **Step 5: Commit**

```bash
git add Clyde/Services/HistoryStore.swift ClydeTests/HistoryStoreTests.swift
git commit -m "feat(history): sqlite-backed event store"
```

---

### Task 4: Claim-and-ingest with crash recovery

**Files:**
- Modify: `Clyde/Services/HistoryStore.swift`
- Test: `ClydeTests/HistoryStoreTests.swift`

**Interfaces:**
- Consumes: `HistoryStore` from Task 3, `HistorySpool.parse` from Task 2.
- Produces: `@discardableResult func ingestPending() -> Int` on `HistoryStore`, returning the number of events ingested. Reads `<directory>/spool.jsonl` and any leftover `<directory>/spool.*.ingesting`.

- [ ] **Step 1: Write the failing test**

Append to `ClydeTests/HistoryStoreTests.swift`:

```swift
    private func writeSpool(_ lines: [String], in dir: URL, named name: String = "spool.jsonl") {
        let text = lines.joined(separator: "\n") + "\n"
        try? text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func spoolLine(_ event: String, ts: Int) -> String {
        #"{"ts": \#(ts), "event": "\#(event)", "session_id": "s1", "cwd": "/repo"}"#
    }

    func testIngestMovesSpoolEventsIntoTheStore() throws {
        let dir = tempDir()
        writeSpool([spoolLine("UserPromptSubmit", ts: 100), spoolLine("Stop", ts: 160)], in: dir)
        let store = try HistoryStore(directory: dir)

        let count = store.ingestPending()

        XCTAssertEqual(count, 2)
        XCTAssertEqual(store.eventCount(), 2)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("spool.jsonl").path),
            "the claimed spool must be gone so the hook starts a fresh one")
    }

    func testIngestSkipsMalformedLinesAndKeepsTheRest() throws {
        let dir = tempDir()
        writeSpool([spoolLine("Stop", ts: 100), #"{"ts": 1787"#, spoolLine("Stop", ts: 200)], in: dir)
        let store = try HistoryStore(directory: dir)

        XCTAssertEqual(store.ingestPending(), 2)
    }

    /// The important one. A crash between COMMIT and unlink leaves the
    /// claimed file on disk; re-ingesting it would double every duration
    /// in the review with no way for the user to guess why.
    func testLeftoverClaimedFileIsNotIngestedTwice() throws {
        let dir = tempDir()
        writeSpool([spoolLine("Stop", ts: 100)], in: dir)
        let store = try HistoryStore(directory: dir)
        store.ingestPending()

        // Simulate the crash: put the claimed file back under a name the
        // store has already recorded as ingested.
        let claimed = try XCTUnwrap(store.lastClaimedFileName)
        writeSpool([spoolLine("Stop", ts: 100)], in: dir, named: claimed)

        let secondPass = store.ingestPending()

        XCTAssertEqual(secondPass, 0)
        XCTAssertEqual(store.eventCount(), 1)
    }

    func testIngestWithNoSpoolIsANoOp() throws {
        let store = try HistoryStore(directory: tempDir())

        XCTAssertEqual(store.ingestPending(), 0)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter HistoryStoreTests`
Expected: FAIL to compile — `ingestPending()` and `lastClaimedFileName` do not exist.

- [ ] **Step 3: Implement claim-and-ingest**

Add to `HistoryStore`:

```swift
    /// Name of the most recently claimed spool file. Exposed for tests that
    /// need to reconstruct the crash-between-commit-and-unlink window.
    private(set) var lastClaimedFileName: String?

    /// Drain the spool into the database.
    ///
    /// The spool is *claimed* by renaming rather than read in place: the
    /// rename is atomic, so the hook's next append transparently creates a
    /// fresh spool and never notices the handover. Reading in place would
    /// mean truncating a file another process is appending to, and with
    /// parallel hooks that race fires sooner rather than later.
    @discardableResult
    func ingestPending() -> Int {
        let directory = databaseURL.deletingLastPathComponent()
        var total = 0

        // Leftovers first: a claimed file still on disk means a previous
        // run died before unlinking it.
        let leftovers = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasPrefix("spool.") && $0.hasSuffix(".ingesting") }
            .sorted()
        for name in leftovers {
            total += ingestClaimed(named: name, in: directory)
        }

        let spool = directory.appendingPathComponent("spool.jsonl")
        guard FileManager.default.fileExists(atPath: spool.path) else { return total }

        let claimedName = "spool.\(Int(Date().timeIntervalSince1970)).\(UUID().uuidString.prefix(8)).ingesting"
        do {
            try FileManager.default.moveItem(at: spool, to: directory.appendingPathComponent(claimedName))
        } catch {
            ClydeLog.general.error("History: could not claim spool: \(error.localizedDescription, privacy: .public)")
            return total
        }
        lastClaimedFileName = claimedName
        total += ingestClaimed(named: claimedName, in: directory)
        return total
    }

    private func ingestClaimed(named name: String, in directory: URL) -> Int {
        let url = directory.appendingPathComponent(name)

        if alreadyIngested(name) {
            try? FileManager.default.removeItem(at: url)
            return 0
        }

        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            ClydeLog.general.error("History: unreadable claimed spool \(name, privacy: .public)")
            return 0
        }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        let events = lines.compactMap { HistorySpool.parse(line: String($0)) }
        let skipped = lines.count - events.count
        if skipped > 0 {
            ClydeLog.general.info("History: skipped \(skipped, privacy: .public) malformed spool line(s)")
        }

        do {
            try exec("BEGIN")
            try insertWithinTransaction(events)
            try markIngested(name)
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            ClydeLog.general.error("History: ingest failed, spool kept: \(error.localizedDescription, privacy: .public)")
            return 0
        }

        try? FileManager.default.removeItem(at: url)
        return events.count
    }

    private func alreadyIngested(_ name: String) -> Bool {
        let escaped = name.replacingOccurrences(of: "'", with: "''")
        return (scalarInt("SELECT COUNT(*) FROM ingested_files WHERE name = '\(escaped)'") ?? 0) > 0
    }

    private func markIngested(_ name: String) throws {
        let escaped = name.replacingOccurrences(of: "'", with: "''")
        try exec("INSERT INTO ingested_files (name, ingested_at) VALUES ('\(escaped)', \(Int(Date().timeIntervalSince1970)))")
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter HistoryStoreTests`
Expected: PASS, 11 tests.

- [ ] **Step 5: Commit**

```bash
git add Clyde/Services/HistoryStore.swift ClydeTests/HistoryStoreTests.swift
git commit -m "feat(history): claim-and-drain ingestion with crash recovery"
```

---

### Task 5: The statistics queries

**Files:**
- Create: `Clyde/Services/HistoryStats.swift`
- Modify: `Clyde/Models/HistoryEvent.swift` (add the result structs)
- Test: `ClydeTests/HistoryStatsTests.swift`

**Interfaces:**
- Consumes: `HistoryStore` from Tasks 3–4.
- Produces: `struct PeriodTotals { let workingSeconds: Int; let waitingSeconds: Int; let turns: Int; let sessions: Int }`, `struct ProjectRow { let project: String; let workingSeconds: Int; let turns: Int; let topTool: String? }`, and `final class HistoryStats { init(store: HistoryStore); func totals(from: Date, to: Date) -> PeriodTotals; func projects(from: Date, to: Date) -> [ProjectRow] }`.

Durations come from consecutive turn boundaries within one session: `UserPromptSubmit → Stop` is working time, `Stop → the next UserPromptSubmit` is waiting time. An unterminated turn (no `Stop` yet) contributes nothing rather than counting to now, so refreshing the window cannot inflate yesterday.

- [ ] **Step 1: Write the failing test**

Create `ClydeTests/HistoryStatsTests.swift`:

```swift
import XCTest
@testable import Clyde

final class HistoryStatsTests: XCTestCase {

    private func makeStore() throws -> HistoryStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clyde-stats-\(UUID().uuidString)")
        return try HistoryStore(directory: dir)
    }

    private func event(_ name: String, at seconds: Int, session: String = "s1",
                       project: String = "/repo", tool: String? = nil) -> HistoryEvent {
        HistoryEvent(ts: Date(timeIntervalSince1970: TimeInterval(seconds)), event: name,
                     sessionID: session, project: project, tool: tool, summary: nil)
    }

    private let wholeRange = (from: Date(timeIntervalSince1970: 0),
                              to: Date(timeIntervalSince1970: 10_000))

    func testWorkingTimeIsTheSumOfPromptToStop() throws {
        let store = try makeStore()
        try store.insert([
            event("UserPromptSubmit", at: 100), event("Stop", at: 160),
            event("UserPromptSubmit", at: 300), event("Stop", at: 330),
        ])

        let totals = HistoryStats(store: store).totals(from: wholeRange.from, to: wholeRange.to)

        XCTAssertEqual(totals.workingSeconds, 90)
        XCTAssertEqual(totals.turns, 2)
    }

    func testWaitingTimeIsTheGapBetweenStopAndTheNextPrompt() throws {
        let store = try makeStore()
        try store.insert([
            event("UserPromptSubmit", at: 100), event("Stop", at: 160),
            event("UserPromptSubmit", at: 300), event("Stop", at: 330),
        ])

        let totals = HistoryStats(store: store).totals(from: wholeRange.from, to: wholeRange.to)

        XCTAssertEqual(totals.waitingSeconds, 140)
    }

    /// A turn still running when the window is opened must contribute
    /// nothing, or simply refreshing the view would grow yesterday's total.
    func testUnfinishedTurnContributesNoWorkingTime() throws {
        let store = try makeStore()
        try store.insert([event("UserPromptSubmit", at: 100)])

        let totals = HistoryStats(store: store).totals(from: wholeRange.from, to: wholeRange.to)

        XCTAssertEqual(totals.workingSeconds, 0)
        XCTAssertEqual(totals.turns, 1)
    }

    /// An interrupted turn followed by a fresh prompt leaves two
    /// `UserPromptSubmit` events in a row. Pairing them would bill the time
    /// the human spent typing as time Claude spent working.
    func testTwoPromptsInARowAreNotCountedAsWorkingTime() throws {
        let store = try makeStore()
        try store.insert([
            event("UserPromptSubmit", at: 100),
            event("UserPromptSubmit", at: 400),
            event("Stop", at: 430),
        ])

        let totals = HistoryStats(store: store).totals(from: wholeRange.from, to: wholeRange.to)

        XCTAssertEqual(totals.workingSeconds, 30)
        XCTAssertEqual(totals.turns, 2)
    }

    /// Two sessions interleaved in time must not pair across each other.
    func testTurnsArePairedWithinASessionNotAcrossSessions() throws {
        let store = try makeStore()
        try store.insert([
            event("UserPromptSubmit", at: 100, session: "a"),
            event("UserPromptSubmit", at: 110, session: "b"),
            event("Stop", at: 200, session: "a"),
            event("Stop", at: 210, session: "b"),
        ])

        let totals = HistoryStats(store: store).totals(from: wholeRange.from, to: wholeRange.to)

        XCTAssertEqual(totals.workingSeconds, 200)
        XCTAssertEqual(totals.sessions, 2)
    }

    func testProjectRowsSplitTimeAndNameTheTopTool() throws {
        let store = try makeStore()
        try store.insert([
            event("UserPromptSubmit", at: 100, project: "/a"), event("Stop", at: 160, project: "/a"),
            event("PreToolUse", at: 120, project: "/a", tool: "Bash"),
            event("PreToolUse", at: 130, project: "/a", tool: "Bash"),
            event("PreToolUse", at: 140, project: "/a", tool: "Read"),
            event("UserPromptSubmit", at: 400, session: "s2", project: "/b"),
            event("Stop", at: 410, session: "s2", project: "/b"),
        ])

        let rows = HistoryStats(store: store).projects(from: wholeRange.from, to: wholeRange.to)

        XCTAssertEqual(rows.map(\.project), ["/a", "/b"], "busiest project first")
        XCTAssertEqual(rows[0].workingSeconds, 60)
        XCTAssertEqual(rows[0].topTool, "Bash")
        XCTAssertEqual(rows[1].workingSeconds, 10)
    }

    func testRangeExcludesEventsOutsideIt() throws {
        let store = try makeStore()
        try store.insert([
            event("UserPromptSubmit", at: 100), event("Stop", at: 160),
            event("UserPromptSubmit", at: 5000), event("Stop", at: 5100),
        ])

        let totals = HistoryStats(store: store)
            .totals(from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 1000))

        XCTAssertEqual(totals.turns, 1)
        XCTAssertEqual(totals.workingSeconds, 60)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter HistoryStatsTests`
Expected: FAIL to compile — `HistoryStats`, `PeriodTotals`, `ProjectRow` do not exist.

- [ ] **Step 3: Write the query layer**

Append to `Clyde/Models/HistoryEvent.swift`:

```swift
/// Totals for one period, computed on read. Nothing is pre-aggregated —
/// storing answers instead of facts would mean guessing today which
/// questions get asked later.
struct PeriodTotals: Equatable {
    let workingSeconds: Int
    let waitingSeconds: Int
    let turns: Int
    let sessions: Int
}

struct ProjectRow: Equatable {
    let project: String
    let workingSeconds: Int
    let turns: Int
    let topTool: String?
}
```

Create `Clyde/Services/HistoryStats.swift`:

```swift
import Foundation
import SQLite3

/// Read-only queries over `HistoryStore`.
///
/// Durations are derived from turn boundaries: within one session,
/// `UserPromptSubmit → Stop` is time Claude spent working and
/// `Stop → next UserPromptSubmit` is time the session spent waiting on the
/// human. A turn with no `Stop` yet contributes nothing, so refreshing the
/// window cannot inflate a finished day.
final class HistoryStats {
    private let store: HistoryStore

    init(store: HistoryStore) {
        self.store = store
    }

    func totals(from: Date, to: Date) -> PeriodTotals {
        let turns = rows(
            """
            SELECT SUM(dt), COUNT(*) FROM (
              SELECT LEAD(ts) OVER (PARTITION BY session_id ORDER BY ts) - ts AS dt, event,
                     LEAD(event) OVER (PARTITION BY session_id ORDER BY ts) AS next_event
              FROM events WHERE ts >= \(epoch(from)) AND ts < \(epoch(to))
                AND event IN ('UserPromptSubmit','Stop')
            ) WHERE event = 'UserPromptSubmit' AND next_event = 'Stop' AND dt IS NOT NULL
            """)
        let waits = rows(
            """
            SELECT SUM(dt) FROM (
              SELECT LEAD(ts) OVER (PARTITION BY session_id ORDER BY ts) - ts AS dt, event,
                     LEAD(event) OVER (PARTITION BY session_id ORDER BY ts) AS next_event
              FROM events WHERE ts >= \(epoch(from)) AND ts < \(epoch(to))
                AND event IN ('UserPromptSubmit','Stop')
            ) WHERE event = 'Stop' AND next_event = 'UserPromptSubmit' AND dt IS NOT NULL
            """)
        let promptCount = store.scalarInt(
            "SELECT COUNT(*) FROM events WHERE event = 'UserPromptSubmit' AND ts >= \(epoch(from)) AND ts < \(epoch(to))") ?? 0
        let sessionCount = store.scalarInt(
            "SELECT COUNT(DISTINCT session_id) FROM events WHERE ts >= \(epoch(from)) AND ts < \(epoch(to))") ?? 0

        return PeriodTotals(
            workingSeconds: turns.first?.first.flatMap { Int($0) } ?? 0,
            waitingSeconds: waits.first?.first.flatMap { Int($0) } ?? 0,
            turns: promptCount,
            sessions: sessionCount
        )
    }

    func projects(from: Date, to: Date) -> [ProjectRow] {
        var result: [ProjectRow] = []
        var stmt: OpaquePointer?
        let sql = """
            SELECT project, SUM(dt) AS worked, COUNT(*) AS turns FROM (
              SELECT project, session_id, event,
                     LEAD(ts) OVER (PARTITION BY session_id ORDER BY ts) - ts AS dt,
                     LEAD(event) OVER (PARTITION BY session_id ORDER BY ts) AS next_event
              FROM events WHERE ts >= \(epoch(from)) AND ts < \(epoch(to))
                AND event IN ('UserPromptSubmit','Stop')
            ) WHERE event = 'UserPromptSubmit' AND next_event = 'Stop' AND dt IS NOT NULL
            GROUP BY project ORDER BY worked DESC
            """
        guard sqlite3_prepare_v2(store.handle(), sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            let project = String(cString: sqlite3_column_text(stmt, 0))
            result.append(ProjectRow(
                project: project,
                workingSeconds: Int(sqlite3_column_int64(stmt, 1)),
                turns: Int(sqlite3_column_int64(stmt, 2)),
                topTool: topTool(project: project, from: from, to: to)
            ))
        }
        return result
    }

    private func topTool(project: String, from: Date, to: Date) -> String? {
        var stmt: OpaquePointer?
        let escaped = project.replacingOccurrences(of: "'", with: "''")
        let sql = """
            SELECT tool FROM events
            WHERE tool IS NOT NULL AND project = '\(escaped)'
              AND ts >= \(epoch(from)) AND ts < \(epoch(to))
            GROUP BY tool ORDER BY COUNT(*) DESC, tool ASC LIMIT 1
            """
        guard sqlite3_prepare_v2(store.handle(), sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW, let text = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: text)
    }

    private func epoch(_ date: Date) -> Int { Int(date.timeIntervalSince1970) }

    private func rows(_ sql: String) -> [[Int64?]] {
        var out: [[Int64?]] = []
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(store.handle(), sql, -1, &stmt, nil) == SQLITE_OK else { return out }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: [Int64?] = []
            for column in 0..<sqlite3_column_count(stmt) {
                row.append(sqlite3_column_type(stmt, column) == SQLITE_NULL
                           ? nil : sqlite3_column_int64(stmt, column))
            }
            out.append(row)
        }
        return out
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter HistoryStatsTests`
Expected: PASS, 7 tests.

- [ ] **Step 5: Commit**

```bash
git add Clyde/Models/HistoryEvent.swift Clyde/Services/HistoryStats.swift ClydeTests/HistoryStatsTests.swift
git commit -m "feat(history): working, waiting and per-project queries"
```

---

### Task 6: Ingestion schedule

**Files:**
- Modify: `Clyde/App/AppDelegate.swift`
- Modify: `Clyde/Services/AppPaths.swift` (history directory)

**Interfaces:**
- Consumes: `HistoryStore.ingestPending()`.
- Produces: `AppPaths.historyDir`, and a `historyStore` property on `AppDelegate` that later tasks read.

- [ ] **Step 1: Add the path**

In `Clyde/Services/AppPaths.swift`, beside `stateDir`:

```swift
    /// Durable session history: the hook's spool plus Clyde's SQLite store.
    static var historyDir: URL {
        clydeDir.appendingPathComponent("history")
    }
```

- [ ] **Step 2: Wire the store and its schedule**

In `AppDelegate`, next to the other stored properties:

```swift
    private(set) var historyStore: HistoryStore?
    private var historyIngestTimer: Timer?
```

In `applicationDidFinishLaunching`, after the monitors are constructed:

```swift
        // History is best-effort: if the store cannot be opened, Clyde
        // carries on with tracking and the review window reports itself
        // unavailable. Session tracking must never break because of a
        // statistics feature.
        do {
            let store = try HistoryStore(directory: AppPaths.historyDir)
            historyStore = store
            DispatchQueue.global(qos: .utility).async { store.ingestPending() }
            // 30s, not the 3s poll: the review needs no second-level
            // freshness, and writing to the database that often is work
            // with no reader.
            let timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
                DispatchQueue.global(qos: .utility).async { store.ingestPending() }
            }
            historyIngestTimer = timer
        } catch {
            ClydeLog.general.error("History disabled: \(error.localizedDescription, privacy: .public)")
        }
```

In `applicationWillTerminate` (add the method if absent):

```swift
        historyIngestTimer?.invalidate()
        historyStore?.ingestPending()
```

- [ ] **Step 3: Build and run the suite**

Run: `swift build && swift test`
Expected: PASS, no regressions.

- [ ] **Step 4: Verify live**

```bash
./scripts/build-app.sh debug
mkdir -p .build/debug/Clyde.app/Contents/Frameworks
cp -R .build/arm64-apple-macosx/debug/Sparkle.framework .build/debug/Clyde.app/Contents/Frameworks/
install_name_tool -add_rpath @executable_path/../Frameworks .build/debug/Clyde.app/Contents/MacOS/Clyde
codesign --force --deep -s - .build/debug/Clyde.app
cp Clyde/Resources/clyde-hook.sh ~/.claude/hooks/clyde-hook.sh
open .build/debug/Clyde.app
# Run a real Claude session, then:
wc -l ~/.clyde/history/spool.jsonl        # grows while the session works
sleep 35
sqlite3 ~/.clyde/history/history.sqlite "SELECT COUNT(*), MIN(ts), MAX(ts) FROM events;"
ls ~/.clyde/history/                       # spool consumed, no .ingesting left behind
```

Expected: the spool grows, the count in the database matches the lines that were in it, and no `.ingesting` file survives. Note the count — Task 8 reconciles the window against it.

- [ ] **Step 5: Commit**

```bash
git add Clyde/App/AppDelegate.swift Clyde/Services/AppPaths.swift
git commit -m "feat(history): ingest the spool on launch, on a timer and on quit"
```

---

### Task 7: Review window

**Files:**
- Create: `Clyde/Views/ReviewWindow.swift`
- Modify: `Clyde/App/AppDelegate.swift` (menu entry + window management)

**Interfaces:**
- Consumes: `HistoryStats`, `PeriodTotals`, `ProjectRow`, `AppDelegate.historyStore`.
- Produces: `struct ReviewView: View` and `AppDelegate.openReview()`.

- [ ] **Step 1: Write the view**

Create `Clyde/Views/ReviewWindow.swift`:

```swift
import SwiftUI

/// The review surface. A dedicated window rather than part of the panel:
/// the panel is 400×420 and built for glancing mid-task, while a review is
/// something you sit down and read.
struct ReviewView: View {
    let stats: HistoryStats

    enum Period: String, CaseIterable, Identifiable {
        case day = "Today", week = "This week"
        var id: String { rawValue }

        var range: (from: Date, to: Date) {
            let now = Date()
            let start = Calendar.current.startOfDay(for: now)
            switch self {
            case .day:  return (start, now)
            case .week: return (Calendar.current.date(byAdding: .day, value: -6, to: start) ?? start, now)
            }
        }
    }

    @State private var period: Period = .day

    private var totals: PeriodTotals {
        let range = period.range
        return stats.totals(from: range.from, to: range.to)
    }

    private var projects: [ProjectRow] {
        let range = period.range
        return stats.projects(from: range.from, to: range.to)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("", selection: $period) {
                ForEach(Period.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 240)

            HStack(spacing: 12) {
                tile("Working", Self.duration(totals.workingSeconds))
                tile("Waiting on you", Self.duration(totals.waitingSeconds))
                tile("Turns", "\(totals.turns)")
                tile("Sessions", "\(totals.sessions)")
            }

            Text("Projects")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(white: 0.7))

            if projects.isEmpty {
                Text("Nothing recorded for this period yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(white: 0.5))
            } else {
                ForEach(projects, id: \.project) { row in
                    HStack {
                        Text((row.project as NSString).lastPathComponent)
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                        Text(row.topTool ?? "—")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color(white: 0.55))
                        Text("\(row.turns) turns")
                            .font(.system(size: 11))
                            .foregroundStyle(Color(white: 0.55))
                            .frame(width: 70, alignment: .trailing)
                        Text(Self.duration(row.workingSeconds))
                            .font(.system(size: 12, design: .monospaced))
                            .frame(width: 70, alignment: .trailing)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\((row.project as NSString).lastPathComponent), \(row.turns) turns, \(Self.duration(row.workingSeconds)) working")
                }
            }

            Spacer()
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 420)
    }

    private func tile(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(Color(white: 0.55))
            Text(value)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.14)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }

    static func duration(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }
}
```

- [ ] **Step 2: Add the menu entry**

In `AppDelegate`, alongside the existing "Show Clyde" item, add `Session review…` calling:

```swift
    @MainActor func openReview() {
        guard let store = historyStore else {
            ClydeLog.general.info("Review requested but history is unavailable")
            return
        }
        if let existing = reviewWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let controller = NSHostingController(rootView: ReviewView(stats: HistoryStats(store: store)))
        let window = NSWindow(contentViewController: controller)
        window.title = "Session review"
        window.styleMask = [.titled, .closable, .resizable]
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        reviewWindow = window
    }
```

with `private var reviewWindow: NSWindow?` as a stored property.

- [ ] **Step 3: Build and run the suite**

Run: `swift build && swift test`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add Clyde/Views/ReviewWindow.swift Clyde/App/AppDelegate.swift
git commit -m "feat(ui): session review window"
```

---

### Task 8: Settings — size, count and clearing

**Files:**
- Modify: `Clyde/Views/SettingsView.swift`

**Interfaces:**
- Consumes: `HistoryStore.databaseSizeBytes()`, `eventCount()`, `oldestEventDate()`, `clear()`.

- [ ] **Step 1: Add the History section**

In `SettingsView`, following the existing section pattern:

```swift
    private var historySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("History")
                .font(.system(size: 12, weight: .semibold))

            // Retention is manual by design, so the cost has to be visible.
            // Cleanup the user cannot see the need for is not cleanup.
            Text(historySummary)
                .font(.system(size: 11))
                .foregroundStyle(Color(white: 0.55))

            Button("Clear history") {
                try? historyStore?.clear()
                historySummaryTick += 1
            }
        }
    }

    private var historySummary: String {
        guard let store = historyStore, store.eventCount() > 0 else {
            return "No history recorded yet."
        }
        let mb = Double(store.databaseSizeBytes()) / 1_048_576
        let size = mb < 1 ? String(format: "%.0f KB", Double(store.databaseSizeBytes()) / 1024)
                          : String(format: "%.1f MB", mb)
        let oldest = store.oldestEventDate().map {
            DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .none)
        } ?? "—"
        return "\(store.eventCount()) events, \(size), since \(oldest)."
    }
```

Add `@State private var historySummaryTick = 0` so the label refreshes after clearing, and pass the store in from wherever `SettingsView` is constructed in `AppDelegate.openSettings()`.

- [ ] **Step 2: Build and run the suite**

Run: `swift build && swift test`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add Clyde/Views/SettingsView.swift Clyde/App/AppDelegate.swift
git commit -m "feat(ui): show history size and offer to clear it"
```

---

### Task 9: Live verification and documentation

**Files:**
- Modify: `CHANGELOG.md`, `ROADMAP.md`

- [ ] **Step 1: Reconcile the window against reality**

Four times in the week before this plan, a green suite coexisted with a dead feature. The numbers get checked against hand-counted events, not against their own tests.

```bash
# after a real working session with the debug build running
sqlite3 ~/.clyde/history/history.sqlite \
  "SELECT COUNT(*) FROM events WHERE event='UserPromptSubmit' AND ts >= strftime('%s','now','start of day');"
grep -c 'event=UserPromptSubmit' ~/.clyde/logs/hook.log
```

Expected: the turn count in the window matches the first number, and the two numbers agree for the period covered by the current log. Open the review window and confirm the projects listed are the repos actually worked in.

- [ ] **Step 2: Confirm nothing leaks into the store**

```bash
sqlite3 ~/.clyde/history/history.sqlite "SELECT DISTINCT summary FROM events LIMIT 40;"
```

Expected: only tool summaries of the kind the panel shows. No sentence from any Claude reply. If one appears, stop and fix Task 1 before going further.

- [ ] **Step 3: Update the changelog**

Add to `## [Unreleased]` in `CHANGELOG.md` (one long line, no hard wrapping):

```markdown
- **Clyde remembers what happened.** A new Session review window answers where the day went: how long Claude spent working, how long sessions sat waiting on you, how many turns you took, and which projects took the time. History is kept locally and indefinitely — Settings shows what it costs and clears it in one click. Nothing from your conversations is stored: only the same tool names and summaries the panel already shows you.
```

- [ ] **Step 4: Tick the roadmap**

In `ROADMAP.md`, replace the three implemented `v0.8.0` items with one-line summaries of what was actually built, per the repo convention, and leave the retention item marked with the decision taken (unbounded, manual clearing, size surfaced in Settings).

- [ ] **Step 5: Commit**

```bash
git add CHANGELOG.md ROADMAP.md
git commit -m "docs: record the session review feature"
```

---

## Self-Review

**Spec coverage:** spool format and hook bump → Task 1; stored fields and the no-message-content rule → Tasks 1–2 plus the guard in Task 9 Step 2; schema and indexes → Task 3; claim-and-drain plus crash recovery → Task 4; derived-not-materialised statistics → Task 5; ingest schedule → Task 6; review window → Task 7; visible size and manual clearing → Task 8; failure modes → the `do/catch` in Task 6 (store unopenable), the skip-and-count in Task 4 (malformed line), the hook's `|| true` in Task 1 (spool write fails), the rollback in Task 4 (disk full); `0600` permissions → Task 3; live verification → Tasks 6 and 9.

**Deliberately deferred:** the filterable event list named in the spec's "first release" paragraph is not in Task 7. The tiles and the project table are what make the window worth opening; the list is additive and can follow once the store has real data in it. Note this when reporting completion so it is a recorded decision rather than an omission.

**Placeholders:** none — every code step carries the code.

**Type consistency:** `HistoryEvent(ts:event:sessionID:project:tool:summary:)` is constructed identically in Tasks 2, 4 and 5. `HistoryStore.insertWithinTransaction`, `exec`, `scalarInt` and `handle()` are declared non-private in Task 3 precisely because Tasks 4 and 5 call them. `ingestPending()` returns `Int` in Tasks 4 and 6 alike.
