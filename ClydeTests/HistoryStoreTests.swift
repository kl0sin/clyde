import XCTest
import SQLite3
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

    func testParsesAToolDuration() {
        let line = #"{"ts": 1787660000, "event": "PostToolUse", "session_id": "s1", "cwd": "/repo", "tool": "Bash", "dur": 4200}"#

        XCTAssertEqual(HistorySpool.parse(line: line)?.durationMs, 4200)
    }

    func testEventWithoutADurationParsesToNil() {
        let line = #"{"ts": 1787660000, "event": "Stop", "session_id": "s1", "cwd": "/repo"}"#

        XCTAssertNil(HistorySpool.parse(line: line)?.durationMs)
    }

    /// Databases created before v39 have no duration column. Opening one
    /// must add it rather than failing or silently dropping every insert
    /// that carries a duration — an install that has been collecting
    /// history for weeks is exactly the case that matters here.
    func testOpeningAPreDurationDatabaseMigratesIt() throws {
        let dir = tempDir()
        // Build the old schema by hand, exactly as v38 shipped it.
        let old = try HistoryStore(directory: dir)
        old.read { handle in
            sqlite3_exec(handle, "DROP TABLE events", nil, nil, nil)
            sqlite3_exec(handle, """
                CREATE TABLE events (
                  id INTEGER PRIMARY KEY, ts INTEGER NOT NULL, event TEXT NOT NULL,
                  session_id TEXT NOT NULL, project TEXT NOT NULL, tool TEXT, summary TEXT
                )
                """, nil, nil, nil)
        }

        let migrated = try HistoryStore(directory: dir)
        try migrated.insert([
            HistoryEvent(ts: Date(timeIntervalSince1970: 100), event: "PostToolUse",
                         sessionID: "s1", project: "/repo", tool: "Bash",
                         summary: nil, durationMs: 2500)
        ])

        XCTAssertEqual(migrated.eventCount(), 1)
    }

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

    /// B1: a single invalid UTF-8 byte between two valid lines used to
    /// fail `String(contentsOf:encoding:.utf8)` for the *whole file*,
    /// which returned early without consuming or marking it ingested —
    /// so every event in the file was lost, and lost again every 30s
    /// forever, since the same unreadable file just kept getting
    /// re-claimed and re-failed. Decoding losslessly (substituting
    /// U+FFFD for the bad byte) must recover the two good lines and
    /// still consume the file.
    func testInvalidUTF8ByteDoesNotDiscardTheRestOfTheFile() throws {
        let dir = tempDir()
        var bytes = Data((spoolLine("UserPromptSubmit", ts: 100) + "\n").utf8)
        bytes.append(0xFF)
        bytes.append(contentsOf: "\n".utf8)
        bytes.append(contentsOf: (spoolLine("Stop", ts: 160) + "\n").utf8)
        try bytes.write(to: dir.appendingPathComponent("spool.jsonl"))
        let store = try HistoryStore(directory: dir)

        let count = store.ingestPending()

        XCTAssertEqual(count, 2)
        XCTAssertEqual(store.eventCount(), 2)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("spool.jsonl").path),
            "a spool with one bad byte must still be consumed, not retried forever")
    }
}
