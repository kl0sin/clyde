import SwiftUI
import Combine
import AppKit
import Darwin

@MainActor
final class AppViewModel: ObservableObject {
    @Published var isCollapsed = true
    @Published var showSettings = false
    @Published var lastError: String?
    @Published var hookHealthIssue: HookInstaller.HealthIssue?
    @Published var widgetVisible: Bool {
        didSet { UserDefaults.standard.set(widgetVisible, forKey: Self.widgetVisibleKey) }
    }

    let processMonitor: ProcessMonitor
    let terminalLauncher: TerminalLauncher
    let notificationService: NotificationService
    let attentionMonitor: AttentionMonitor
    let activityLog: ActivityLog

    var clydeState: ClydeState {
        // Attention takes priority over busy — if any session is waiting for
        // permission, surface that distinct state to the animation layer.
        if !attentionMonitor.attentionPIDs.isEmpty {
            return .attention
        }
        return processMonitor.clydeState
    }

    var statusText: String {
        let sessions = processMonitor.sessions.filter { !$0.isGhost }
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
    private var hookDirSource: DispatchSourceFileSystemObject?
    private var hookDirFD: Int32 = -1
    private var settingsFileSource: DispatchSourceFileSystemObject?
    private var settingsFileFD: Int32 = -1
    private var settingsWatcherDebounce: DispatchWorkItem?
    private var hookHealTimer: Timer?

    deinit {
        // Release everything we own. The class is @MainActor but deinit runs
        // nonisolated; cancelling tasks/sources/timers is safe from any
        // context, and the dispatch source's cancel handler closes hookDirFD.
        errorClearTask?.cancel()
        hookDirSource?.cancel()
        settingsFileSource?.cancel()
        settingsWatcherDebounce?.cancel()
        hookHealTimer?.invalidate()
    }

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
        self.activityLog = ActivityLog(
            processMonitor: processMonitor,
            attentionMonitor: attentionMonitor
        )
        self.widgetVisible = (UserDefaults.standard.object(forKey: Self.widgetVisibleKey) as? Bool) ?? true

        processMonitor.onSessionBecameIdle = { [weak self] session in
            guard let self else { return }
            // Don't ring for ghosts (sessions that are visually lingering after exit).
            if session.isGhost { return }
            // If the attention hook already fired for this PID, the attention path owns
            // the notification — skip "ready" to avoid duplication.
            if self.attentionMonitor.attentionPIDs.contains(session.pid) {
                return
            }
            self.notificationService.sendNotification(for: session)
            self.notificationService.playReadySound(for: session)
        }

        // Forward ProcessMonitor updates to our own observers.
        //
        // Historical note: we used to clear the attention flag here whenever a
        // session was seen as .busy, on the theory that "busy means user is
        // working in that session again". That was wrong — permission
        // requests happen *while* Claude is still busy (Stop hasn't fired),
        // so clearing attention on busy immediately wiped every permission
        // alert. Attention is now only cleared by explicit user action
        // (focusSession), by the hook's SessionEnd, or by the scan timeout.
        processMonitor.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        attentionMonitor.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        attentionMonitor.onAttentionNeeded = { [weak self] pid in
            guard let self,
                  let session = self.processMonitor.sessions.first(where: { $0.pid == pid }) else {
                return
            }
            self.notificationService.playAttentionSound(for: session)
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
    private static let widgetVisibleKey = "widgetVisible"

    func start() {
        notificationService.requestPermission()
        terminalLauncher.detectTerminals()

        let saved = UserDefaults.standard.double(forKey: "pollingInterval")
        if saved > 0 {
            processMonitor.updatePollingInterval(saved)
        }

        processMonitor.startPolling()
        attentionMonitor.start()
        // One-shot legacy migration must run BEFORE the first health check,
        // otherwise the check sees the old `clyde-notify.sh` file in place
        // and reports "everything fine" while settings.json points nowhere.
        HookInstaller.migrateLegacyHookIfNeeded()
        ensureHookHealthy()
        startHookSelfHealing()
        startSettingsWatcher()
        ClydeLog.general.info("Clyde started")
    }

    /// Watch `~/.claude/settings.json` itself. The hooks-dir watcher only
    /// catches tampering with our script file; it doesn't catch the much
    /// more common failure mode where some OTHER tool (e.g. claude-visual)
    /// rewrites settings.json end-to-end and silently strips our hook
    /// entries. When that happens, hooks stop firing entirely and Clyde's
    /// "in progress" detection goes dark until the 60s safety-net timer.
    /// This watcher closes that gap to ~300ms.
    ///
    /// Re-arms after every event because atomic writes (mktemp + mv) swap
    /// the inode, so the FD we hold becomes orphaned and stops delivering.
    private func startSettingsWatcher() {
        armSettingsWatcher()
    }

    private func armSettingsWatcher() {
        settingsFileSource?.cancel()
        settingsFileSource = nil

        let path = AppPaths.claudeSettingsFile.path
        guard FileManager.default.fileExists(atPath: path) else {
            // File doesn't exist yet — retry shortly. Claude creates it on
            // first launch, so on a fresh machine we may briefly have nothing
            // to watch.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.armSettingsWatcher()
            }
            return
        }

        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            ClydeLog.hooks.error("Failed to open settings.json for watching")
            return
        }
        settingsFileFD = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend, .attrib],
            queue: DispatchQueue.main
        )
        source.setEventHandler { [weak self] in
            self?.handleSettingsFileChanged()
        }
        source.setCancelHandler { [weak self] in
            if let fd = self?.settingsFileFD, fd >= 0 {
                close(fd)
                self?.settingsFileFD = -1
            }
        }
        source.resume()
        settingsFileSource = source
    }

    private func handleSettingsFileChanged() {
        // Suppress the FSEvents echo from our own writes. Without this guard,
        // every install() triggers another health check that re-installs that
        // triggers another event... a tight reinstall loop.
        if let last = HookInstaller.lastSelfWriteAt,
           Date().timeIntervalSince(last) < 1.5 {
            armSettingsWatcher()
            return
        }

        // Debounce — external tools often write the file in two passes
        // (truncate then content). Coalescing avoids running the health
        // check against a half-written intermediate state.
        settingsWatcherDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.ensureHookHealthy()
            self?.armSettingsWatcher()
        }
        settingsWatcherDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// Watch `~/.claude/hooks/` for changes and re-run auto-repair the
    /// moment anything tampers with the hook script (delete, replace,
    /// truncate, ...). Plus a 60s safety-net timer for cases where the
    /// FSEvents source somehow drops an event.
    private func startHookSelfHealing() {
        let hooksDir = AppPaths.claudeHooksDir
        try? FileManager.default.createDirectory(at: hooksDir, withIntermediateDirectories: true)

        let fd = open(hooksDir.path, O_EVTONLY)
        if fd >= 0 {
            hookDirFD = fd
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .delete, .rename, .extend, .attrib],
                queue: DispatchQueue.main
            )
            source.setEventHandler { [weak self] in
                self?.ensureHookHealthy()
            }
            source.setCancelHandler { [weak self] in
                if let fd = self?.hookDirFD, fd >= 0 {
                    close(fd)
                    self?.hookDirFD = -1
                }
            }
            source.resume()
            hookDirSource = source
        }

        // Belt-and-braces: a 60s tick that re-runs the health check in case
        // FSEvents misses something. Cheap, just a stat() call.
        hookHealTimer?.invalidate()
        hookHealTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.ensureHookHealthy() }
        }
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
            ClydeLog.hooks.info("Health check found issue: \(issue.bannerMessage, privacy: .public)")

            let shouldAutoInstall: Bool
            switch issue {
            case .claudeNotInstalled:
                // Don't try to install a hook for a CLI that doesn't
                // exist — the user needs to install Claude Code first.
                // The banner will tell them.
                shouldAutoInstall = false
            case .notInstalled:
                shouldAutoInstall = !optedOut
            case .scriptMissing, .scriptNotExecutable, .outdated, .missingEvents:
                shouldAutoInstall = true
            case .autoRepairFailed:
                shouldAutoInstall = false
            }

            let resolvedIssue: HookInstaller.HealthIssue?
            if shouldAutoInstall {
                do {
                    try HookInstaller.install()
                    ClydeLog.hooks.info("Auto-installed/repaired Claude hook (was: \(issue.bannerMessage, privacy: .public))")
                    resolvedIssue = HookInstaller.healthCheck()
                } catch {
                    ClydeLog.hooks.error("Auto-install failed: \(error.localizedDescription, privacy: .public)")
                    resolvedIssue = .autoRepairFailed(reason: error.localizedDescription)
                }
            } else {
                resolvedIssue = issue
            }

            let finalIssue = resolvedIssue
            await MainActor.run { self.hookHealthIssue = finalIssue }
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

    /// Wipe all hook-driven state files (state/, events/) and clear the
    /// in-memory caches. Useful when the user suspects something is stuck.
    /// Sessions will reappear on the next hook event or pgrep poll.
    func resetAllHookState() {
        let toClear = [AppPaths.stateDir, AppPaths.eventsDir]
        for dir in toClear {
            if let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
                for f in files {
                    try? FileManager.default.removeItem(at: dir.appendingPathComponent(f))
                }
            }
        }
        ClydeLog.general.info("All hook state cleared by user")
        // Re-poll so the UI reflects the wipe immediately.
        Task { await processMonitor.poll() }
    }

    /// Wipe state for a single session (info + busy markers + any pending
    /// attention event). Used by the per-session reset action in the
    /// expanded view.
    func resetSession(_ session: Session) {
        if let sid = session.sessionId {
            let names = ["\(sid)-info", "\(sid)-busy"]
            for name in names {
                try? FileManager.default.removeItem(at: AppPaths.stateDir.appendingPathComponent(name))
            }
            try? FileManager.default.removeItem(at: AppPaths.eventsDir.appendingPathComponent("\(sid).json"))
        }
        // Also clear the in-memory attention flag for this PID, in case
        // there were legacy events keyed by something else.
        attentionMonitor.clearAttention(pid: session.pid)
        ClydeLog.general.info("Session \(session.pid, privacy: .public) state cleared by user")
        Task { await processMonitor.poll() }
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
        // Dedupe identical back-to-back errors. The previous behaviour
        // restarted the auto-clear timer on every duplicate, which meant a
        // burst of identical failures kept the banner visible indefinitely.
        if lastError == message, errorClearTask != nil { return }

        lastError = message
        errorClearTask?.cancel()
        errorClearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, !Task.isCancelled else { return }
            await MainActor.run {
                self.lastError = nil
                self.errorClearTask = nil
            }
        }
    }
}
