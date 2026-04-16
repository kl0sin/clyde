import Foundation

enum SessionStatus: Equatable {
    case busy
    case idle
}

struct Session: Identifiable, Equatable {
    let id: UUID
    /// Mutable so a `claude --resume` can swap in the new Claude process
    /// PID without our needing to throw away the row. The row's stable
    /// identity comes from `id` (derived from `sessionId`), not from PID.
    var pid: pid_t
    /// Stable identity from Claude Code's hook payload (UUID). Available for
    /// sessions discovered via SessionStart hook; nil for legacy / pgrep-only.
    var sessionId: String?
    var status: SessionStatus
    var workingDirectory: String
    var customName: String?
    var statusChangedAt: Date
    var needsAttention: Bool = false
    /// Non-nil when a StopFailure event reported an API/billing error.
    /// Orthogonal to busy/idle — a session can be busy AND have an error
    /// (Claude retrying internally). Cleared by the next Stop event.
    var errorReason: String? = nil
    /// Non-nil while a subagent is actively running inside this session.
    var subagentType: String? = nil
    /// Set when the underlying Claude process has exited but we're keeping
    /// the row visible briefly. Nil for live sessions.
    var endedAt: Date? = nil

    var isGhost: Bool { endedAt != nil }

    /// Human-readable label for the error badge. Returns nil if there
    /// is no error, so the UI can gate the badge on this being non-nil.
    var errorDisplayText: String? {
        guard let reason = errorReason else { return nil }
        switch reason {
        case "rate_limit":              return "Rate limited"
        case "billing_error":           return "Billing error"
        case "server_error":            return "Server error"
        case "max_output_tokens":       return "Output limit"
        case "authentication_failed":   return "Auth failed"
        case "invalid_request":         return "Invalid request"
        default:                        return "Error"
        }
    }

    /// The project folder name extracted from the working directory, or
    /// nil if the cwd is empty / the home directory.
    var projectName: String? {
        guard !workingDirectory.isEmpty, workingDirectory != NSHomeDirectory() else { return nil }
        return (workingDirectory as NSString).lastPathComponent
    }

    var displayName: String {
        if let customName, !customName.isEmpty {
            return Self.sanitize(customName)
        }
        // Use the project folder name whenever cwd is known and looks like a
        // real project path. The home directory itself is the classic
        // unreliable value that legacy pgrep-based detection returns when
        // `lsof` finds only the global ~/.claude/settings file, so we treat
        // it as "unknown" and fall back to the generic label.
        if !workingDirectory.isEmpty && workingDirectory != NSHomeDirectory() {
            return Self.sanitize((workingDirectory as NSString).lastPathComponent)
        }
        if workingDirectory == NSHomeDirectory() {
            return "Home"
        }
        return "Untitled session"
    }

    /// Strip control characters and clamp the length so a hostile or
    /// corrupted cwd can't break the row layout. Anything past 64 chars
    /// gets ellipsised — long enough for any reasonable folder name.
    private static func sanitize(_ raw: String) -> String {
        let cleaned = raw.unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) }
            .reduce(into: "") { $0.unicodeScalars.append($1) }
        if cleaned.count > 64 {
            return String(cleaned.prefix(63)) + "…"
        }
        return cleaned.isEmpty ? "Untitled session" : cleaned
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
