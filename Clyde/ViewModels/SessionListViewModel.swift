import SwiftUI
import Combine

@MainActor
final class SessionListViewModel: ObservableObject {
    @Published var terminalSessions: [TerminalSession] = []
    @Published var selectedSessionID: UUID?

    let processMonitor: ProcessMonitor
    private var cancellables = Set<AnyCancellable>()

    var selectedSession: TerminalSession? {
        if let id = selectedSessionID {
            return terminalSessions.first(where: { $0.id == id })
        }
        return terminalSessions.first
    }

    // Process monitor data for status bar
    var monitoredSessions: [Session] { processMonitor.sessions }
    var sessionCount: Int { processMonitor.sessions.count }
    var busyCount: Int { processMonitor.sessions.filter { $0.status == .busy }.count }
    var idleCount: Int { processMonitor.sessions.filter { $0.status == .idle }.count }

    init(processMonitor: ProcessMonitor) {
        self.processMonitor = processMonitor

        processMonitor.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    func selectSession(_ session: TerminalSession) {
        selectedSessionID = session.id
    }

    func createNewSession(cwd: String? = nil, runClaude: Bool = false) {
        do {
            let session = runClaude
                ? try TerminalSession.createClaude(cwd: cwd)
                : try TerminalSession.createShell(cwd: cwd)
            terminalSessions.append(session)
            selectedSessionID = session.id

            // Forward changes from terminal session
            session.objectWillChange
                .sink { [weak self] _ in self?.objectWillChange.send() }
                .store(in: &cancellables)
        } catch {
            print("Failed to create terminal session: \(error)")
        }
    }

    func closeSession(_ session: TerminalSession) {
        session.terminate()
        terminalSessions.removeAll(where: { $0.id == session.id })
        if selectedSessionID == session.id {
            selectedSessionID = terminalSessions.first?.id
        }
    }

    func renameSession(id: UUID, to name: String) {
        if let session = terminalSessions.first(where: { $0.id == id }) {
            session.title = name
        }
    }
}
