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
    private let stateDir: URL
    private(set) var pollingInterval: TimeInterval

    /// Fired once per session when it transitions from busy to idle.
    var onSessionBecameIdle: ((Session) -> Void)?

    private var pollTask: Task<Void, Never>?
    private var stateWatchTask: Task<Void, Never>?
    private var stateDirSource: DispatchSourceFileSystemObject?
    private var stateDirFD: Int32 = -1

    /// PIDs the hook state watcher currently considers busy.
    /// This is updated by a fast (~500ms) file-system poll on `~/.clyde/state/`,
    /// decoupled from the heavier child-process poll.
    private var hookBusyPIDs: Set<pid_t> = []

    init(
        shell: ShellExecutor = RealShellExecutor(),
        pollingInterval: TimeInterval = AppConstants.defaultPollingInterval,
        stateDir: URL = AppPaths.stateDir
    ) {
        self.shell = shell
        self.pollingInterval = pollingInterval
        self.stateDir = stateDir
    }

    deinit {
        pollTask?.cancel()
    }

    /// Hook-derived metadata for discovered sessions, keyed by PID.
    /// Populated by `discoverPIDs()` from -info files and consumed by
    /// `updatedSession` when building Session structs.
    private(set) var hookInfoByPID: [pid_t: HookInfo] = [:]

    struct HookInfo: Equatable {
        let sessionId: String
        let cwd: String
    }

    func discoverPIDs() async -> [pid_t] {
        // Two sources, unified into one PID set:
        //
        //  1. -info files written by the SessionStart hook. These give us
        //     full session metadata (session_id + cwd) and classify
        //     accurately via -busy markers.
        //
        //  2. pgrep claude. Catches sessions that were already running when
        //     Clyde was installed (no -info file). They appear immediately
        //     as ready and only flip to busy if a UserPromptSubmit hook
        //     fires for them (which it will the next time the user types).
        //
        // CRITICAL: pgrep is ONLY used here, for discovery. classifyStatus
        // never inspects child processes — that historic fallback caused
        // false positives for every long-lived helper (sourcekit-lsp, MCP
        // servers, language servers). Hook state is the sole source of
        // truth for busy/idle.
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
                if kill(info.pid, 0) != 0 && errno == ESRCH {
                    try? FileManager.default.removeItem(at: file)
                    continue
                }
                pids.insert(info.pid)
                if !info.sessionId.isEmpty {
                    hookInfo[info.pid] = HookInfo(sessionId: info.sessionId, cwd: info.cwd)
                }
            }
        }
        hookInfoByPID = hookInfo

        // Add any claude binary that pgrep finds, regardless of hook state.
        if let output = try? await shell.run("pgrep -x claude"), !output.isEmpty {
            for line in output.components(separatedBy: "\n") {
                if let pid = Int32(line.trimmingCharacters(in: .whitespaces)) {
                    pids.insert(pid)
                }
            }
        }

        return pids.sorted()
    }

    private struct ParsedInfo {
        let pid: pid_t
        let sessionId: String
        let cwd: String
    }

    private func readInfoFile(file: URL) -> ParsedInfo? {
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pidValue = json["pid"] as? Int else {
            return nil
        }
        let sessionId = (json["session_id"] as? String) ?? ""
        let cwd = (json["cwd"] as? String) ?? ""
        return ParsedInfo(pid: pid_t(pidValue), sessionId: sessionId, cwd: cwd)
    }

    /// Classify a Claude session's state. Pure hook-driven — there's no
    /// process inspection, no child filtering, no heuristics. The hook
    /// either says "busy" (marker file exists) or it doesn't (idle).
    func classifyStatus(pid: pid_t) async -> SessionStatus {
        return hookBusyPIDs.contains(pid) ? .busy : .idle
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
        // Refresh hook-driven busy state inline so a single poll() call is
        // self-contained: discover PIDs and classify them based on the
        // current on-disk markers, without depending on the FSEvents watcher
        // having run first. This makes the function deterministic for tests
        // and removes any chance of a race on startup.
        refreshHookBusyPIDs()

        let pids = await discoverPIDs()
        let now = Date()

        // Capture the previous live PIDs so we can promote disappearances
        // to ghost rows that linger briefly in the UI.
        let previousLivePIDs = Set(sessions.lazy.filter { !$0.isGhost }.map(\.pid))

        var updatedSessions: [Session] = []
        updatedSessions.reserveCapacity(pids.count)

        for pid in pids {
            let newStatus = await classifyStatus(pid: pid)
            let session = await updatedSession(pid: pid, newStatus: newStatus)
            updatedSessions.append(session)
        }

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
    private func updatedSession(pid: pid_t, newStatus: SessionStatus) async -> Session {
        let info = hookInfoByPID[pid]

        if var existing = sessions.first(where: { $0.pid == pid }) {
            // Backfill metadata from the hook info if it became available.
            if existing.sessionId == nil, let info {
                existing.sessionId = info.sessionId
            }
            if existing.workingDirectory.isEmpty {
                if let info, !info.cwd.isEmpty {
                    existing.workingDirectory = info.cwd
                } else {
                    existing.workingDirectory = await detectCWD(pid: pid)
                }
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
            let cwd = info?.cwd.isEmpty == false ? info!.cwd : await detectCWD(pid: pid)
            return Session(
                pid: pid,
                workingDirectory: cwd,
                status: newStatus,
                sessionId: info?.sessionId
            )
        }
    }

    func updatePollingInterval(_ interval: TimeInterval) {
        pollingInterval = max(1, min(interval, 10))
    }

    /// Snapshot of -info filenames seen on the previous tick. Used to detect
    /// session arrivals/departures so we can kick the main poll immediately.
    private var lastInfoFilenames: Set<String> = []

    /// Reads -busy markers from disk into `hookBusyPIDs`. Pure side-effect on
    /// `hookBusyPIDs` — doesn't kick a poll. Safe to call from poll() itself.
    @discardableResult
    private func refreshHookBusyPIDs() -> Bool {
        let now = Date()
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: stateDir,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else {
            let changed = !hookBusyPIDs.isEmpty
            if changed { hookBusyPIDs = [] }
            return changed
        }

        var present: Set<pid_t> = []
        for file in files where file.lastPathComponent.hasSuffix("-busy") {
            guard let pid = readMarkerPID(file: file) else {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            if kill(pid, 0) != 0 && errno == ESRCH {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            if let attrs = try? file.resourceValues(forKeys: [.contentModificationDateKey]),
               let mtime = attrs.contentModificationDate,
               now.timeIntervalSince(mtime) < AppConstants.busyMarkerTimeout {
                present.insert(pid)
            } else {
                try? FileManager.default.removeItem(at: file)
            }
        }

        let changed = present != hookBusyPIDs
        if changed { hookBusyPIDs = present }
        return changed
    }

    /// Watches the state dir for changes via FSEvents and triggers a re-poll.
    /// Cheap (just dir listing + mtime reads) so it runs independently of the
    /// main classification cycle.
    private func pollHookState() {
        let busyChanged = refreshHookBusyPIDs()

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

        if busyChanged || infoChanged {
            Task { await self.poll() }
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
        stateDirFD = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend, .attrib],
            queue: DispatchQueue.main
        )
        source.setEventHandler { [weak self] in
            self?.pollHookState()
        }
        source.setCancelHandler { [weak self] in
            if let fd = self?.stateDirFD, fd >= 0 {
                close(fd)
                self?.stateDirFD = -1
            }
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
