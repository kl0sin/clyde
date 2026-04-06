import SwiftUI
import Combine
import AppKit

@MainActor
final class AppViewModel: ObservableObject {
    @Published var isCollapsed = true
    @Published var showSettings = false
    @Published var lastError: String?
    @Published var hookHealthIssue: HookInstaller.HealthIssue?

    let processMonitor: ProcessMonitor
    let terminalLauncher: TerminalLauncher
    let notificationService: NotificationService
    let attentionMonitor: AttentionMonitor

    var clydeState: ClydeState {
        // Attention takes priority over busy — if any session is waiting for
        // permission, surface that distinct state to the animation layer.
        if !attentionMonitor.attentionPIDs.isEmpty {
            return .attention
        }
        return processMonitor.clydeState
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
    private var errorClearTask: Task<Void, Never>?

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

        processMonitor.onSessionBecameIdle = { [weak self] session in
            guard let self else { return }
            // If the attention hook already fired for this PID, the attention path owns
            // the notification — skip "ready" to avoid duplication.
            if self.attentionMonitor.attentionPIDs.contains(session.pid) {
                return
            }
            self.notificationService.sendNotification(for: session)
            self.notificationService.playReadySound()
        }

        // When session becomes busy again, clear its attention flag
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

        attentionMonitor.onAttentionNeeded = { [weak self] pid in
            guard let self,
                  let session = self.processMonitor.sessions.first(where: { $0.pid == pid }) else {
                return
            }
            self.notificationService.playAttentionSound()
            self.notificationService.sendNotification(for: session)
        }
    }

    func toggleExpanded() {
        isCollapsed.toggle()
    }

    func updatePollingInterval(_ interval: Double) {
        processMonitor.updatePollingInterval(interval)
    }

    func focusSession(_ session: Session) {
        attentionMonitor.clearAttention(pid: session.pid)
        Task {
            do {
                try await terminalLauncher.focusSession(session)
            } catch {
                ClydeLog.terminal.error("Focus session failed: \(error.localizedDescription, privacy: .public)")
                showError(error.localizedDescription)
            }
        }
    }

    private static let hookOptOutKey = "hookAutoInstallOptOut"

    func start() {
        notificationService.requestPermission()
        terminalLauncher.detectTerminals()

        let saved = UserDefaults.standard.double(forKey: "pollingInterval")
        if saved > 0 {
            processMonitor.updatePollingInterval(saved)
        }

        processMonitor.startPolling()
        attentionMonitor.start()
        ensureHookHealthy()
        ClydeLog.general.info("Clyde started")
    }

    /// Auto-install or auto-repair the hook on startup.
    ///
    /// Runs off the main actor — file IO + JSON parsing shouldn't block the
    /// app launch. Result is delivered back to the main actor for UI binding.
    ///
    /// We never silently overwrite a working install. We only act when:
    ///  - the hook is missing AND the user hasn't explicitly opted out, or
    ///  - the install is corrupt / outdated / missing events (always repair).
    private func ensureHookHealthy() {
        let optedOut = UserDefaults.standard.bool(forKey: Self.hookOptOutKey)
        Task.detached(priority: .utility) {
            let issue = HookInstaller.healthCheck()
            guard let issue else {
                await MainActor.run { self.hookHealthIssue = nil }
                return
            }

            let shouldAutoInstall: Bool
            switch issue {
            case .notInstalled:
                shouldAutoInstall = !optedOut
            case .scriptMissing, .scriptNotExecutable, .outdated, .missingEvents:
                shouldAutoInstall = true
            case .autoRepairFailed:
                shouldAutoInstall = false
            }

            var resolvedIssue: HookInstaller.HealthIssue? = issue
            if shouldAutoInstall {
                do {
                    try HookInstaller.install()
                    ClydeLog.hooks.info("Auto-installed/repaired Claude hook (was: \(issue.bannerMessage, privacy: .public))")
                    resolvedIssue = HookInstaller.healthCheck()
                } catch {
                    ClydeLog.hooks.error("Auto-install failed: \(error.localizedDescription, privacy: .public)")
                    resolvedIssue = .autoRepairFailed(reason: error.localizedDescription)
                }
            }

            await MainActor.run { self.hookHealthIssue = resolvedIssue }
        }
    }

    /// Re-runs the hook installer's health check. Call this after the user
    /// toggles the install button in Settings.
    func refreshHookHealth() {
        hookHealthIssue = HookInstaller.healthCheck()
        if let issue = hookHealthIssue {
            ClydeLog.hooks.info("Hook health issue: \(issue.bannerMessage, privacy: .public)")
        }
    }

    /// Persist the user's choice to remove the hook so we don't re-install
    /// on the next launch.
    func setHookOptOut(_ optedOut: Bool) {
        UserDefaults.standard.set(optedOut, forKey: Self.hookOptOutKey)
    }

    /// Build a multi-line diagnostic dump and copy it to the pasteboard.
    /// Used by the "Copy diagnostic info" button in Settings.
    func copyDiagnosticInfoToPasteboard() {
        var lines: [String] = []
        lines.append("=== Clyde diagnostic info ===")
        if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
            lines.append("Clyde version: \(version)")
        }
        lines.append("Generated: \(ISO8601DateFormatter().string(from: Date()))")

        lines.append("")
        lines.append("--- Hook ---")
        lines.append("Installed: \(HookInstaller.isInstalled)")
        lines.append("Current script version: \(HookInstaller.currentScriptVersion)")
        if let issue = hookHealthIssue {
            lines.append("Health issue: \(issue.bannerMessage)")
        } else {
            lines.append("Health: OK")
        }
        lines.append("Opted out: \(UserDefaults.standard.bool(forKey: Self.hookOptOutKey))")

        lines.append("")
        lines.append("--- State directory ---")
        if let files = try? FileManager.default.contentsOfDirectory(atPath: AppPaths.stateDir.path) {
            lines.append("Files: \(files.count)")
            for f in files.sorted() { lines.append("  \(f)") }
        } else {
            lines.append("(unreadable)")
        }

        lines.append("")
        lines.append("--- Events directory ---")
        if let files = try? FileManager.default.contentsOfDirectory(atPath: AppPaths.eventsDir.path) {
            lines.append("Files: \(files.count)")
            for f in files.sorted() { lines.append("  \(f)") }
        } else {
            lines.append("(unreadable)")
        }

        lines.append("")
        lines.append("--- Sessions ---")
        let sessions = processMonitor.sessions
        let attentionPIDs = attentionMonitor.attentionPIDs
        lines.append("Total: \(sessions.count)")
        for s in sessions {
            let attn = attentionPIDs.contains(s.pid) ? " [attention]" : ""
            let sid = s.sessionId.map { " sid=\($0)" } ?? ""
            lines.append("  pid=\(s.pid) status=\(s.status) cwd=\(s.workingDirectory)\(sid)\(attn)")
        }

        lines.append("")
        lines.append("--- Polling ---")
        lines.append("Fallback interval: \(processMonitor.pollingInterval)s")

        let dump = lines.joined(separator: "\n")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(dump, forType: .string)
        ClydeLog.general.info("Diagnostic info copied to pasteboard")
    }

    private func showError(_ message: String) {
        lastError = message
        errorClearTask?.cancel()
        errorClearTask = Task {
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled {
                await MainActor.run { self.lastError = nil }
            }
        }
    }
}
