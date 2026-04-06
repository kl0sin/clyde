import SwiftUI
import Combine

@MainActor
final class AppViewModel: ObservableObject {
    @Published var isCollapsed = true
    @Published var showSettings = false

    let processMonitor: ProcessMonitor
    let terminalLauncher: TerminalLauncher
    let notificationService: NotificationService
    let attentionMonitor: AttentionMonitor

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
            notificationService: NotificationService(),
            attentionMonitor: AttentionMonitor()
        )
    }

    convenience init(processMonitor: ProcessMonitor) {
        self.init(
            processMonitor: processMonitor,
            terminalLauncher: TerminalLauncher(),
            notificationService: NotificationService(),
            attentionMonitor: AttentionMonitor()
        )
    }

    init(
        processMonitor: ProcessMonitor,
        terminalLauncher: TerminalLauncher,
        notificationService: NotificationService,
        attentionMonitor: AttentionMonitor
    ) {
        self.processMonitor = processMonitor
        self.terminalLauncher = terminalLauncher
        self.notificationService = notificationService
        self.attentionMonitor = attentionMonitor

        processMonitor.onSessionBecameIdle = { [weak notificationService] session in
            notificationService?.sendNotification(for: session)
            notificationService?.playReadySound()
        }

        // Clear attention when session starts processing again
        processMonitor.objectWillChange
            .sink { [weak self] _ in
                guard let self else { return }
                for session in self.processMonitor.sessions where session.status == .busy {
                    self.attentionMonitor.clearAttention(pid: session.pid)
                }
                self.objectWillChange.send()
            }
            .store(in: &cancellables)

        attentionMonitor.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // Play attention sound when a new session needs user input
        attentionMonitor.onAttentionNeeded = { [weak self] pid in
            guard let self else { return }
            if let session = self.processMonitor.sessions.first(where: { $0.pid == pid }) {
                self.notificationService.playAttentionSound()
                self.notificationService.sendNotification(for: session)
            }
        }
    }

    func toggleExpanded() {
        isCollapsed.toggle()
    }

    func updatePollingInterval(_ interval: Double) {
        processMonitor.updatePollingInterval(interval)
    }

    func focusSession(_ session: Session) {
        // Focusing implicitly handles the attention
        attentionMonitor.clearAttention(pid: session.pid)
        Task {
            try? await terminalLauncher.focusSession(session)
        }
    }

    func start() {
        notificationService.requestPermission()
        terminalLauncher.detectTerminals()

        let saved = UserDefaults.standard.double(forKey: "pollingInterval")
        if saved > 0 {
            processMonitor.updatePollingInterval(saved)
        }

        processMonitor.startPolling()
        attentionMonitor.start()
    }
}
