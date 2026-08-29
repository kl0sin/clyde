import Foundation
import Combine
import Darwin
import Darwin.libproc

protocol ShellExecutor {
    func run(_ command: String) async throws -> String
}

struct RealShellExecutor: ShellExecutor {
    func run(_ command: String) async throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

/// Monitors Claude Code processes and classifies their state based on child process presence.
/// A Claude process with active children → busy (processing a tool). No children → idle (waiting).
@MainActor
final class ProcessMonitor: ObservableObject {
    @Published var sessions: [Session] = []
    @Published var clydeState: ClydeState = .sleeping

    private let shell: ShellExecutor
    private let stateDir: URL
    private(set) var pollingInterval: TimeInterval

    /// Identity check used by `isLiveClaudeProcess` to confirm that a
    /// PID belongs to the Claude Code CLI. Injectable so tests can
    /// substitute a stub instead of having `ps` actually run against
    /// the test process. Default implementation lives in
    /// `defaultIsLiveClaudeProcess`.
    private let isLiveClaudeProcessCheck: @Sendable (pid_t) -> Bool

    /// Fired once per session when it transitions from busy to idle.
    var onSessionBecameIdle: ((Session) -> Void)?

    private var pollTask: Task<Void, Never>?
    private var stateWatchTask: Task<Void, Never>?
    private var stateDirSource: DispatchSourceFileSystemObject?

    /// PIDs the hook state watcher currently considers busy.
    /// This is updated by a fast (~500ms) file-system poll on `~/.clyde/state/`,
    /// decoupled from the heavier child-process poll.
    private var hookBusyPIDs: Set<pid_t> = []

    /// Error reason per PID, populated from `-error` marker files
    /// written by the StopFailure hook. Keyed by PID, value is the
    /// `stop_reason` string (e.g. "rate_limit", "server_error").
    private var hookErrorByPID: [pid_t: String] = [:]

    /// Active subagent type per PID, populated from `-subagent` marker
    /// files written by SubagentStart. Cleared on SubagentStop / Stop.

    /// Active tool per PID, populated from `-tool` marker files written
    /// by PreToolUse. Cleared on PostToolUse / Stop / SessionEnd.
    private var hookToolByPID: [pid_t: ActiveTool] = [:]

    /// Active plan progress per PID, populated from `-plan` marker
    /// files written by TaskCreated / TaskCompleted. Cleared only on
    /// SessionEnd or a manual session reset; persists across Stop /
    /// UserPromptSubmit so a multi-turn plan keeps tracking.
    private var hookPlanByPID: [pid_t: ActivePlan] = [:]
    private var hookLastMessageByPID: [pid_t: String] = [:]
    private var hookToolCountByPID: [pid_t: Int] = [:]
    private var hookCommandByPID: [pid_t: String] = [:]
    private var hookWorktreeByPID: [pid_t: (name: String, path: String)] = [:]

    /// Active Task-dispatched subagents per PID, populated from `-agents/*.json` markers.
    /// Inner array is sorted by `startedAt` ascending.
    private var hookAgentsByPID: [pid_t: [ActiveSubagent]] = [:]

    /// Pgrep-only PIDs (no `-info` file yet, so no `sessionId`) that we
    /// deferred for one poll tick to give the SessionStart hook a chance
    /// to fire. Used by `poll()` to ensure each PID is deferred at most
    /// once — second appearance is rendered normally even if the hook
    /// hasn't shown up. See the "deferral" comment in `poll()` for the
    /// race this closes.
    private var deferredPgrepPIDs: Set<pid_t> = []

    /// Window during which a recently-ended ghost row implies "the next
    /// new pgrep PID is probably a resume of the same session". Anything
    /// longer than this and we stop suspecting resume; anything shorter
    /// and slow Claude startups would race past it.
    private static let resumeDeferWindow: TimeInterval = 5

    init(
        shell: ShellExecutor = RealShellExecutor(),
        pollingInterval: TimeInterval = AppConstants.defaultPollingInterval,
        stateDir: URL = AppPaths.stateDir,
        isLiveClaudeProcessCheck: @escaping @Sendable (pid_t) -> Bool = ProcessMonitor.defaultIsLiveClaudeProcess
    ) {
        self.shell = shell
        self.pollingInterval = pollingInterval
        self.stateDir = stateDir
        self.isLiveClaudeProcessCheck = isLiveClaudeProcessCheck
    }

    deinit {
        // Release everything we hold so resources don't outlive the monitor
        // when nobody calls stopPolling() before deallocation.
        // Task.cancel() and DispatchSource.cancel() are both safe to invoke
        // from a nonisolated context. The cancel handler closes the
        // descriptor it captured.
        pollTask?.cancel()
        stateWatchTask?.cancel()
        stateDirSource?.cancel()
    }

    /// Hook-derived metadata for discovered sessions, keyed by PID.
    /// Populated by `discoverPIDs()` from -info files and consumed by
    /// `updatedSession` when building Session structs.
    private(set) var hookInfoByPID: [pid_t: HookInfo] = [:]

    struct HookInfo: Equatable {
        let sessionId: String
        let cwd: String
        /// "startup", "resume", "clear", or "compact". Empty for
        /// sessions discovered via pgrep or legacy -info files that
        /// predate the source field (v15+).
        let source: String
        /// "cleat" when the session runs inside a Cleat Docker
        /// sandbox (https://github.com/cleatdev/cleat). Empty for
        /// regular host sessions. Drives both the liveness check
        /// (a cleat session's PID points at the container init
        /// process, not at `claude`) and the row decoration.
        let runtime: String
        /// Cleat container name (e.g. `cleat-clyde-1a2b3c4d`) when
        /// `runtime == "cleat"`, empty otherwise. Surfaced in the UI
        /// and useful for tooltips / debug.
        let container: String
    }

