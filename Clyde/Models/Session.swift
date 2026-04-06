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

    var displayName: String {
        if let customName, !customName.isEmpty {
            return customName
        }
        if workingDirectory.isEmpty {
            return "Session \(pid)"
        }
        return (workingDirectory as NSString).lastPathComponent
    }

    init(pid: pid_t, workingDirectory: String = "", status: SessionStatus = .busy) {
        self.id = UUID()
        self.pid = pid
        self.status = status
        self.workingDirectory = workingDirectory
        self.customName = nil
        self.statusChangedAt = Date()
    }
}
