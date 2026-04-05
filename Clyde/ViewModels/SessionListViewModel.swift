import SwiftUI
import Combine

@MainActor
final class SessionListViewModel: ObservableObject {
    let processMonitor: ProcessMonitor
    private var cancellables = Set<AnyCancellable>()

    /// Custom names persisted by PID path (workingDirectory -> name)
    @Published var customNames: [String: String] = [:]

    var sessions: [Session] {
        processMonitor.sessions.map { session in
            var s = session
            if let name = customNames[session.workingDirectory], !name.isEmpty {
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

        // Load saved names
        if let saved = UserDefaults.standard.dictionary(forKey: "sessionNames") as? [String: String] {
            customNames = saved
        }

        processMonitor.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    func renameSession(workingDirectory: String, to name: String) {
        customNames[workingDirectory] = name.isEmpty ? nil : name
        UserDefaults.standard.set(customNames, forKey: "sessionNames")
        objectWillChange.send()
    }
}