    /// Side map of PID → runtime ("" or "cleat") populated by
    /// `refreshPIDRuntimes()`. Used by `isLiveClaudeProcess` so the
    /// cleat branch skips the `ps -o comm=claude` identity check —
    /// the host PID is a `containerd-shim`-shaped process, not the
    /// Claude binary. Refreshed before every disk-state pass so the
    /// FSEvents-driven `pollHookState` path also sees correct values.
    private var pidRuntimeByPID: [pid_t: String] = [:]

    func discoverPIDs() async -> [pid_t] {
        // Self-contained: refresh the runtime side map before the
        // liveness loop so a cleat-tagged -info is recognised even
        // when discoverPIDs() is invoked directly (tests, or any
        // future call site that skips the poll() preamble). In the
        // poll() path this is a cheap duplicate dir listing.
        refreshPIDRuntimes()

        // One source, and it must be evidence rather than inference:
        //
        //  1. -info files written by the SessionStart hook. These give us
        //     full session metadata (session_id + cwd) and classify
        //     accurately via -busy markers.
        //
        // That is the only source. Discovery by process name was removed
        // after it turned every process merely called `claude` — including
        // this project's own test fixtures — into a phantom session.
        var pids: Set<pid_t> = []
        var hookInfo: [pid_t: HookInfo] = [:]

        if let infoFiles = try? FileManager.default.contentsOfDirectory(
            at: stateDir,
            includingPropertiesForKeys: nil
        ) {
            for file in infoFiles where file.lastPathComponent.hasSuffix("-info") {
                guard let info = readInfoFile(file: file) else {
                    try? FileManager.default.removeItem(at: file)
                    continue
                }
                // Liveness alone is not enough: macOS aggressively recycles
                // PIDs, so a dead Claude PID often gets reassigned to an
                // unrelated long-lived binary (Slack, mdworker, …). Without
                // the identity check we'd surface that recycled PID as a
                // phantom Claude session. Mirror the rule used for `-busy`
                // markers (see refreshHookBusy at line ~489).
                if !isLiveClaudeProcess(pid: info.pid) {
                    try? FileManager.default.removeItem(at: file)
                    continue
                }
                pids.insert(info.pid)
                if !info.sessionId.isEmpty {
                    hookInfo[info.pid] = HookInfo(
                        sessionId: info.sessionId,
                        cwd: info.cwd,
                        source: info.source,
                        runtime: info.runtime,
                        container: info.container
                    )
                }
            }
        }
        hookInfoByPID = hookInfo

        // Deliberately NO process-name discovery here.
        //
        // This used to add every PID that `pgrep -x claude` returned,
        // "regardless of hook state". A process name is not evidence of a
        // Claude Code session, and the cost of pretending otherwise was
        // paid by the user: Clyde's own HookScriptTests spawn a symlink
        // named `claude` (the hook looks for an ancestor with that name, so
        // the fixture must have it), and running the suite filled the panel
        // with phantom rows named after the package directory. They never
        // showed as working — no markers exist for a process that is not a
        // session — and they lingered as "Ended" ghosts once the test
        // process exited. Any binary called `claude` on the user's PATH did
        // the same thing.
        //
        // A session now appears when the hook writes something for it, which
        // is the same evidence the rest of this class already treats as the
        // sole source of truth for status. Sessions that predate Clyde's
        // install surface on their first hook event of any kind — see the
        // -info backfill in clyde-hook.sh, which covers tool calls and not
        // just prompts, so an actively working session appears in seconds.
        return pids.sorted()
    }

    private struct ParsedInfo {
        let pid: pid_t
        let sessionId: String
        let cwd: String
        let source: String
        let runtime: String
        let container: String
    }

    private func readInfoFile(file: URL) -> ParsedInfo? {
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pidValue = json["pid"] as? Int else {
            return nil
        }
        let sessionId = (json["session_id"] as? String) ?? ""
        let cwd = (json["cwd"] as? String) ?? ""
        let source = (json["source"] as? String) ?? ""
        let runtime = (json["runtime"] as? String) ?? ""
        let container = (json["container"] as? String) ?? ""
        return ParsedInfo(
            pid: pid_t(pidValue),
            sessionId: sessionId,
            cwd: cwd,
            source: source,
            runtime: runtime,
            container: container
        )
    }

    /// Sweep `-info` files for runtime metadata. Cheap (one stat + small
    /// JSON parse per file) and called from both poll() and
    /// pollHookState() so the liveness check sees correct runtime
    /// labels regardless of which code path runs first.
    private func refreshPIDRuntimes() {
        var next: [pid_t: String] = [:]
        if let files = try? FileManager.default.contentsOfDirectory(
            at: stateDir, includingPropertiesForKeys: nil
        ) {
            for file in files where file.lastPathComponent.hasSuffix("-info") {
                guard let info = readInfoFile(file: file), !info.runtime.isEmpty else { continue }
                next[info.pid] = info.runtime
            }
        }
        pidRuntimeByPID = next
    }

    /// Classify a Claude session's state. Pure hook-driven — there's no
    /// process inspection, no child filtering, no heuristics. The hook
    /// either says "busy" (marker file exists) or it doesn't (idle).
    func classifyStatus(pid: pid_t) async -> SessionStatus {
        return hookBusyPIDs.contains(pid) ? .busy : .idle
    }

