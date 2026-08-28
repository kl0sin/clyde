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
