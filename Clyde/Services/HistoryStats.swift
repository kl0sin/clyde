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
            SELECT SUM(dt), COUNT(*), MAX(dt) FROM (
              SELECT LEAD(ts) OVER (PARTITION BY session_id ORDER BY ts, id) - ts AS dt, event,
                     LEAD(event) OVER (PARTITION BY session_id ORDER BY ts, id) AS next_event
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
              SELECT LEAD(ts) OVER (PARTITION BY session_id ORDER BY ts, id) - ts AS dt, event,
                     LEAD(event) OVER (PARTITION BY session_id ORDER BY ts, id) AS next_event
              FROM events WHERE ts >= \(epoch(from)) AND ts < \(epoch(to))
                AND event IN ('UserPromptSubmit','Stop')
            ) WHERE event = 'Stop' AND next_event = 'UserPromptSubmit' AND dt IS NOT NULL
            """)
        // The worst single wait, not the sum: see PeriodTotals.
        let longestWait = rows(
            """
            SELECT MAX(dt) FROM (
              SELECT LEAD(ts) OVER (PARTITION BY session_id ORDER BY ts, id) - ts AS dt, event,
                     LEAD(event) OVER (PARTITION BY session_id ORDER BY ts, id) AS next_event
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
            sessions: sessionCount,
            longestWaitSeconds: longestWait.first?.first.flatMap { $0.map(Int.init) } ?? 0,
            // Column 2 of the same turn query: the pairs are already built
            // there, and asking twice would mean keeping two copies of a
            // window function in sync.
            longestTurnSeconds: turns.first?.dropFirst(2).first.flatMap { $0.map(Int.init) } ?? 0,
            toolSeconds: toolSeconds(from: from, to: to)
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
        var worked: [String: Int] = [:]
        let workedSQL = """
            SELECT project, SUM(dt) AS worked FROM (
              SELECT project, session_id, event,
                     LEAD(ts) OVER (PARTITION BY session_id ORDER BY ts, id) - ts AS dt,
                     LEAD(event) OVER (PARTITION BY session_id ORDER BY ts, id) AS next_event
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
                    worked[project] = Int(sqlite3_column_int64(stmt, 1))
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
                workingSeconds: worked[project] ?? 0,
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

    /// Seconds spent inside tool calls — the part of a turn that was the
    /// machine working rather than the model thinking.
    ///
    /// Overlapping calls within one session are counted once. Claude runs
    /// tools in parallel batches routinely, so summing durations would
    /// report more tool time than the turn lasted and leave "thinking"
    /// negative. Two *different* sessions overlapping is not double
    /// counting — they really do burn wall-clock at the same time — so the
    /// union is taken per session and the results added.
    ///
    /// The merge happens in Swift rather than SQL: interval union is
    /// awkward in SQLite and this runs over a day's calls, not a table
    /// scan of years.
    func toolSeconds(from: Date, to: Date) -> Int {
        var intervals: [String: [(start: Int, end: Int)]] = [:]
        let sql = """
            SELECT session_id, ts, duration_ms FROM events
            WHERE event = 'PostToolUse' AND duration_ms IS NOT NULL
              AND ts >= ? AND ts < ?
            ORDER BY session_id, ts
            """

        store.read { handle in
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, Int64(from.timeIntervalSince1970))
            sqlite3_bind_int64(stmt, 2, Int64(to.timeIntervalSince1970))
            while sqlite3_step(stmt) == SQLITE_ROW {
                let session = String(cString: sqlite3_column_text(stmt, 0))
                let end = Int(sqlite3_column_int64(stmt, 1))
                let seconds = Int((Double(sqlite3_column_int64(stmt, 2)) / 1000).rounded())
                intervals[session, default: []].append((start: end - seconds, end: end))
            }
        }

        return intervals.values.reduce(0) { $0 + Self.unionLength(of: $1) }
    }

    /// Total length covered by a set of intervals, counting overlap once.
    static func unionLength(of intervals: [(start: Int, end: Int)]) -> Int {
        let sorted = intervals.sorted { $0.start < $1.start }
        var total = 0
        var current: (start: Int, end: Int)?
        for interval in sorted {
            guard var open = current else { current = interval; continue }
            if interval.start <= open.end {
                open.end = max(open.end, interval.end)
                current = open
            } else {
                total += open.end - open.start
                current = interval
            }
        }
        if let open = current { total += open.end - open.start }
        return total
    }

    /// The activity trail: what Claude actually did, newest first.
    ///
    /// Carries tool calls and subagent dispatches and drops the
    /// bookkeeping — `PostToolUse` and `PostToolBatch` mirror every
    /// `PreToolUse`, so listing all three would render one action as three
    /// lines of history. Turn boundaries are left out too: the tiles above
    /// already count them, and interleaving them here buries the work.
    func trail(from: Date, to: Date, project: String? = nil, limit: Int = 200) -> [HistoryEvent] {
        var result: [HistoryEvent] = []
        let filter = project == nil ? "" : "AND project = ?3 "
        let sql = """
            SELECT ts, event, session_id, project, tool, summary
            FROM events
            WHERE ts >= ?1 AND ts < ?2 \(filter)
              AND event IN ('PreToolUse', 'SubagentStart', 'StopFailure')
            ORDER BY ts DESC, id DESC
            LIMIT \(max(0, limit))
            """

        store.read { handle in
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, Int64(from.timeIntervalSince1970))
            sqlite3_bind_int64(stmt, 2, Int64(to.timeIntervalSince1970))
            if let project {
                let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                sqlite3_bind_text(stmt, 3, project, -1, transient)
            }
            while sqlite3_step(stmt) == SQLITE_ROW {
                result.append(HistoryEvent(
                    ts: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 0))),
                    event: String(cString: sqlite3_column_text(stmt, 1)),
                    sessionID: String(cString: sqlite3_column_text(stmt, 2)),
                    project: String(cString: sqlite3_column_text(stmt, 3)),
                    tool: sqlite3_column_text(stmt, 4).map { String(cString: $0) },
                    summary: sqlite3_column_text(stmt, 5).map { String(cString: $0) }
                ))
            }
        }
        return result
    }

    /// Per-day buckets for the activity grid. Uses the same turn pairing as
    /// `totals`, so a period's days always sum to the period's minutes
    /// rather than drifting from the number shown right above them.
    func dailyActivity(from: Date, to: Date) -> [DayActivity] {
        var result: [DayActivity] = []
        let sql = """
            -- One pass, not one per day. The first version picked each day's
            -- busiest project with a correlated subquery, which re-ran the
            -- window function over the entire range for every day it
            -- returned. Half a year of heavy use took 140 seconds; the
            -- review window opens on this query, so it simply never filled
            -- in. Both aggregates now read the same materialised pairs, and
            -- the pick is a ranked join.
            WITH pairs AS (
              SELECT ts, event, project,
                     LEAD(ts) OVER (PARTITION BY session_id ORDER BY ts, id) - ts AS dt,
                     LEAD(event) OVER (PARTITION BY session_id ORDER BY ts, id) AS next_event
              FROM events WHERE ts >= ?1 AND ts < ?2
                AND event IN ('UserPromptSubmit','Stop')
            ),
            marked AS (
              SELECT date(ts, 'unixepoch', 'localtime') AS day, project,
                     CASE WHEN event = 'UserPromptSubmit' AND next_event = 'Stop' AND dt IS NOT NULL
                          THEN dt ELSE 0 END AS worked,
                     CASE WHEN event = 'UserPromptSubmit' THEN 1 ELSE 0 END AS turn
              FROM pairs
            ),
            per_day AS (
              SELECT day, SUM(worked) AS worked, SUM(turn) AS turns
              FROM marked GROUP BY day
            ),
            -- Same tie-break as before: most seconds wins, and an all-zero
            -- day falls back to the alphabetically first project rather
            -- than to whichever row the engine happened to keep.
            ranked AS (
              SELECT day, project,
                     ROW_NUMBER() OVER (PARTITION BY day
                                        ORDER BY SUM(worked) DESC, project ASC) AS rank
              FROM marked GROUP BY day, project
            )
            SELECT per_day.day, per_day.worked, per_day.turns, ranked.project
            FROM per_day LEFT JOIN ranked
              ON ranked.day = per_day.day AND ranked.rank = 1
            WHERE per_day.turns > 0
            ORDER BY per_day.day
            """

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone.current
        formatter.locale = Locale(identifier: "en_US_POSIX")

        store.read { handle in
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, Int64(from.timeIntervalSince1970))
            sqlite3_bind_int64(stmt, 2, Int64(to.timeIntervalSince1970))
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let dayText = sqlite3_column_text(stmt, 0),
                      let day = formatter.date(from: String(cString: dayText)) else { continue }
                let topProject = sqlite3_column_text(stmt, 3).map { String(cString: $0) }
                result.append(DayActivity(
                    day: day,
                    workingSeconds: Int(sqlite3_column_int64(stmt, 1)),
                    turns: Int(sqlite3_column_int64(stmt, 2)),
                    topProject: topProject
                ))
            }
        }
        return result
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