    /// Detect project dir for a pgrep-discovered claude PID. The current
    /// `claude` binary keeps its working directory pointed at the project
    /// root, so `lsof -d cwd` gives a clean answer. Older builds (and any
    /// future ones that chdir to `/`) fall through to the `.claude/settings`
    /// heuristic: scan the process's open files and use the first project
    /// whose `.claude/settings*` is loaded. The heuristic still happily
    /// matches `~/.claude/settings.json` (the global config) which is why
    /// it used to mislabel real project sessions as "Home" — we explicitly
    /// reject `NSHomeDirectory()` here so the caller falls back to
    /// "Untitled session" rather than a misleading project name.
    func detectCWD(pid: pid_t) async -> String {
        if let output = try? await shell.run(
            "lsof -a -p \(pid) -d cwd -Fn 2>/dev/null"
        ) {
            for line in output.split(separator: "\n") where line.first == "n" {
                let path = String(line.dropFirst())
                if !path.isEmpty && path != "/" {
                    return path
                }
            }
        }

        guard let output = try? await shell.run(
            "lsof -p \(pid) -Fn 2>/dev/null | grep -m1 '/.claude/settings'"
        ), !output.isEmpty else {
            return ""
        }
        let path = String(output.dropFirst()) // strip leading 'n'
        guard let range = path.range(of: "/.claude/") else { return "" }
        let candidate = String(path[path.startIndex..<range.lowerBound])
        // Drop the home-directory match: it's the global config, not a
        // project, and rendering it as "Home" obscures the real cwd that
        // pgrep-only sessions usually have somewhere under `_Projects/…`.
        return candidate == NSHomeDirectory() ? "" : candidate
    }

    func poll() async {
        // Refresh hook-driven busy state inline so a single poll() call is
        // self-contained: discover PIDs and classify them based on the
        // current on-disk markers, without depending on the FSEvents watcher
        // having run first. This makes the function deterministic for tests
        // and removes any chance of a race on startup.
        refreshPIDRuntimes()
        refreshHookBusyPIDs()
        refreshHookErrors()
        refreshHookTools()
        refreshHookPlans()
        refreshHookLastMessages()
        refreshHookCommands()
        refreshHookWorktrees()
        refreshHookAgents()

        let pids = await discoverPIDs()
        let now = Date()

        // Capture the previous live PIDs so we can promote disappearances
        // to ghost rows that linger briefly in the UI.
        let previousLivePIDs = Set(sessions.lazy.filter { !$0.isGhost }.map(\.pid))

        var updatedSessions: [Session] = []
        updatedSessions.reserveCapacity(pids.count)

        // Sessions identified by their stable session_id that we revived
        // from a ghost row this tick. The linger loop below uses this set
        // to skip carrying the now-stale ghost forward — without this, a
        // `claude --resume` ends up showing two rows for the same session
        // (the ghost from the old PID, plus the freshly-revived live row).
        var revivedSessionIds: Set<String> = []

        // Resume-flicker mitigation. When `claude --resume` runs, the new
        // claude binary is visible to `pgrep -x claude` ~hundreds of ms
        // before its `SessionStart` hook fires and writes the `-info`
        // file. During that window the new PID has no `hookInfoByPID`
        // entry, so we don't know its `sessionId`, so the revival path
        // can't fire — a brand-new pgrep-only row appears alongside the
        // existing ghost and the user briefly sees two rows for what is
        // logically one session.
        //
        // Mitigation: when a pgrep-only PID first shows up AND there's a
        // recently-ended ghost on screen (within `resumeDeferWindow`),
        // skip it for ONE tick. By the next poll the SessionStart hook
        // has typically fired, hookInfoByPID has the session_id, and the
        // revival path runs cleanly with no flash. The deferral is
        // strictly one tick per PID — second appearance is always
        // rendered, so a genuine non-resume new session is delayed by
        // at most one polling interval.
        let hasRecentGhost = sessions.contains { session in
            guard session.isGhost, let endedAt = session.endedAt else { return false }
            return now.timeIntervalSince(endedAt) < Self.resumeDeferWindow
        }
        var nextDeferred: Set<pid_t> = []

        for pid in pids {
            let info = hookInfoByPID[pid]
            let isPgrepOnly = info == nil

            if isPgrepOnly && hasRecentGhost && !deferredPgrepPIDs.contains(pid) {
                // First time we see this pgrep-only PID alongside a
                // recent ghost — defer one tick.
                nextDeferred.insert(pid)
                continue
            }

            let newStatus = await classifyStatus(pid: pid)
            // Detect revival BEFORE updatedSession runs, because
            // updatedSession() returns the freshly-revived row and
            // we lose the "was a ghost" signal once the row is live.
            if let info,
               !info.sessionId.isEmpty,
               sessions.contains(where: { $0.sessionId == info.sessionId && $0.isGhost })
            {
                revivedSessionIds.insert(info.sessionId)
            }
            let session = await updatedSession(pid: pid, newStatus: newStatus)
            updatedSessions.append(session)
        }

        deferredPgrepPIDs = nextDeferred

        // Promote sessions that vanished this cycle into ghosts. They keep
        // their last metadata so the row stays meaningful, just labelled
        // "ended Xm ago" until the linger window expires.
        let livePIDs = Set(updatedSessions.map(\.pid))
        for vanished in previousLivePIDs.subtracting(livePIDs) {
            if let last = sessions.first(where: { $0.pid == vanished && !$0.isGhost }) {
                var ghost = last
                ghost.status = .idle
                ghost.endedAt = now
                ghost.statusChangedAt = now
                updatedSessions.append(ghost)
            }
        }

        // Carry forward existing ghosts that are still within the linger window.
        for existingGhost in sessions where existingGhost.isGhost {
            // Skip ghosts whose session_id was just revived by a resumed
            // session. Otherwise the resumed live row and the stale ghost
            // would coexist in the UI for the full linger window.
            if let sid = existingGhost.sessionId, revivedSessionIds.contains(sid) {
                continue
            }
            if let endedAt = existingGhost.endedAt,
               now.timeIntervalSince(endedAt) < AppConstants.endedSessionLinger,
               !livePIDs.contains(existingGhost.pid) {
                updatedSessions.append(existingGhost)
            }
        }

        // Sort: live sessions by recency (newest first), then ghosts at the bottom.
        sessions = updatedSessions.sorted { lhs, rhs in
            if lhs.isGhost != rhs.isGhost { return !lhs.isGhost }
            return lhs.statusChangedAt > rhs.statusChangedAt
        }

        let liveSessions = sessions.filter { !$0.isGhost }
        if liveSessions.isEmpty {
            clydeState = .sleeping
        } else {
            clydeState = liveSessions.contains(where: { $0.status == .busy }) ? .busy : .idle
        }
    }

