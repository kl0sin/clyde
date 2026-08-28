import Foundation
import SQLite3

/// Read-only queries over `HistoryStore`.
///
/// Durations are derived from turn boundaries: within one session,
/// `UserPromptSubmit → Stop` is time Claude spent working and
/// `Stop → next UserPromptSubmit` is time the session spent waiting on the
/// human. A turn with no `Stop` yet contributes nothing, so refreshing the
/// window cannot inflate a finished day.
///
/// `workingSeconds` and `waitingSeconds` are deliberately not a partition of
/// elapsed session time. A prompt immediately followed by another prompt
/// (an interrupted turn re-prompted) leaves a gap that lands in neither
/// bucket — it is the human typing over an abandoned turn, not time Claude
/// spent working or time the session spent waiting on a finished answer.
/// Do not "fix" the two totals to sum to elapsed time; that would misbill
/// that gap into one bucket or the other.
///
/// Every query here goes through `store.read`, which serializes against
/// `HistoryStore`'s own ingest queue — this window can be opened while a
/// 30s ingest tick is mid-transaction, and without that serialization a
/// query issued at that moment would observe the transaction's
/// not-yet-committed rows.
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
              FROM events
              -- Deliberate: the range filter runs before LEAD builds pairs, so a
              -- turn straddling a window boundary (prompt before `from`, Stop
              -- inside it, or vice versa) is missing one endpoint and
              -- contributes to neither period. Crediting the partial segment
              -- would mean clamping durations to the window, which is a lot
              -- more code for a cost of at most one turn per boundary.
              WHERE ts >= \(epoch(from)) AND ts < \(epoch(to))
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
        let promptCount = scalarInt(
            "SELECT COUNT(*) FROM events WHERE event = 'UserPromptSubmit' AND ts >= \(epoch(from)) AND ts < \(epoch(to))") ?? 0
        let sessionCount = scalarInt(
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

    /// Per-project breakdown. `turns` here counts every `UserPromptSubmit` in
    /// the window — the same definition `PeriodTotals.turns` uses — not just
    /// completed prompt/Stop pairs, so the per-project column never
    /// undercounts against the headline total shown on the same screen. A
    /// project with prompts but no completed pair still appears, with
    /// `workingSeconds == 0`, rather than being invisible in a view of work
    /// that only just started.
    func projects(from: Date, to: Date) -> [ProjectRow] {
        var worked: [String: (seconds: Int, topTool: String?)] = [:]
        let workedSQL = """
            SELECT project, SUM(dt) AS worked FROM (
              SELECT project, session_id, event,
                     LEAD(ts) OVER (PARTITION BY session_id ORDER BY ts) - ts AS dt,
                     LEAD(event) OVER (PARTITION BY session_id ORDER BY ts) AS next_event
              FROM events WHERE ts >= \(epoch(from)) AND ts < \(epoch(to))
                AND event IN ('UserPromptSubmit','Stop')
            ) WHERE event = 'UserPromptSubmit' AND next_event = 'Stop' AND dt IS NOT NULL
            GROUP BY project
            """
        store.read { handle in
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(handle, workedSQL, -1, &stmt, nil) == SQLITE_OK {
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let project = String(cString: sqlite3_column_text(stmt, 0))
                    worked[project] = (Int(sqlite3_column_int64(stmt, 1)), nil)
                }
            }
            sqlite3_finalize(stmt)
        }

        var turnsByProject: [String: Int] = [:]
        let turnsSQL = """
            SELECT project, COUNT(*) FROM events
            WHERE event = 'UserPromptSubmit' AND ts >= \(epoch(from)) AND ts < \(epoch(to))
            GROUP BY project
            """
        store.read { handle in
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(handle, turnsSQL, -1, &stmt, nil) == SQLITE_OK {
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let project = String(cString: sqlite3_column_text(stmt, 0))
                    turnsByProject[project] = Int(sqlite3_column_int64(stmt, 1))
                }
            }
            sqlite3_finalize(stmt)
        }

        let projects = Set(worked.keys).union(turnsByProject.keys)
        let result = projects.map { project -> ProjectRow in
            ProjectRow(
                project: project,
                workingSeconds: worked[project]?.seconds ?? 0,
                turns: turnsByProject[project] ?? 0,
                topTool: topTool(project: project, from: from, to: to)
            )
        }
        return result.sorted { a, b in
            if a.workingSeconds != b.workingSeconds { return a.workingSeconds > b.workingSeconds }
            if a.turns != b.turns { return a.turns > b.turns }
            return a.project < b.project
        }
    }

    private func topTool(project: String, from: Date, to: Date) -> String? {
        let sql = """
            SELECT tool FROM events
            WHERE tool IS NOT NULL AND project = ?
              AND ts >= ? AND ts < ?
            GROUP BY tool ORDER BY COUNT(*) DESC, tool ASC LIMIT 1
            """
        return store.read { handle in
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(stmt, 1, project, -1, transient)
            sqlite3_bind_int64(stmt, 2, Int64(epoch(from)))
            sqlite3_bind_int64(stmt, 3, Int64(epoch(to)))
            guard sqlite3_step(stmt) == SQLITE_ROW, let text = sqlite3_column_text(stmt, 0) else { return nil }
            return String(cString: text)
        }
    }

    private func epoch(_ date: Date) -> Int { Int(date.timeIntervalSince1970) }

    /// Scalar-query helper, mirroring `HistoryStore`'s old `scalarInt` but
    /// routed through `store.read` so it takes the store's serial queue
    /// like every other access here.
    private func scalarInt(_ sql: String) -> Int? {
        store.read { handle in
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return Int(sqlite3_column_int64(stmt, 0))
        }
    }

    private func rows(_ sql: String) -> [[Int64?]] {
        store.read { handle in
            var out: [[Int64?]] = []
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { return out }
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
}
