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
    /// The single worst gap between Claude finishing and the human coming
    /// back. Kept apart from `waitingSeconds` because the sum is
    /// misleading on its own — leave a session overnight and it reads
    /// fourteen hours — while the worst single wait names a moment you can
    /// actually do something about.
    let longestWaitSeconds: Int
    /// How often a session sat blocked on a permission prompt.
    let blockedCount: Int
}

struct ProjectRow: Equatable {
    let project: String
    let workingSeconds: Int
    let turns: Int
    let topTool: String?
}

/// One local-time day's worth of activity, for the calendar grid.
///
/// Local time on purpose: the grid a person reads is their own calendar,
/// so a turn that starts at 23:50 belongs to that evening, not to the
/// following UTC day.
struct DayActivity: Equatable {
    let day: Date
    let workingSeconds: Int
    let turns: Int
    /// The project that took the most time that day — the first thing
    /// anyone wants to know about a busy square.
    let topProject: String?
}
