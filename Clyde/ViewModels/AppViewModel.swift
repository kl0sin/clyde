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
        if sessions.isEmpty { return "no sessions" }
        let processingCount = sessions.filter { $0.status == .busy }.count
        let readyCount = sessions.count - processingCount
        if processingCount > 0 && readyCount > 0 {
            return "\(processingCount) working · \(readyCount) ready"
        }
        if processingCount > 0 { return "\(processingCount) working" }
        return "\(readyCount) ready"
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
            notificationService?.playReadySound()
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
