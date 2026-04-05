import SwiftUI
import Combine

@MainActor
final class SessionListViewModel: ObservableObject {
    let processMonitor: ProcessMonitor
    private var cancellables = Set<AnyCancellable>()

    /// Custom names keyed by session UUID
    @Published var customNames: [UUID: String] = [:]

    var sessions: [Session] {
        processMonitor.sessions.map { session in
            var s = session
            if let name = customNames[session.id], !name.isEmpty {
                s.customName = name
            }
            return s
        }
    }

    var sessionCount: Int { processMonitor.sessions.count }
    var busyCount: Int { processMonitor.sessions.filter { $0.status == .busy }.count }
    var idleCount: Int { processMonitor.sessions.filter { $0.status == .idle }.count }

    init(processMonitor: ProcessMonitor) {
        self.processMonitor = processMonitor
        processMonitor.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    func renameSession(id: UUID, to name: String) {
        customNames[id] = name.isEmpty ? nil : name
        objectWillChange.send()
    }
}
