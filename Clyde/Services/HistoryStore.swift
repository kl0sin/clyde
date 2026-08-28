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

    /// Name of the most recently claimed spool file. Exposed for tests that
    /// need to reconstruct the crash-between-commit-and-unlink window.
    private(set) var lastClaimedFileName: String?

    /// Serializes every access to `db`. The store is reachable from three
    /// independent callers — the launch path, a repeating 30s timer, and
    /// (via `HistoryStats`) the UI — and nothing stops any two of them
    /// from overlapping: a slow ingest tick still running when the next
    /// one fires, launch racing the first tick, or the review window
    /// opening while a tick is mid-transaction. Reads and writes share one
    /// connection, so an unsynchronized read issued while a write's
    /// transaction is open would observe that transaction's uncommitted
    /// rows — nothing is corrupted, but the window could briefly show a
    /// half-written batch, which is exactly the "quietly wrong number"
    /// this feature exists to avoid. Every public entry point below takes
    /// this queue before touching `db`; nothing reaches the connection
    /// any other way. The internal (`…Inner` / private) methods do not
    /// take the queue themselves — they assume the caller already holds
    /// it, either because it's an entry point's own `sync` block or
    /// because it's inside `ingestPending()`'s.
    private let ingestQueue = DispatchQueue(label: "com.clyde.historystore.ingest")

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
        // No lock needed here: init runs before this instance is shared
        // with any other thread, so there is nothing to race yet.
        try execInner("""
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

    // MARK: - Public entry points (queue-locked; safe to call from any thread)

    func insert(_ events: [HistoryEvent]) throws {
        guard !events.isEmpty else { return }
        try ingestQueue.sync {
            try execInner("BEGIN")
            do {
                try insertWithinTransaction(events)
                try execInner("COMMIT")
            } catch {
                try? execInner("ROLLBACK")
                throw error
            }
        }
    }

    func eventCount() -> Int {
        ingestQueue.sync { scalarIntInner("SELECT COUNT(*) FROM events") ?? 0 }
    }

    func oldestEventDate() -> Date? {
        ingestQueue.sync {
            guard let ts = scalarIntInner("SELECT MIN(ts) FROM events"), ts > 0 else { return nil }
            return Date(timeIntervalSince1970: TimeInterval(ts))
        }
    }

    func databaseSizeBytes() -> Int64 {
        // File-system metadata, not a connection access — no lock needed.
        let attrs = try? FileManager.default.attributesOfItem(atPath: databaseURL.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }

    func clear() throws {
        try ingestQueue.sync {
            try execInner("DELETE FROM events; DELETE FROM ingested_files; VACUUM;")
        }
    }

    /// General read accessor for callers (namely `HistoryStats`) that need
    /// the raw connection to build their own queries. `body` receives the
    /// handle and must run its *entire* prepare/step/finalize sequence
    /// inside this closure — the lock is held only for the closure's
    /// duration, so a prepared statement must never be smuggled out to be
    /// stepped later, unlocked.
    func read<T>(_ body: (OpaquePointer?) -> T) -> T {
        ingestQueue.sync { body(db) }
    }

    /// Drain the spool into the database.
    ///
    /// The spool is *claimed* by renaming rather than read in place: the
    /// rename is atomic, so the hook's next append transparently creates a
    /// fresh spool and never notices the handover. Reading in place would
    /// mean truncating a file another process is appending to, and with
    /// parallel hooks that race fires sooner rather than later.
    @discardableResult
    func ingestPending() -> Int {
        ingestQueue.sync {
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
    }

    // MARK: - Inner implementations (unlocked; caller must already hold ingestQueue)

    /// Insert without opening a transaction — used by the ingest path,
    /// which needs the events and the claimed filename to commit together.
    /// Unlocked: only called from `insert(_:)` and `ingestClaimed(named:in:)`,
    /// both of which already run inside `ingestQueue`.
    private func insertWithinTransaction(_ events: [HistoryEvent]) throws {
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
            try execInner("BEGIN")
            try insertWithinTransaction(events)
            try markIngested(name)
            try execInner("COMMIT")
        } catch {
            try? execInner("ROLLBACK")
            ClydeLog.general.error("History: ingest failed, spool kept: \(error.localizedDescription, privacy: .public)")
            return 0
        }

        try? FileManager.default.removeItem(at: url)
        return events.count
    }

    private func alreadyIngested(_ name: String) -> Bool {
        let escaped = name.replacingOccurrences(of: "'", with: "''")
        return (scalarIntInner("SELECT COUNT(*) FROM ingested_files WHERE name = '\(escaped)'") ?? 0) > 0
    }

    private func markIngested(_ name: String) throws {
        let escaped = name.replacingOccurrences(of: "'", with: "''")
        try execInner("INSERT INTO ingested_files (name, ingested_at) VALUES ('\(escaped)', \(Int(Date().timeIntervalSince1970)))")
    }

    /// Unlocked exec. Only called from `init` (nothing to race with yet)
    /// and from other inner methods that already run inside `ingestQueue`.
    private func execInner(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw StoreError.statementFailed(lastError())
        }
    }

    /// Unlocked scalar query. Only called from other inner/entry-point
    /// bodies that already run inside `ingestQueue`.
    private func scalarIntInner(_ sql: String) -> Int? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_int64(stmt, 0))
    }

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
