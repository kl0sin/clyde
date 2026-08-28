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

        let workingSeconds: Int64? = turns.first?.first ?? nil
        let waitingSeconds: Int64? = waits.first?.first ?? nil

        return PeriodTotals(
            workingSeconds: workingSeconds.map(Int.init) ?? 0,
            waitingSeconds: waitingSeconds.map(Int.init) ?? 0,
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
