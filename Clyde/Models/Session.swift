import Foundation

enum SessionStatus: Equatable {
    case busy
    case idle
}

struct ActiveTool: Equatable {
    /// Verbatim tool_name from Claude's hook payload (e.g. "Edit",
    /// "Bash", "mcp__github__create_issue"). Never empty — the hook
    /// skips writing the -tool file when tool_name is missing.
    let toolName: String
    /// Short, display-ready summary of the tool's primary input
    /// (basename for Edit/Write, host for WebFetch, etc.). Empty for
    /// unknown tools — `toolDisplayLabel` falls back to just the name.
    let summary: String
    /// Wall-clock time the PreToolUse hook fired. Used by SessionRow's
    /// TimelineView to render a live-ticking duration string.
    let startedAt: Date
}

struct ActivePlan: Equatable {
    /// Number of TaskCreated events seen for the current session run
    /// (starts at 0, increments by 1 per event). Reset only on
    /// SessionEnd or a manual session reset.
    let taskCount: Int
    /// Number of TaskCompleted events seen since the first TaskCreated
    /// in the current run. Bounded above by `taskCount` for display
    /// purposes via `progress` clamping.
    let doneCount: Int
    /// Wall-clock time the first TaskCreated event fired. Held across
    /// turns so a multi-turn plan-then-execute keeps the same start.
    let startedAt: Date

    /// True when the badge should switch to the green ✓ rendering.
    var isComplete: Bool { taskCount > 0 && doneCount >= taskCount }

    /// 0.0…1.0 fill ratio for the progress bar. Clamped so
    /// `doneCount > taskCount` (defensive — Claude shouldn't fire
    /// extra TaskCompleted events but if it does we don't overflow).
    var progress: Double {
        guard taskCount > 0 else { return 0 }
        return Double(min(doneCount, taskCount)) / Double(taskCount)
    }
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
    /// Non-nil while a built-in or MCP tool call is in flight. The hook
    /// writes this on PreToolUse and clears it on PostToolUse / Stop /
    /// SessionEnd, so it tracks the same per-tool-call lifecycle.
    var activeTool: ActiveTool? = nil
    /// Non-nil while a plan-then-execute run is in progress. Populated
    /// by ProcessMonitor from -plan marker files written by the
    /// TaskCreated / TaskCompleted hook events. Cleared on SessionEnd
    /// or manual session reset.
    var activePlan: ActivePlan? = nil
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

    /// Single-line label rendered on the session row's second line
    /// while a tool is running. Returns `nil` when the session is idle
    /// or busy-but-not-in-a-tool — callers fall back to the project
    /// path in that case.
    var toolDisplayLabel: String? {
        guard let tool = activeTool else { return nil }
        return tool.summary.isEmpty ? tool.toolName : "\(tool.toolName) · \(tool.summary)"
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
