import Foundation

/// Launches and focuses Claude sessions in the hosting terminal.
/// Auto-detects which terminal hosts a given session by walking its process tree.
@MainActor
final class TerminalLauncher: ObservableObject {
    @Published var availableTerminals: [TerminalAdapter] = []

    private let allAdapters: [TerminalAdapter] = [
        ITermAdapter(),
        TerminalAppAdapter(),
        WarpAdapter(),
        GhosttyAdapter()
    ]

    func detectTerminals() {
        availableTerminals = allAdapters.filter { $0.isInstalled }
    }

    /// Focus the terminal tab hosting this Claude session.
    /// Walks the process tree to identify which terminal emulator owns the session.
    func focusSession(_ session: Session) async throws {
        guard let (adapter, shellPID) = await findHostingTerminal(claudePID: session.pid) else {
            throw TerminalError.hostingTerminalNotFound
        }
        try await adapter.focusSession(parentPID: shellPID)
    }

    /// Walk from claude PID → shell → terminal emulator.
    /// Returns the shell PID and matching adapter.
    private func findHostingTerminal(claudePID: pid_t) async -> (adapter: TerminalAdapter, shellPID: pid_t)? {
        let shell = RealShellExecutor()

        let shellPIDOutput = (try? await shell.run("ps -p \(claudePID) -o ppid=")) ?? ""
        guard let shellPID = Int32(shellPIDOutput.trimmingCharacters(in: .whitespaces)), shellPID > 1 else {
            return nil
        }

        var currentPID = shellPID
        for _ in 0..<10 {
            let parentOutput = (try? await shell.run("ps -p \(currentPID) -o ppid=")) ?? ""
            guard let parentPID = Int32(parentOutput.trimmingCharacters(in: .whitespaces)), parentPID > 1 else {
                return nil
            }

            let commOutput = (try? await shell.run("ps -p \(parentPID) -o comm=")) ?? ""
            let comm = commOutput.trimmingCharacters(in: .whitespaces).lowercased()

            if let adapter = matchAdapter(forProcessName: comm) {
                return (adapter, shellPID)
            }

            currentPID = parentPID
        }
        return nil
    }

    private func matchAdapter(forProcessName name: String) -> TerminalAdapter? {
        if name.contains("iterm") {
            return allAdapters.first { $0 is ITermAdapter }
        }
        if name.contains("terminal") && !name.contains("iterm") {
            return allAdapters.first { $0 is TerminalAppAdapter }
        }
        if name.contains("warp") || name.contains("stable") {
            return allAdapters.first { $0 is WarpAdapter }
        }
        if name.contains("ghostty") {
            return allAdapters.first { $0 is GhosttyAdapter }
        }
        return nil
    }
}
