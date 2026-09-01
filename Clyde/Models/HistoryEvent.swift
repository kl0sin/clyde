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
    /// How long the call took, in milliseconds. Only `PostToolUse` carries
    /// it — it is what lets the review separate the model thinking from
    /// the machine compiling, instead of reporting one wall-clock number
    /// and calling all of it work.
    var durationMs: Int?
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
    /// The longest single prompt-to-Stop turn. The mirror of
    /// `longestWaitSeconds`: the sum tells you the day was busy, this tells
    /// you which turn to go look at.
    let longestTurnSeconds: Int
    /// Of the busy time, how much was spent inside tool calls. Zero also
    /// means "not recorded" for history written before the hook reported
    /// durations, which is why the split is hidden rather than drawn as
    /// 100% thinking when this is zero.
    let toolSeconds: Int

    /// Busy time that was not a tool call: the model actually working.
    /// Clamped, because a turn still open can have tool calls counted
    /// against a turn duration that does not exist yet.
    var thinkingSeconds: Int { max(0, workingSeconds - toolSeconds) }
}

struct ProjectRow: Equatable {
    /// The repository's path, with any worktree stripped — so a branch
    /// checked out in a worktree is this project on a branch, not a
    /// project of its own.
    let project: String
    let workingSeconds: Int
    let turns: Int
    let topTool: String?
    /// Worktrees this row's time was spent in, most-used first. Empty
    /// when the work happened in the repository itself.
    var worktrees: [String] = []
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
