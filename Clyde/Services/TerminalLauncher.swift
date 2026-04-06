import Foundation

@MainActor
final class TerminalLauncher: ObservableObject {
    @Published var availableTerminals: [TerminalAdapter] = []
    @Published var selectedTerminalName: String = ""

    private let allAdapters: [TerminalAdapter] = [
        ITermAdapter(),
        TerminalAppAdapter(),
        WarpAdapter(),
        GhosttyAdapter()
    ]

    var selectedAdapter: TerminalAdapter? {
        availableTerminals.first(where: { $0.name == selectedTerminalName })
            ?? availableTerminals.first
    }

    func detectTerminals() {
        availableTerminals = allAdapters.filter { $0.isInstalled }
        if selectedTerminalName.isEmpty, let first = availableTerminals.first {
            selectedTerminalName = first.name
        }
    }

    func openNewSession() async throws {
        guard let adapter = selectedAdapter else {
            throw TerminalError.terminalNotInstalled
        }
        try await adapter.openNewSession()
    }

    /// Walk from claude PID → shell (direct parent) → terminal emulator.
    /// Returns the shell PID (to pass to adapter.focusSession) + the matching adapter.
    private func findHostingTerminal(claudePID: pid_t) async -> (adapter: TerminalAdapter, shellPID: pid_t)? {
        let shell = RealShellExecutor()

        // Step 1: get shell PID (direct parent of claude)
        let shellPIDOutput = (try? await shell.run("ps -p \(claudePID) -o ppid=")) ?? ""
        guard let shellPID = Int32(shellPIDOutput.trimmingCharacters(in: .whitespaces)), shellPID > 1 else {
            return nil
        }

        // Step 2: walk up from shell to find the terminal app
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
        // Process names from `ps -o comm=` on macOS:
        // iTerm2: /Applications/iTerm.app/Contents/MacOS/iTerm2
        // Terminal: /System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal
        // Warp: /Applications/Warp.app/Contents/MacOS/stable
        // Ghostty: /Applications/Ghostty.app/Contents/MacOS/ghostty
        let lowercased = name.lowercased()

        if lowercased.contains("iterm") {
            return allAdapters.first { $0 is ITermAdapter }
        }
        if lowercased.contains("terminal") && !lowercased.contains("iterm") {
            return allAdapters.first { $0 is TerminalAppAdapter }
        }
        if lowercased.contains("warp") || lowercased.contains("stable") {
            return allAdapters.first { $0 is WarpAdapter }
        }
        if lowercased.contains("ghostty") {
            return allAdapters.first { $0 is GhosttyAdapter }
        }
        return nil
    }

    func focusSession(_ session: Session) async throws {
        // Auto-detect which terminal hosts this session, pass shell PID to adapter
        if let (adapter, shellPID) = await findHostingTerminal(claudePID: session.pid) {
            try await adapter.focusSession(parentPID: shellPID)
            return
        }

        // Fallback: selected terminal with claude's parent PID
        guard let adapter = selectedAdapter else {
            throw TerminalError.terminalNotInstalled
        }
        let shell = RealShellExecutor()
        let ppidOutput = (try? await shell.run("ps -p \(session.pid) -o ppid=")) ?? ""
        let ppid = Int32(ppidOutput.trimmingCharacters(in: .whitespaces)) ?? session.pid
        try await adapter.focusSession(parentPID: ppid)
    }
}
