import Foundation
import AppKit

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

            // The bundle identifier is what every adapter already
            // declares and what AppleScript resolves against, so ask the
            // process itself rather than reading its path for clues.
            if let identifier = NSRunningApplication(processIdentifier: parentPID)?.bundleIdentifier,
               let adapter = adapter(forBundleIdentifier: identifier) {
                return (adapter, shellPID)
            }

            // Fallback for a pid with no bundle — a terminal launched
            // straight from its binary, or one macOS has not registered.
            let commOutput = (try? await shell.run("ps -p \(parentPID) -o comm=")) ?? ""
            let comm = commOutput.trimmingCharacters(in: .whitespaces)

            if let adapter = adapter(forProcessPath: comm) {
                return (adapter, shellPID)
            }

            currentPID = parentPID
        }
        return nil
    }

    /// The reliable match: an identifier the adapter declares, compared
    /// whole rather than searched for inside a string.
    func adapter(forBundleIdentifier identifier: String) -> TerminalAdapter? {
        guard !identifier.isEmpty else { return nil }
        return allAdapters.first {
            $0.bundleIdentifiers.contains { $0.caseInsensitiveCompare(identifier) == .orderedSame }
        }
    }

    /// Last resort, matched on the app bundle in the path rather than on
    /// the executable's name: Warp's binary is called `stable`, and
    /// `contains("stable")` used to hand it every unrelated process that
    /// happened to have those six letters somewhere in its path.
    func adapter(forProcessPath path: String) -> TerminalAdapter? {
        let lowered = path.lowercased()
        func hasBundle(_ name: String) -> Bool { lowered.contains("/\(name).app/") }

        if hasBundle("iterm") || hasBundle("iterm2") {
            return allAdapters.first { $0 is ITermAdapter }
        }
        if hasBundle("terminal") {
            return allAdapters.first { $0 is TerminalAppAdapter }
        }
        if hasBundle("warp") || hasBundle("warp preview") {
            return allAdapters.first { $0 is WarpAdapter }
        }
        if hasBundle("ghostty") {
            return allAdapters.first { $0 is GhosttyAdapter }
        }
        return nil
    }
}
