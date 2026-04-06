import Foundation
import Combine
import Darwin

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
    private(set) var pollingInterval: TimeInterval

    /// Fired once per session when it transitions from busy to idle.
    var onSessionBecameIdle: ((Session) -> Void)?

    private var pollTask: Task<Void, Never>?
    private var stateWatchTask: Task<Void, Never>?

    /// PIDs the hook state watcher currently considers busy.
    /// This is updated by a fast (~500ms) file-system poll on `~/.clyde/state/`,
    /// decoupled from the heavier child-process poll.
    private var hookBusyPIDs: Set<pid_t> = []

    init(shell: ShellExecutor = RealShellExecutor(), pollingInterval: TimeInterval = AppConstants.defaultPollingInterval) {
        self.shell = shell
        self.pollingInterval = pollingInterval
    }

    deinit {
        pollTask?.cancel()
    }

    func discoverPIDs() async -> [pid_t] {
        // Primary: read PIDs from hook-written -info files. Sessions started
        // after the hook was installed are tracked here, with no polling.
        var hookPIDs: Set<pid_t> = []
        if let infoFiles = try? FileManager.default.contentsOfDirectory(
            at: AppPaths.stateDir,
            includingPropertiesForKeys: nil
        ) {
            for file in infoFiles where file.lastPathComponent.hasSuffix("-info") {
                guard let pid = readMarkerPID(file: file) else {
                    try? FileManager.default.removeItem(at: file)
                    continue
                }
                // Drop info files for dead Claude processes (crash without SessionEnd).
                if kill(pid, 0) != 0 && errno == ESRCH {
                    try? FileManager.default.removeItem(at: file)
                    continue
                }
                hookPIDs.insert(pid)
            }
        }

        // Fallback: pgrep for sessions that started before the hook was installed.
        var pgrepPIDs: Set<pid_t> = []
        if let output = try? await shell.run("pgrep -x claude"), !output.isEmpty {
            for line in output.components(separatedBy: "\n") {
                if let pid = Int32(line.trimmingCharacters(in: .whitespaces)) {
                    pgrepPIDs.insert(pid)
                }
            }
        }

        return Array(hookPIDs.union(pgrepPIDs))
    }

    /// Process names that Claude spawns as background helpers — not real tool work.
    /// These should NOT make the session count as busy.
    private static let ignoredChildCommands: Set<String> = ["caffeinate"]

    /// Classify a Claude session's state.
    ///
    /// Primary signal: hook-written busy marker at `~/.clyde/state/<pid>-busy`.
    /// The hook fires synchronously on `UserPromptSubmit` / `Stop`, so this is
    /// orders of magnitude more accurate than polling child processes.
    ///
    /// Fallback: if no fresh marker exists, fall back to child-process detection
    /// for sessions that predate the hook install or when the hook is missing.
    func classifyStatus(pid: pid_t) async -> SessionStatus {
        // 1. Hook-based detection via the fast state watcher.
        if hookBusyPIDs.contains(pid) {
            return .busy
        }

        // 2. Fallback: pgrep-based detection (legacy sessions / hook not installed).
        return await classifyStatusViaChildren(pid: pid)
    }

    /// Fallback classification: inspects child processes and filters known helpers.
    private func classifyStatusViaChildren(pid: pid_t) async -> SessionStatus {
        guard let pgrepOutput = try? await shell.run("pgrep -P \(pid)"),
              !pgrepOutput.isEmpty else {
            return .idle
        }

        let childPIDs = pgrepOutput
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard !childPIDs.isEmpty else { return .idle }

        // Inspect each child's state and full command line.
        // `ps -o stat=,args= -p <pid>` outputs e.g. "S+    /usr/bin/npm exec @angular/cli mcp".
        let psQuery = "ps -o stat=,args= -p \(childPIDs.joined(separator: ","))"
        guard let psOutput = try? await shell.run(psQuery) else {
            // If ps fails, fall back to the old behavior.
            return .busy
        }

        for line in psOutput.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            // Split into stat (first token) and args (rest of the line).
            let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2 else { continue }
            let stat = String(parts[0])
            let args = String(parts[1]).trimmingCharacters(in: .whitespaces)

            // Zombies don't count as real work.
            if stat.first == "Z" { continue }

            // Extract the binary name from the first arg for the ignore list.
            let firstArg = args.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? args
            let commandName = (firstArg as NSString).lastPathComponent
            if Self.ignoredChildCommands.contains(commandName) { continue }

            // MCP servers are long-lived helpers, not real tool executions.
            if Self.isLikelyMCPServer(args: args) { continue }

            // Found a real child doing real work.
            return .busy
        }

        return .idle
    }

    /// Conservative MCP server detection. Only matches well-known patterns so
    /// we don't accidentally filter out user shell commands that merely mention "mcp".
    private static func isLikelyMCPServer(args: String) -> Bool {
        let lower = args.lowercased()
        if lower.hasSuffix(" mcp") { return true }                 // "npm exec pkg mcp"
        if lower.contains("mcp-server") { return true }            // "mcp-server-filesystem"
        if lower.contains("/mcp/") { return true }                 // ".claude/mcp/xyz"
        if lower.contains("uvx mcp-") { return true }              // "uvx mcp-foo"
        if lower.contains("@modelcontextprotocol/") { return true } // official NPM scope
        return false
    }

    /// Detect project dir from claude's open .claude/settings files via lsof.
    /// Claude sets its cwd to /, so we can't use lsof -d cwd directly.
    func detectCWD(pid: pid_t) async -> String {
        guard let output = try? await shell.run(
            "lsof -p \(pid) -Fn 2>/dev/null | grep -m1 '/.claude/settings'"
        ), !output.isEmpty else {
            return ""
        }
        let path = String(output.dropFirst()) // strip leading 'n'
        if let range = path.range(of: "/.claude/") {
            return String(path[path.startIndex..<range.lowerBound])
        }
        return ""
    }

    func poll() async {
        let pids = await discoverPIDs()

        if pids.isEmpty {
            sessions = []
            clydeState = .sleeping
            return
        }

        var updatedSessions: [Session] = []
        updatedSessions.reserveCapacity(pids.count)

        for pid in pids {
            let newStatus = await classifyStatus(pid: pid)
            let session = await updatedSession(pid: pid, newStatus: newStatus)
            updatedSessions.append(session)
        }

        sessions = updatedSessions
        clydeState = sessions.contains(where: { $0.status == .busy }) ? .busy : .idle
    }

    /// Update an existing session or create a new one. Caches CWD detection.
    private func updatedSession(pid: pid_t, newStatus: SessionStatus) async -> Session {
        if var existing = sessions.first(where: { $0.pid == pid }) {
            // CWD detection is expensive — only do it once per session
            if existing.workingDirectory.isEmpty {
                existing.workingDirectory = await detectCWD(pid: pid)
            }

            if existing.status != newStatus {
                existing.status = newStatus
                existing.statusChangedAt = Date()
                if newStatus == .idle {
                    onSessionBecameIdle?(existing)
                }
            }
            return existing
        } else {
            let cwd = await detectCWD(pid: pid)
            return Session(pid: pid, workingDirectory: cwd, status: newStatus)
        }
    }

    func updatePollingInterval(_ interval: TimeInterval) {
        pollingInterval = max(1, min(interval, 10))
    }

    /// Snapshot of -info filenames seen on the previous tick. Used to detect
    /// session arrivals/departures so we can kick the main poll immediately.
    private var lastInfoFilenames: Set<String> = []

    /// Polls the hook state directory every 250 ms, maintaining `hookBusyPIDs`.
    /// Cheap (just dir listing + mtime reads) so it runs independently of the main poll.
    /// A busy marker "lingers" for `busyMarkerLinger` seconds after Stop deletes it,
    /// so short prompt→stop cycles remain visible in the UI.
    private func pollHookState() {
        let now = Date()
        let stateDir = AppPaths.stateDir
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: stateDir,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else {
            if !hookBusyPIDs.isEmpty { hookBusyPIDs = [] }
            return
        }

        // PIDs whose marker file is currently present on disk ("really busy").
        // Filename is keyed by Claude's session_id; the live PID lives in the
        // file content (JSON), so we read each file to extract it.
        var present: Set<pid_t> = []
        for file in files where file.lastPathComponent.hasSuffix("-busy") {
            guard let pid = readMarkerPID(file: file) else {
                // Unparseable marker — drop it.
                try? FileManager.default.removeItem(at: file)
                continue
            }

            // Discard markers whose PID no longer exists (Claude crashed without Stop).
            if kill(pid, 0) != 0 && errno == ESRCH {
                try? FileManager.default.removeItem(at: file)
                continue
            }

            if let attrs = try? file.resourceValues(forKeys: [.contentModificationDateKey]),
               let mtime = attrs.contentModificationDate,
               now.timeIntervalSince(mtime) < AppConstants.busyMarkerTimeout {
                present.insert(pid)
            } else {
                // Stale by mtime — remove so it doesn't keep showing up.
                try? FileManager.default.removeItem(at: file)
            }
        }

        // Refresh last-seen ONLY for genuinely-present PIDs. This is what makes
        // the linger window finite — once the marker disappears, last-seen freezes
        // and the linger countdown begins.
        for pid in present { hookBusyLastSeen[pid] = now }

        // Drop expired entries from the last-seen map.
        let linger = AppConstants.busyMarkerLinger
        hookBusyLastSeen = hookBusyLastSeen.filter { now.timeIntervalSince($0.value) < linger }

        // Effective busy = currently-present ∪ still-within-linger.
        var active = present
        for pid in hookBusyLastSeen.keys { active.insert(pid) }

        // Detect session arrivals/departures via -info file presence so a new
        // session is reflected in the UI within ~250 ms instead of waiting for
        // the next main poll tick.
        let infoFilenames = Set(files.lazy
            .map(\.lastPathComponent)
            .filter { $0.hasSuffix("-info") })
        let infoChanged = infoFilenames != lastInfoFilenames
        lastInfoFilenames = infoFilenames

        if active != hookBusyPIDs || infoChanged {
            hookBusyPIDs = active
            // Kick the main poll to re-classify immediately.
            Task { await self.poll() }
        }
    }

    private var hookBusyLastSeen: [pid_t: Date] = [:]

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
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                let interval = self?.pollingInterval ?? AppConstants.defaultPollingInterval
                try? await Task.sleep(for: .seconds(interval))
            }
        }

        stateWatchTask?.cancel()
        stateWatchTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.pollHookState()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
        stateWatchTask?.cancel()
        stateWatchTask = nil
    }
}
