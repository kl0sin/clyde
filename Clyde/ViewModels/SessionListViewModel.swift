import SwiftUI
import Combine

@MainActor
final class SessionListViewModel: ObservableObject {
    let processMonitor: ProcessMonitor
    weak var attentionMonitor: AttentionMonitor?
    private var cancellables = Set<AnyCancellable>()

    /// Custom names keyed by session UUID
    @Published var customNames: [UUID: String] = [:]

    var sessions: [Session] {
        let attentionPIDs = attentionMonitor?.attentionPIDs ?? []
        return processMonitor.sessions.map { session in
            var s = session
            if let name = customNames[session.id], !name.isEmpty {
                s.customName = name
            }
            s.needsAttention = attentionPIDs.contains(session.pid)
            return s
        }
    }

    var sessionCount: Int { processMonitor.sessions.count }
    var busyCount: Int { processMonitor.sessions.filter { $0.status == .busy }.count }
    var idleCount: Int { processMonitor.sessions.filter { $0.status == .idle }.count }
    var attentionCount: Int {
        guard let ids = attentionMonitor?.attentionPIDs else { return 0 }
        return ids.count
    }

    init(processMonitor: ProcessMonitor, attentionMonitor: AttentionMonitor? = nil) {
        self.processMonitor = processMonitor
        self.attentionMonitor = attentionMonitor
        processMonitor.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        attentionMonitor?.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    func renameSession(id: UUID, to name: String) {
        customNames[id] = name.isEmpty ? nil : name
        objectWillChange.send()
    }
}
