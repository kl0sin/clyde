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