    /// Update an existing session or create a new one. Caches CWD detection.
    ///
    /// Lookup priority:
    ///   1. Match by PID against a live row (the common case — same
    ///      Claude process across polling ticks).
    ///   2. Match by `sessionId` against any row including ghosts. This
    ///      catches `claude --resume`: SessionEnd promoted the old PID
    ///      to a ghost, SessionStart fires with the SAME session_id but
    ///      a NEW PID. We must revive the ghost into the new live row
    ///      instead of leaving the ghost lingering and creating a
    ///      duplicate row for the new PID.
    ///   3. Otherwise, create a brand-new session.
    private func updatedSession(pid: pid_t, newStatus: SessionStatus) async -> Session {
        let info = hookInfoByPID[pid]

        // (1) PID match against live rows.
        if var existing = sessions.first(where: { $0.pid == pid && !$0.isGhost }) {
            // Backfill metadata from the hook info if it became available.
            if existing.sessionId == nil, let info {
                existing.sessionId = info.sessionId
            }
            // Always update cwd from hook info (not just when empty) so
            // CwdChanged events propagate the new project name live.
            if let info, !info.cwd.isEmpty {
                existing.workingDirectory = info.cwd
            } else if existing.workingDirectory.isEmpty {
                existing.workingDirectory = await detectCWD(pid: pid)
            }
            if let info {
                existing.runtime = info.runtime
                existing.container = info.container
            }

            if existing.status != newStatus {
                existing.status = newStatus
                existing.statusChangedAt = Date()
                if newStatus == .idle {
                    onSessionBecameIdle?(existing)
                }
            }
            existing.errorReason = hookErrorByPID[pid]
            existing.activeTool = hookToolByPID[pid]
            existing.activePlan = hookPlanByPID[pid]
            existing.activeToolCount = hookToolCountByPID[pid] ?? 0
            existing.lastMessage = hookLastMessageByPID[pid]
            existing.activeCommand = hookCommandByPID[pid]
            existing.worktreeName = worktreeName(forPID: pid)
            existing.activeSubagents = hookAgentsByPID[pid] ?? []
            return existing
        }

        // (2) sessionId match — revival path for `claude --resume`.
        if let sid = info?.sessionId, !sid.isEmpty,
           var revived = sessions.first(where: { $0.sessionId == sid })
        {
            revived.pid = pid
            revived.endedAt = nil
            revived.status = newStatus
            revived.statusChangedAt = Date()
            if let info, !info.cwd.isEmpty {
                revived.workingDirectory = info.cwd
            }
            if let info {
                revived.runtime = info.runtime
                revived.container = info.container
            }
            revived.activeTool = hookToolByPID[pid]
            revived.activePlan = hookPlanByPID[pid]
            revived.activeToolCount = hookToolCountByPID[pid] ?? 0
            revived.lastMessage = hookLastMessageByPID[pid]
            revived.activeCommand = hookCommandByPID[pid]
            revived.worktreeName = worktreeName(forPID: pid)
            revived.activeSubagents = hookAgentsByPID[pid] ?? []
            return revived
        }

        // (3) Brand-new session.
        let cwd = info?.cwd.isEmpty == false ? info!.cwd : await detectCWD(pid: pid)
        var fresh = Session(
            pid: pid,
            workingDirectory: cwd,
            status: newStatus,
            sessionId: info?.sessionId
        )
        fresh.runtime = info?.runtime ?? ""
        fresh.container = info?.container ?? ""
        fresh.activeTool = hookToolByPID[pid]
        fresh.activePlan = hookPlanByPID[pid]
        fresh.activeToolCount = hookToolCountByPID[pid] ?? 0
        fresh.lastMessage = hookLastMessageByPID[pid]
        fresh.activeCommand = hookCommandByPID[pid]
        fresh.worktreeName = worktreeName(forPID: pid)
        fresh.activeSubagents = hookAgentsByPID[pid] ?? []
        return fresh
    }

    func updatePollingInterval(_ interval: TimeInterval) {
        pollingInterval = max(1, min(interval, 10))
    }

    /// Snapshot of -info filenames seen on the previous tick. Used to detect
    /// session arrivals/departures so we can kick the main poll immediately.
    private var lastInfoFilenames: Set<String> = []

    /// True iff `pid` is alive AND (for native host sessions) looks
    /// like a Claude Code process. For Cleat-sandboxed sessions the
    /// recorded PID is the container's init process on the host
    /// (typically `containerd-shim` / `docker-init`), which would
    /// fail the `argv[0] == claude` identity check; in that case we
    /// fall back to a plain liveness probe via `kill(pid, 0)`. The
    /// PID-recycling concern that motivated the identity check
    /// doesn't apply: Linux/Docker keep the container init PID
    /// pinned for the container's lifetime, and we re-derive the PID
    /// on every hook event via the cleat resolver, so a stale PID
    /// can't outlive its container.
    private func isLiveClaudeProcess(pid: pid_t) -> Bool {
        if pidRuntimeByPID[pid] == "cleat" {
            return kill(pid, 0) == 0
        }
        return isLiveClaudeProcessCheck(pid)
    }

