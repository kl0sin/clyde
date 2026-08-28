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
