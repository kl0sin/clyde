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

    func focusSession(_ session: Session) async throws {
        let shell = RealShellExecutor()
        let ppidOutput = try await shell.run("ps -p \(session.pid) -o ppid=")
        guard let ppid = Int32(ppidOutput.trimmingCharacters(in: .whitespaces)) else {
            return
        }
        guard let adapter = selectedAdapter else {
            throw TerminalError.terminalNotInstalled
        }
        try await adapter.focusSession(parentPID: ppid)
    }
}