    /// Default identity check, used outside tests.
    ///
    /// History: this used to compare `proc_name(pid)` against the literal
    /// "claude", on the assumption that the kernel's exec image short name
    /// matches the binary name on disk. That broke for the real Claude Code
    /// CLI because the binary lives at `.../claude/<version>/cli.js` (or
    /// similar), so `proc_name` returns the *version directory* (e.g.
    /// "2.1.96"), not "claude". Every live Claude session was therefore
    /// classified as not-a-claude, every -busy marker was nuked from disk
    /// the instant the hook wrote it, and the UI never saw "in progress".
    ///
    /// New rule: a marker is valid iff
    ///   1. the PID is still alive (`kill(pid, 0) == 0`), AND
    ///   2. its argv[0] basename matches "claude" (via `ps -o comm=`,
    ///      which on macOS reports argv[0], not the exec image name).
    ///
    /// Falling back to `ps` is fine here — this only runs on hook events
    /// or the 1 s state-watch tick, so it's a few invocations per session
    /// per second worst case. We still need *some* identity check to
    /// defend against the PID-recycling case (the recycled PID belonging
    /// to a long-lived non-Claude binary that outlives the hook's Stop).
    @Sendable
    nonisolated static func defaultIsLiveClaudeProcess(pid: pid_t) -> Bool {
        // Cheap liveness gate first — `kill(pid, 0)` is a single syscall.
        guard kill(pid, 0) == 0 else { return false }

        // Identity check via argv[0]. We deliberately do NOT use
        // `proc_name` here (see history above). `ps -o comm=` returns
        // the argv[0] basename, which is "claude" for the real CLI
        // regardless of where the binary lives on disk.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-p", "\(pid)", "-o", "comm="]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            // ps unavailable / blocked → trust the liveness check above
            // rather than nuking the marker. False negatives here cause
            // visible UI breakage; false positives are essentially
            // harmless (the marker self-cleans on next Stop / death).
            return true
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let raw = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // `ps -o comm=` on macOS prints the absolute path of argv[0]
        // (or just the basename, depending on how the process was
        // launched). Match on the trailing path component.
        let basename = (raw as NSString).lastPathComponent
        return basename == "claude"
    }

    /// Reads -busy markers from disk into `hookBusyPIDs`. Pure side-effect on
    /// `hookBusyPIDs` — doesn't kick a poll. Safe to call from poll() itself.
    @discardableResult
    private func refreshHookBusyPIDs() -> Bool {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: stateDir,
            includingPropertiesForKeys: nil
        ) else {
            let changed = !hookBusyPIDs.isEmpty
            if changed { hookBusyPIDs = [] }
            return changed
        }

        // Sticky semantics: a -busy marker is valid for as long as its
        // owning process is alive. The hook script removes it on Stop /
        // StopFailure / SessionEnd / interrupt; we remove it here only
        // when the PID is gone. No mtime expiry — long pure-text turns
        // and long permission prompts must not silently flip to idle.
        var present: Set<pid_t> = []
        for file in files where file.lastPathComponent.hasSuffix("-busy") {
            guard let pid = readMarkerPID(file: file) else {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            if !isLiveClaudeProcess(pid: pid) {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            present.insert(pid)
        }

        let changed = present != hookBusyPIDs
        if changed { hookBusyPIDs = present }
        return changed
    }

    /// Reads `-error` marker files written by the StopFailure hook.
    /// Returns true if the set changed since last call.
    @discardableResult
    private func refreshHookErrors() -> Bool {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: stateDir, includingPropertiesForKeys: nil
        ) else {
            let changed = !hookErrorByPID.isEmpty
            if changed { hookErrorByPID = [:] }
            return changed
        }
        var errors: [pid_t: String] = [:]
        for file in files where file.lastPathComponent.hasSuffix("-error") {
            guard let data = try? Data(contentsOf: file),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pidValue = json["pid"] as? Int,
                  let reason = json["reason"] as? String else {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            let pid = pid_t(pidValue)
            if kill(pid, 0) != 0 {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            errors[pid] = reason
        }
        let changed = errors != hookErrorByPID
        if changed { hookErrorByPID = errors }
        return changed
    }


    /// Reads `-tool` marker files written by the PreToolUse hook.
    /// Returns true if the dictionary changed since last call.
    @discardableResult
    private func refreshHookTools() -> Bool {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: stateDir, includingPropertiesForKeys: nil
        ) else {
            let changed = !hookToolByPID.isEmpty
            if changed { hookToolByPID = [:] }
            return changed
        }
        var tools: [pid_t: ActiveTool] = [:]
        var counts: [pid_t: Int] = [:]

        // Preferred shape (hook v30+): one slot per tool_use_id, so a
        // batch of parallel calls is represented honestly. The oldest
        // call labels the row; the count drives the "N tools" variant.
        for dir in files where dir.lastPathComponent.hasSuffix("-tools") {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }

            // Same reclamation as `-agents/`: slots are pruned by PID
            // liveness, but nothing ever removed the directory, so a
            // session killed without SessionEnd left an empty one behind
            // for good. Orphan means "no `-info` on disk" — not "the
            // liveness probe said no" — because a cleat session fails the
            // identity check while being perfectly alive.
            let sid = String(dir.lastPathComponent.dropLast("-tools".count))
            guard FileManager.default.fileExists(
                atPath: stateDir.appendingPathComponent("\(sid)-info").path) else {
                try? FileManager.default.removeItem(at: dir)
                ClydeLog.hooks.info("Reclaimed orphaned -tools dir sid=\(sid, privacy: .public)")
                continue
            }

            guard let slots = try? FileManager.default.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: nil) else { continue }
            for slot in slots where slot.pathExtension == "json" {
                guard let data = try? Data(contentsOf: slot),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let pidValue = json["pid"] as? Int,
                      let toolName = json["tool_name"] as? String,
                      !toolName.isEmpty,
                      let startedAt = json["started_at"] as? Int else {
                    try? FileManager.default.removeItem(at: slot)
                    continue
                }
                let pid = pid_t(pidValue)
                if kill(pid, 0) != 0 {
                    try? FileManager.default.removeItem(at: slot)
                    continue
                }
                let started = Date(timeIntervalSince1970: TimeInterval(startedAt))
                counts[pid, default: 0] += 1
                let candidate = ActiveTool(
                    toolName: toolName,
                    summary: (json["summary"] as? String) ?? "",
                    startedAt: started
                )
                if let existing = tools[pid], existing.startedAt <= started { continue }
                tools[pid] = candidate
            }
        }

