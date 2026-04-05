import SwiftUI
import Combine

@MainActor
final class AppViewModel: ObservableObject {
    @Published var isCollapsed = true
    @Published var showSettings = false

    let processMonitor: ProcessMonitor
    let terminalLauncher: TerminalLauncher
    let notificationService: NotificationService

    var clydeState: ClydeState {
        processMonitor.clydeState
    }

    var statusText: String {
        let sessions = processMonitor.sessions
        if sessions.isEmpty { return "sleeping" }
        let busyCount = sessions.filter { $0.status == .busy }.count
        if busyCount > 0 { return "\(busyCount) active" }
        return "all idle"
    }

    private var cancellables = Set<AnyCancellable>()

    convenience init() {
        self.init(
            processMonitor: ProcessMonitor(),
            terminalLauncher: TerminalLauncher(),
            notificationService: NotificationService()
        )
    }

    convenience init(processMonitor: ProcessMonitor) {
        self.init(
            processMonitor: processMonitor,
            terminalLauncher: TerminalLauncher(),
            notificationService: NotificationService()
        )
    }

    init(
        processMonitor: ProcessMonitor,
        terminalLauncher: TerminalLauncher,
        notificationService: NotificationService
    ) {
        self.processMonitor = processMonitor
        self.terminalLauncher = terminalLauncher
        self.notificationService = notificationService

        processMonitor.onSessionBecameIdle = { [weak notificationService] session in
            notificationService?.sendNotification(for: session)
        }

        processMonitor.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    func toggleExpanded() {
        isCollapsed.toggle()
    }

    func start() {
        notificationService.requestPermission()
        terminalLauncher.detectTerminals()
        processMonitor.startPolling()
    }
}
