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

/// One in-flight Task-dispatched subagent inside a parent session.
struct ActiveSubagent: Equatable, Identifiable, Sendable {
    /// The subagent's `agent_id` once SubagentStart has claimed the
    /// entry; the dispatching `tool_use_id` while it is still pending.
    let id: String
    /// `subagent_type` from `tool_input` (e.g. `general-purpose`, `Explore`).
    let type: String
    /// Trimmed `description` (or prompt fallback) from `tool_input`.
    let summary: String
    /// When the parent dispatched the Task call (hook write time).
    let startedAt: Date
    /// True once a `TeammateIdle` event flagged this agent-team teammate
    /// as about to go idle. A quiet row state, deliberately not routed
    /// into the attention pipeline — see the TeammateIdle branch in
    /// `clyde-hook.sh` for why.
    var isIdle: Bool = false
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

    /// Currently running Task-dispatched subagents inside this session,
    /// sorted by `startedAt` ascending (oldest first). Empty when the
    /// session has no parallel Task fan-out in flight.
    var activeSubagents: [ActiveSubagent] = []

    /// Type of the subagent that best represents this session for the
    /// Activity timeline: the oldest one still running, or nil when none
    /// are. Derived from `activeSubagents` rather than stored, so the
    /// timeline and the panel cannot disagree.
    var primarySubagentType: String? { activeSubagents.first?.type }

    /// How the row names the agents this session has in flight, or nil when
    /// it has none.
    ///
    /// Every agent affordance used to be gated on `count >= 2`, because a
    /// single agent was covered by the legacy `-subagent` marker's own
    /// indicator. v0.7.0 retired that marker and nothing took over the
    /// one-agent case, so a session with exactly one agent running showed
    /// no sign of it at all — the row fell back to the tool line and the
    /// work looked like it was happening nowhere.
    var activeAgentsLabel: String? {
        switch activeSubagents.count {
        case 0: return nil
        case 1: return "1 agent"
        case let n: return "\(n) agents"
        }
    }
    /// Non-nil while a built-in or MCP tool call is in flight. The hook
    /// writes this on PreToolUse and clears it on PostToolUse / Stop /
    /// SessionEnd, so it tracks the same per-tool-call lifecycle.
    var activeTool: ActiveTool? = nil
    /// How many tool calls are in flight right now. Claude batches calls
    /// and runs them in parallel, so this is routinely > 1; the row shows
    /// `N tools` instead of a single label in that case. 0 when idle.
    var activeToolCount: Int = 0
    /// Name of the slash command driving this turn, from
    /// `UserPromptExpansion`. Cleared when the turn ends. Nil for
    /// ordinary typed prompts.
    var activeCommand: String? = nil
    /// Name of the git worktree this session is working inside, from
    /// `WorktreeCreate`. Empty when the session is in a normal checkout.
    var worktreeName: String = ""
    /// Non-nil while a plan-then-execute run is in progress. Populated
    /// by ProcessMonitor from -plan marker files written by the
    /// TaskCreated / TaskCompleted hook events. Cleared on SessionEnd
    /// or manual session reset.
    var activePlan: ActivePlan? = nil
    /// One-line preview of Claude's last reply, from `Stop`'s
    /// `last_assistant_message`. Cleared the moment the user submits a
    /// new prompt, so it only ever describes a session sitting idle.
    var lastMessage: String? = nil
    /// Set when the underlying Claude process has exited but we're keeping
    /// the row visible briefly. Nil for live sessions.
    var endedAt: Date? = nil
    /// "cleat" when this session runs inside a Cleat Docker sandbox,
    /// empty for regular host sessions. Populated from the hook's
    /// `-info` file. Drives the small badge rendered next to the
    /// project name so the user can tell sandboxed sessions apart.
    var runtime: String = ""
    /// Cleat container name (e.g. `cleat-clyde-1a2b3c4d`) when
    /// `runtime == "cleat"`. Empty otherwise. Shown as a tooltip on
    /// the cleat badge and useful for future container-aware actions.
    var container: String = ""

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

    /// True while the session still has work in flight — its own turn,
    /// or a subagent running past it.
    ///
    /// The busy marker is written by `UserPromptSubmit` and cleared by
    /// `Stop`, but `-agents/` records deliberately survive `Stop`
    /// because subagents routinely outlive the parent's turn. Reading
    /// only the marker meant a session showed "ready" beside a spinning
    /// agent, and the "finished" notification fired while four agents
    /// were still working.
    ///
    /// A teammate flagged idle by `TeammateIdle` is not doing work and
    /// does not hold the session open on its own.
    var isWorking: Bool {
        if status == .busy { return true }
        return activeSubagents.contains { !$0.isIdle }
    }

    /// The project folder name extracted from the working directory, or
    /// nil if the cwd is empty / the home directory.
    var projectName: String? {
        guard !workingDirectory.isEmpty, workingDirectory != NSHomeDirectory() else { return nil }
        return Self.projectFolder(from: workingDirectory)
    }

    /// The folder a session belongs to.
    ///
    /// Normally the last component of the cwd. Inside a worktree it is
    /// the repository that owns it: Claude Code puts worktrees under
    /// `<repo>/.claude/worktrees/<name>` and moves the session there,
    /// so the plain answer renamed a session mid-flight to the branch
    /// it had just created — and the worktree badge beside it showed
    /// the same word twice while the project itself disappeared from
    /// the row.
    static func projectFolder(from path: String) -> String {
        (projectRoot(from: path) as NSString).lastPathComponent
    }

    /// The repository a path belongs to, with any worktree stripped.
    ///
    /// Claude Code puts a worktree under `<repo>/.claude/worktrees/<name>`
    /// and moves the session there, so the raw path makes a worktree look
    /// like a project of its own — a second entry in the review window
    /// for what is the same work on a different branch.
    static func projectRoot(from path: String) -> String {
        let marker = "/.claude/worktrees/"
        if let range = path.range(of: marker) {
            return String(path[path.startIndex..<range.lowerBound])
        }
        return path
    }

    /// The worktree a path is in, if it is in one.
    static func worktreeName(from path: String) -> String? {
        let marker = "/.claude/worktrees/"
        guard let range = path.range(of: marker) else { return nil }
        let tail = path[range.upperBound...]
        let name = tail.split(separator: "/").first.map(String.init)
        return (name?.isEmpty ?? true) ? nil : name
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
            return Self.sanitize(Self.projectFolder(from: workingDirectory))
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