        for file in files where file.lastPathComponent.hasSuffix("-tool") {
            guard let data = try? Data(contentsOf: file),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pidValue = json["pid"] as? Int,
                  let toolName = json["tool_name"] as? String,
                  !toolName.isEmpty,
                  let startedAt = json["started_at"] as? Int else {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            let pid = pid_t(pidValue)
            if kill(pid, 0) != 0 {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            // Legacy single-slot marker from a pre-v30 hook. Never
            // overrides the richer per-call slots above.
            if tools[pid] != nil { continue }
            counts[pid, default: 0] += 1
            let summary = (json["summary"] as? String) ?? ""
            tools[pid] = ActiveTool(
                toolName: toolName,
                summary: summary,
                startedAt: Date(timeIntervalSince1970: TimeInterval(startedAt))
            )
        }
        let changed = tools != hookToolByPID || counts != hookToolCountByPID
        if changed {
            hookToolByPID = tools
            hookToolCountByPID = counts
        }
        return changed
    }

    /// Reads `-plan` marker files written by the TaskCreated /
    /// TaskCompleted hooks. Returns true if the dictionary changed.
    @discardableResult
    private func refreshHookPlans() -> Bool {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: stateDir, includingPropertiesForKeys: nil
        ) else {
            let changed = !hookPlanByPID.isEmpty
            if changed { hookPlanByPID = [:] }
            return changed
        }
        var plans: [pid_t: ActivePlan] = [:]
        for file in files where file.lastPathComponent.hasSuffix("-plan") {
            guard let data = try? Data(contentsOf: file),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pidValue = json["pid"] as? Int,
                  let taskCount = json["task_count"] as? Int,
                  let doneCount = json["done_count"] as? Int,
                  let startedAt = json["started_at"] as? Int else {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            let pid = pid_t(pidValue)
            if kill(pid, 0) != 0 {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            plans[pid] = ActivePlan(
                taskCount: taskCount,
                doneCount: doneCount,
                startedAt: Date(timeIntervalSince1970: TimeInterval(startedAt))
            )
        }
        let changed = plans != hookPlanByPID
        if changed { hookPlanByPID = plans }
        return changed
    }

    /// Reads `state/<sid>-worktree` markers written by WorktreeCreate.
    private func refreshHookWorktrees() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: stateDir, includingPropertiesForKeys: nil
        ) else {
            hookWorktreeByPID = [:]
            return
        }
        var worktrees: [pid_t: (name: String, path: String)] = [:]
        for file in files where file.lastPathComponent.hasSuffix("-worktree") {
            guard let data = try? Data(contentsOf: file),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pidValue = json["pid"] as? Int,
                  let name = json["name"] as? String,
                  !name.isEmpty else {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            let pid = pid_t(pidValue)
            if kill(pid, 0) != 0 {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            worktrees[pid] = (name: name, path: (json["path"] as? String) ?? "")
        }
        hookWorktreeByPID = worktrees
    }

    /// The worktree name for `pid`. The marker's presence is
    /// authoritative and deliberately not re-checked against `cwd`: the
    /// hook re-derives the marker from the live cwd on every event and
    /// deletes it as soon as the session is outside, so "marker exists"
    /// already means "inside the worktree right now". Our own `cwd` is
    /// the unreliable half — entering a worktree emits no `CwdChanged`,
    /// so `-info` keeps the parent repo's path for the whole session and
    /// gating on it dropped the badge on every real worktree session.
    private func worktreeName(forPID pid: pid_t) -> String {
        hookWorktreeByPID[pid]?.name ?? ""
    }

    /// Reads `state/<sid>-command` markers written by UserPromptExpansion.
    @discardableResult
    private func refreshHookCommands() -> Bool {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: stateDir, includingPropertiesForKeys: nil
        ) else {
            let changed = !hookCommandByPID.isEmpty
            if changed { hookCommandByPID = [:] }
            return changed
        }
        var commands: [pid_t: String] = [:]
        for file in files where file.lastPathComponent.hasSuffix("-command") {
            guard let data = try? Data(contentsOf: file),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pidValue = json["pid"] as? Int,
                  let command = json["command"] as? String,
                  !command.isEmpty else {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            let pid = pid_t(pidValue)
            if kill(pid, 0) != 0 {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            commands[pid] = command
        }
        let changed = commands != hookCommandByPID
        if changed { hookCommandByPID = commands }
        return changed
    }

    /// Reads `state/<sid>-lastmsg` markers written by Stop. Returns true
    /// if the dictionary changed since last call.
    @discardableResult
    private func refreshHookLastMessages() -> Bool {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: stateDir, includingPropertiesForKeys: nil
        ) else {
            let changed = !hookLastMessageByPID.isEmpty
            if changed { hookLastMessageByPID = [:] }
            return changed
        }
        var messages: [pid_t: String] = [:]
        for file in files where file.lastPathComponent.hasSuffix("-lastmsg") {
            guard let data = try? Data(contentsOf: file),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pidValue = json["pid"] as? Int,
                  let message = json["message"] as? String,
                  !message.isEmpty else {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            let pid = pid_t(pidValue)
            if kill(pid, 0) != 0 {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            messages[pid] = message
        }
        let changed = messages != hookLastMessageByPID
        if changed { hookLastMessageByPID = messages }
        return changed
    }

    /// Reads `state/<sid>-agents/*.json` marker files written by PreToolUse(Task).
    /// Returns true if the dictionary changed since last call.
    @discardableResult
    private func refreshHookAgents() -> Bool {
        let cutoff = Date().addingTimeInterval(-30 * 60)
        var byPID: [pid_t: [ActiveSubagent]] = [:]

        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: stateDir, includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            let changed = !hookAgentsByPID.isEmpty
            if changed { hookAgentsByPID = [:] }
            return changed
        }

        for entry in entries where entry.lastPathComponent.hasSuffix("-agents") {
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            guard isDir else { continue }
            let sid = String(entry.lastPathComponent.dropLast("-agents".count))

            // Reclaim the directory of a session that is gone. A session
            // that ends cleanly has its `-agents/` removed by SessionEnd;
            // one that is killed or crashes never emits it and leaves the
            // directory behind forever, because the loop below skips any
            // session it can't resolve to a live PID — so the only case
            // that produces litter was the only case never collected.
            //
            // Orphan detection keys on `-info` being absent rather than on
            // the liveness probe: a cleat-sandboxed session fails the
            // identity check while being perfectly alive, and deleting a
            // live session's agents is far worse than leaving litter. The
            // `-info` file is written by SessionStart and removed by
            // SessionEnd, and `discoverPIDs` prunes it for dead PIDs, so
            // its absence is the honest signal.
            let infoURL = stateDir.appendingPathComponent("\(sid)-info")
            guard FileManager.default.fileExists(atPath: infoURL.path) else {
                try? FileManager.default.removeItem(at: entry)
                ClydeLog.hooks.info("Reclaimed orphaned -agents dir sid=\(sid, privacy: .public)")
                continue
            }

            guard let parentPID = parentPIDForSessionID(sid) else { continue }

            guard let files = try? FileManager.default.contentsOfDirectory(
                at: entry, includingPropertiesForKeys: nil
            ) else { continue }

            var agents: [ActiveSubagent] = []
            for file in files where file.pathExtension == "json" {
                // `agent_id` once SubagentStart has claimed the entry,
                // `tool_use_id` while it is still pending. The two hook
                // events share no identifier, so a claimed record has no
                // tool_use_id to fall back on.
                guard let data = try? Data(contentsOf: file),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let id = (json["agent_id"] as? String) ?? (json["tool_use_id"] as? String),
                      let type = json["subagent_type"] as? String,
                      let startedAt = json["started_at"] as? Int else {
                    ClydeLog.hooks.info("Skipping malformed -agents file \(file.lastPathComponent, privacy: .public)")
                    continue
                }
                let started = Date(timeIntervalSince1970: TimeInterval(startedAt))
                guard started >= cutoff else {
                    // Delete rather than skip. Skipping kept the file on
                    // disk forever and re-logged this line on every poll —
                    // 1200 lines an hour at a 3s interval — while the disk
                    // never got its space back.
                    try? FileManager.default.removeItem(at: file)
                    ClydeLog.hooks.info("Reclaimed stale subagent entry id=\(id, privacy: .public)")
                    continue
                }
                let summary = (json["summary"] as? String) ?? ""
                let isIdle = (json["idle"] as? Bool) ?? false
                agents.append(ActiveSubagent(id: id, type: type, summary: summary, startedAt: started, isIdle: isIdle))
            }
            if !agents.isEmpty {
                byPID[parentPID] = agents.sorted { $0.startedAt < $1.startedAt }
            }
        }

        let changed = byPID != hookAgentsByPID
        if changed { hookAgentsByPID = byPID }
        return changed
    }

    /// Maps a hook session ID (the prefix of marker filenames) to the PID
    /// recorded by its `-info` file. Returns nil if the info file is gone or
    /// the PID it points to is not live.
    private func parentPIDForSessionID(_ sid: String) -> pid_t? {
        let info = stateDir.appendingPathComponent("\(sid)-info")
        guard let data = try? Data(contentsOf: info),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pidValue = json["pid"] as? Int else { return nil }
        let pid = pid_t(pidValue)
        return isLiveClaudeProcess(pid: pid) ? pid : nil
    }

    /// Watches the state dir for changes via FSEvents and triggers a re-poll.
    /// Cheap (just dir listing + mtime reads) so it runs independently of the
    /// main classification cycle.
    private func pollHookState() {
        refreshPIDRuntimes()
        let busyChanged = refreshHookBusyPIDs()
        let errorChanged = refreshHookErrors()
        let toolChanged = refreshHookTools()
        let planChanged = refreshHookPlans()
        let lastMsgChanged = refreshHookLastMessages()
        _ = refreshHookCommands()
        refreshHookWorktrees()
        let agentsChanged = refreshHookAgents()
        _ = lastMsgChanged

        // Detect session arrivals/departures via -info file presence so a new
        // session is reflected in the UI immediately instead of waiting for
        // the next main poll tick.
        let infoFilenames: Set<String>
        if let files = try? FileManager.default.contentsOfDirectory(
            at: stateDir, includingPropertiesForKeys: nil
        ) {
            infoFilenames = Set(files.lazy
                .map(\.lastPathComponent)
                .filter { $0.hasSuffix("-info") })
        } else {
            infoFilenames = []
        }
        let infoChanged = infoFilenames != lastInfoFilenames
        lastInfoFilenames = infoFilenames

        // Fast path: when only the busy state of an EXISTING session
        // flipped (no new info files = no new sessions), reflect that
        // on the in-memory sessions array immediately, synchronously.
        // This avoids waiting on the full `poll()` cycle (which shells
        // out to pgrep — ~50–200 ms of latency before the UI catches
        // up to the hook event).
        if busyChanged || errorChanged || toolChanged || planChanged || agentsChanged {
            applyBusyStateToSessions()
        }

        if busyChanged || infoChanged || errorChanged || toolChanged || planChanged || agentsChanged {
            Task { await self.poll() }
        }
    }

    /// Synchronously update the `status` of every live session in the
    /// in-memory `sessions` array based on the current `hookBusyPIDs`.
    /// Does not touch ghosts. Used as the fast path from
    /// `pollHookState` so the UI reflects hook events instantly.
    private func applyBusyStateToSessions() {
        var changed = false
        var updated = sessions
        for index in updated.indices where !updated[index].isGhost {
            let pid = updated[index].pid
            let newStatus: SessionStatus = hookBusyPIDs.contains(pid) ? .busy : .idle
            if updated[index].status != newStatus {
                updated[index].status = newStatus
                updated[index].statusChangedAt = Date()
                changed = true
                if newStatus == .idle {
                    onSessionBecameIdle?(updated[index])
                }
            }
            // Apply error + subagent state inline for fast UI feedback.
            let newError = hookErrorByPID[pid]
            if updated[index].errorReason != newError {
                updated[index].errorReason = newError
                changed = true
            }
            let newTool = hookToolByPID[pid]
            if updated[index].activeTool != newTool {
                updated[index].activeTool = newTool
                changed = true
            }
            let newToolCount = hookToolCountByPID[pid] ?? 0
            if updated[index].activeToolCount != newToolCount {
                updated[index].activeToolCount = newToolCount
                changed = true
            }
            let newPlan = hookPlanByPID[pid]
            if updated[index].activePlan != newPlan {
                updated[index].activePlan = newPlan
                changed = true
            }
            let newLastMessage = hookLastMessageByPID[pid]
            if updated[index].lastMessage != newLastMessage {
                updated[index].lastMessage = newLastMessage
                changed = true
            }
            let newCommand = hookCommandByPID[pid]
            if updated[index].activeCommand != newCommand {
                updated[index].activeCommand = newCommand
                changed = true
            }
            let newWorktree = worktreeName(forPID: pid)
            if updated[index].worktreeName != newWorktree {
                updated[index].worktreeName = newWorktree
                changed = true
            }
            let newAgents = hookAgentsByPID[pid] ?? []
            if updated[index].activeSubagents != newAgents {
                updated[index].activeSubagents = newAgents
                changed = true
            }
        }
        if changed {
            sessions = updated
            let liveSessions = sessions.filter { !$0.isGhost }
            if liveSessions.isEmpty {
                clydeState = .sleeping
            } else {
                clydeState = liveSessions.contains(where: { $0.status == .busy }) ? .busy : .idle
            }
        }
    }

    /// Reads `{ "pid": <int>, ... }` from a marker file. Tolerates the legacy
    /// format where the filename was the PID and the body was a timestamp string.
    private func readMarkerPID(file: URL) -> pid_t? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        // New format: JSON with "pid" field.
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let pidValue = json["pid"] as? Int {
            return pid_t(pidValue)
        }
        // Legacy format fallback: filename is the PID itself.
        let base = file.lastPathComponent.replacingOccurrences(of: "-busy", with: "")
        return pid_t(base)
    }

    func startPolling() {
        // Prime hookBusyPIDs synchronously BEFORE the first poll() so the
        // initial classification sees hook-derived state instead of falling
        // back to pgrep on an empty set.
        pollHookState()
        startStateDirWatcher()

        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                let interval = self?.pollingInterval ?? AppConstants.defaultPollingInterval
                try? await Task.sleep(for: .seconds(interval))
            }
        }

        // Backup periodic tick (1 s): handles linger expiry that has no
        // FSEvents trigger (no file change happens when linger times out).
        stateWatchTask?.cancel()
        stateWatchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.pollHookState()
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
        stateWatchTask?.cancel()
        stateWatchTask = nil
        stopStateDirWatcher()
    }

