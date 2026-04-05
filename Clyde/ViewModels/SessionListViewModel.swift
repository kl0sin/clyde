import SwiftUI
import Combine

@MainActor
final class SessionListViewModel: ObservableObject {
    @Published var selectedSessionID: UUID?

    let processMonitor: ProcessMonitor
    private var cancellables = Set<AnyCancellable>()

    var sessions: [Session] {
        processMonitor.sessions
    }

    var selectedSession: Session? {
        if let id = selectedSessionID {
            return sessions.first(where: { $0.id == id })
        }
        return sessions.first
    }

    var sessionCount: Int { sessions.count }
    var busyCount: Int { sessions.filter { $0.status == .busy }.count }
    var idleCount: Int { sessions.filter { $0.status == .idle }.count }

    init(processMonitor: ProcessMonitor) {
        self.processMonitor = processMonitor

        processMonitor.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    func selectSession(_ session: Session) {
        selectedSessionID = session.id
    }

    func renameSession(id: UUID, to name: String) {
        if let index = processMonitor.sessions.firstIndex(where: { $0.id == id }) {
            processMonitor.sessions[index].customName = name
        }
    }
}
