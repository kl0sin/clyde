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
        // Use the project folder name whenever cwd is known and looks like a
        // real project path. The home directory itself is the classic
        // unreliable value that legacy pgrep-based detection returns when
        // `lsof` finds only the global ~/.claude/settings file, so we treat
        // it as "unknown" and fall back to the generic label.
        if !workingDirectory.isEmpty && workingDirectory != NSHomeDirectory() {
            return (workingDirectory as NSString).lastPathComponent
        }
        return "Untitled session"
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