    /// Watches `~/.clyde/state/` for any directory entry change (file added,
    /// removed, renamed) via DispatchSource. Fires `pollHookState` immediately
    /// so a hook write is reflected in the UI within ~1 ms.
    private func startStateDirWatcher() {
        stopStateDirWatcher()

        // Make sure the directory exists before opening — otherwise open() fails.
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)

        let fd = open(stateDir.path, O_EVTONLY)
        guard fd >= 0 else {
            ClydeLog.process.error("Failed to open state dir for FSEvents watching")
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend, .attrib],
            queue: DispatchQueue.main
        )
        source.setEventHandler { [weak self] in
            self?.pollHookState()
        }
        // Capture `fd` rather than reading it back off the monitor.
        // Cancellation is asynchronous: by the time this runs, a restart
        // may already have opened a replacement descriptor and stored it
        // where the old value used to be, and this handler would close
        // that one instead. Capturing also means the descriptor is
        // released when the monitor is deallocated without stopPolling()
        // — a `weak self` here is nil exactly then, so the fd leaked.
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        stateDirSource = source
        ClydeLog.process.info("Started FSEvents watcher on \(self.stateDir.path, privacy: .public)")
    }

    private func stopStateDirWatcher() {
        stateDirSource?.cancel()
        stateDirSource = nil
    }
}
