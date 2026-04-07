import Foundation

enum SessionStatus: Equatable {
    case busy
    case idle
}

struct Session: Identifiable, Equatable {
    let id: UUID
    let pid: pid_t
    /// Stable identity from Claude Code's hook payload (UUID). Available for
    /// sessions discovered via SessionStart hook; nil for legacy / pgrep-only.
    var sessionId: String?
    var status: SessionStatus
    var workingDirectory: String
    var customName: String?
    var statusChangedAt: Date
    var needsAttention: Bool = false
    /// Set when the underlying Claude process has exited but we're keeping
    /// the row visible briefly. Nil for live sessions.
    var endedAt: Date? = nil

    var isGhost: Bool { endedAt != nil }

    var displayName: String {
        if let customName, !customName.isEmpty {
            return customName
        }
        // Sessions without a hook session_id were discovered via pgrep alone,
        // so we don't have a trustworthy cwd for them — fall back to a
        // generic label until the next hook event populates the -info file.
        if sessionId == nil {
            return "Session \(pid)"
        }
        if workingDirectory.isEmpty {
            return "Session \(pid)"
        }
        return (workingDirectory as NSString).lastPathComponent
    }

    init(pid: pid_t, workingDirectory: String = "", status: SessionStatus = .busy, sessionId: String? = nil) {
        // Prefer to derive the SwiftUI identity from Claude's session_id when
        // it's available so list rows have stable identity across pollings.
        if let sessionId, let derived = UUID(uuidString: sessionId) {
            self.id = derived
        } else {
            self.id = UUID()
        }
        self.pid = pid
        self.sessionId = sessionId
        self.status = status
        self.workingDirectory = workingDirectory
        self.customName = nil
        self.statusChangedAt = Date()
    }
}
