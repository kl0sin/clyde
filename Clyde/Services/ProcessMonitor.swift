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
    private let cpuThreshold: Double = 5.0
    private let requiredIdleReads: Int = 2

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

    func classifyStatus(pid: pid_t) async -> SessionStatus {
        guard let output = try? await shell.run("ps -p \(pid) -o %cpu="),
              let cpu = Double(output.trimmingCharacters(in: .whitespaces)) else {
            return .idle
        }
        return cpu > cpuThreshold ? .busy : .idle
    }

    func detectCWD(pid: pid_t) async -> String {
        // Claude Code changes its CWD to /, so we detect the project directory
        // by finding .claude/settings.local.json in the process's open files
        if let output = try? await shell.run("lsof -p \(pid) -Fn 2>/dev/null | grep '/.claude/settings' | head -1"),
           !output.isEmpty {
            // output is like "n/Users/me/project/.claude/settings.local.json"
            let path = String(output.dropFirst()) // Remove leading 'n'
            if let range = path.range(of: "/.claude/") {
                return String(path[path.startIndex..<range.lowerBound])
            }
        }
        // Fallback: try lsof cwd
        if let output = try? await shell.run("lsof -p \(pid) -d cwd -Fn 2>/dev/null | grep '^n/' | head -1"),
           !output.isEmpty {
            let cwd = String(output.dropFirst())
            if cwd != "/" { return cwd }
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
            let rawStatus = await classifyStatus(pid: pid)
            let cwd = await detectCWD(pid: pid)

            if var existing = sessions.first(where: { $0.pid == pid }) {
                existing.workingDirectory = cwd.isEmpty ? existing.workingDirectory : cwd

                if rawStatus == .idle {
                    existing.consecutiveIdleReads += 1
                } else {
                    existing.consecutiveIdleReads = 0
                }

                let previousStatus = existing.status
                let newStatus: SessionStatus = (rawStatus == .idle && existing.consecutiveIdleReads >= requiredIdleReads) ? .idle : .busy

                if previousStatus != newStatus {
                    existing.status = newStatus
                    existing.statusChangedAt = Date()
                    if newStatus == .idle {
                        onSessionBecameIdle?(existing)
                    }
                }

                updatedSessions.append(existing)
            } else {
                var newSession = Session(pid: pid, workingDirectory: cwd, status: .busy)
                if rawStatus == .idle {
                    newSession.consecutiveIdleReads = 1
                }
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
