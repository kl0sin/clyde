import Foundation

/// Parsing for the hook's spool format. Pure by design: the file handover
/// lives in HistoryStore, so the format itself can be tested without touching
/// the filesystem.
enum HistorySpool {
    static func parse(line: String) -> HistoryEvent? {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ts = json["ts"] as? Int,
              let event = json["event"] as? String,
              let sessionID = json["session_id"] as? String else { return nil }

        return HistoryEvent(
            ts: Date(timeIntervalSince1970: TimeInterval(ts)),
            event: event,
            sessionID: sessionID,
            // The repository, not the worktree inside it: two branches
            // of one repo are one project that happened on two branches.
            project: Session.projectRoot(from: (json["cwd"] as? String) ?? ""),
            tool: json["tool"] as? String,
            summary: json["summary"] as? String,
            durationMs: json["dur"] as? Int
        )
    }
}
