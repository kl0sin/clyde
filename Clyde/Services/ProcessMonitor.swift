import Foundation
import Combine

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

    init(shell: ShellExecutor = RealShellExecutor(), pollingInterval: TimeInterval = AppConstants.defaultPollingInterval) {
        self.shell = shell
        self.pollingInterval = pollingInterval
    }

    deinit {
        pollTask?.cancel()
    }

    func discoverPIDs() async -> [pid_t] {
        guard let output = try? await shell.run("pgrep -x claude"), !output.isEmpty else {
            return []
        }
        return output
            .components(separatedBy: "\n")
            .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// Classify by checking if Claude has active child processes.
    /// Children = running tool → busy. No children = waiting for input → idle.
    func classifyStatus(pid: pid_t) async -> SessionStatus {
        guard let output = try? await shell.run("pgrep -P \(pid)"), !output.isEmpty else {
            return .idle
        }
        return .busy
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

    func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                let interval = self?.pollingInterval ?? AppConstants.defaultPollingInterval
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }
}
