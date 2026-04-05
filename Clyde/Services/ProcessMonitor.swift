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

@MainActor
final class ProcessMonitor: ObservableObject {
    @Published var sessions: [Session] = []
    @Published var clydeState: ClydeState = .sleeping

    private let shell: ShellExecutor
    let pollingInterval: TimeInterval

    var onSessionBecameIdle: ((Session) -> Void)?

    init(shell: ShellExecutor = RealShellExecutor(), pollingInterval: TimeInterval = 3) {
        self.shell = shell
        self.pollingInterval = pollingInterval
    }

    func discoverPIDs() async -> [pid_t] {
        guard let output = try? await shell.run("pgrep -x claude"),
              !output.isEmpty else {
            return []
        }
        return output
            .components(separatedBy: "\n")
            .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// Classify status by checking if Claude has active child processes.
    /// When Claude processes a request, it spawns child processes (node, bash, etc.).
    /// When waiting for user input, it has no children — it's idle.
    func classifyStatus(pid: pid_t) async -> SessionStatus {
        guard let output = try? await shell.run("pgrep -P \(pid)"),
              !output.isEmpty else {
            return .idle // No children = waiting for input
        }
        return .busy // Has children = processing
    }

    func detectCWD(pid: pid_t) async -> String {
        // Claude Code sets CWD to /, so detect project dir from open files
        if let output = try? await shell.run("lsof -p \(pid) -Fn 2>/dev/null | grep '/.claude/settings' | head -1"),
           !output.isEmpty {
            let path = String(output.dropFirst()) // Remove leading 'n'
            if let range = path.range(of: "/.claude/") {
                return String(path[path.startIndex..<range.lowerBound])
            }
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

        for pid in pids {
            let newStatus = await classifyStatus(pid: pid)

            if var existing = sessions.first(where: { $0.pid == pid }) {
                if existing.workingDirectory.isEmpty {
                    existing.workingDirectory = await detectCWD(pid: pid)
                }

                let previousStatus = existing.status
                if previousStatus != newStatus {
                    existing.status = newStatus
                    existing.statusChangedAt = Date()
                    if newStatus == .idle {
                        onSessionBecameIdle?(existing)
                    }
                }

                updatedSessions.append(existing)
            } else {
                let cwd = await detectCWD(pid: pid)
                let newSession = Session(pid: pid, workingDirectory: cwd, status: newStatus)
                updatedSessions.append(newSession)
            }
        }

        sessions = updatedSessions
        clydeState = sessions.contains(where: { $0.status == .busy }) ? .busy : .idle
    }

    func startPolling() {
        Task {
            while !Task.isCancelled {
                await poll()
                try? await Task.sleep(for: .seconds(pollingInterval))
            }
        }
    }
}
