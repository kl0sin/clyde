import SwiftUI
import Combine

@MainActor
final class SessionListViewModel: ObservableObject {
    let processMonitor: ProcessMonitor
    private var cancellables = Set<AnyCancellable>()

    var sessions: [Session] { processMonitor.sessions }
    var sessionCount: Int { sessions.count }
    var busyCount: Int { sessions.filter { $0.status == .busy }.count }
    var idleCount: Int { sessions.filter { $0.status == .idle }.count }

    init(processMonitor: ProcessMonitor) {
        self.processMonitor = processMonitor
        processMonitor.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }
}
