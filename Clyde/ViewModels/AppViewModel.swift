import SwiftUI
import Combine
import AppKit
import Darwin

@MainActor
final class AppViewModel: ObservableObject {
    @Published var isCollapsed = true
    @Published var lastError: String?
    @Published var hookHealthIssue: HookInstaller.HealthIssue?

    /// Re-checks a missing permission until it appears.
    ///
    /// Granting accessibility or input monitoring happens in System
    /// Settings, which touches none of the files Clyde watches — so the
    /// advisory sat there saying the permission was missing long after
    /// it had been given, and the only way out was to quit and reopen.
    /// Two syscalls every fifteen seconds, and only while one of those
    /// two issues is on screen.
    private var permissionRecheckTimer: Timer?
    static let permissionRecheckInterval: TimeInterval = 15

    /// Whether compact's advisory is opened out to its full text.
    ///
    /// It lives here rather than in the view because the compact window
    /// computes its own height and refuses any size its content asks
    /// for — so a panel that does not know the advisory is open renders
    /// it into a window that never grew, and the text is cut off at the
    /// bottom edge. Which is exactly what shipped.
    @Published var compactAdvisoryExpanded = false
    /// Whether the history store opened. The panel's route into the review
    /// window is hidden when it did not, rather than offering a button that
    /// silently does nothing.
    @Published var historyAvailable = false
    /// Session IDs whose subagent list is currently expanded past the 3-visible cap.
    /// In-memory only — resets on relaunch. Auto-pruned in real time when a session's
    /// active count drops to 3 or fewer.
    @Published var expandedSubagentSessions: Set<UUID> = []
    @Published var widgetVisible: Bool {
        didSet { UserDefaults.standard.set(widgetVisible, forKey: Self.widgetVisibleKey) }
    }

    let processMonitor: ProcessMonitor
    let terminalLauncher: TerminalLauncher
    let notificationService: NotificationService
    let attentionMonitor: AttentionMonitor
    /// Reads the questions the hook is waiting on and writes the answers.
    let permissionStore = PermissionRequestStore()
    let activityLog: ActivityLog
    let pushService: PushService

    /// Drives the first-run coachmark tour. Owned here so the same
    /// instance is shared between the expanded panel and the Settings
    /// window via `.environmentObject`.
    let coachmarks: CoachmarkController

    /// Whether any non-ghost session is currently being tracked. Used by
    /// the coachmark tour to pick the with-sessions vs empty-state branch
    /// at first panel expand.
    var hasLiveSessions: Bool {
        processMonitor.sessions.contains { !$0.isGhost }
    }

    /// Plain-language summary of the menu-bar capsule's current state, used
    /// as the VoiceOver label on `WidgetView` and (transitively, with the
    /// "Clyde, " prefix stripped) the menu-bar status item's accessibility
    /// value. Keeping the source of truth here means both surfaces always
    /// announce the same thing.
    var widgetAccessibilityLabel: String {
        let attentionPIDs = attentionMonitor.attentionPIDs
        let sessions = processMonitor.sessions.filter { !$0.isGhost }
        if sessions.isEmpty { return "Clyde, no active sessions" }
        let attention = sessions.filter { attentionPIDs.contains($0.pid) }.count
        let working = sessions.filter { $0.status == .busy && !attentionPIDs.contains($0.pid) }.count
        let ready = sessions.count - attention - working
        var parts: [String] = ["Clyde"]
        if attention > 0 { parts.append("\(attention) needs attention") }
        if working > 0 { parts.append("\(working) working") }
        if ready > 0 { parts.append("\(ready) ready") }
        return parts.joined(separator: ", ")
    }

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
    /// Watchers on `~/.config/cleat/` (dir) and `~/.config/cleat/config`
    /// (file) so the cleat-hooks-disabled banner appears the moment
    /// the user toggles cleat's hooks capability, instead of waiting
    /// for the 60-second safety-net timer to tick. We watch BOTH
    /// because cleat's `--disable hooks` truncates the file via
    /// unlink+create (caught by the dir watcher) but `--enable hooks`
    /// writes to the existing file in place (NOT caught by the dir
    /// watcher — dir-level FSEvents only fire on add/delete/rename
    /// inside the dir, not on content changes to existing files).
    private var cleatConfigDirSource: DispatchSourceFileSystemObject?
    private var cleatConfigDirFD: Int32 = -1
    private var cleatConfigFileSource: DispatchSourceFileSystemObject?
    private var cleatConfigFileFD: Int32 = -1
    private var cleatConfigRetryTimer: Timer?

    deinit {
        // Release everything we own. The class is @MainActor but deinit runs
        // nonisolated; cancelling tasks/sources/timers is safe from any
        // context, and the dispatch source's cancel handler closes hookDirFD.
        errorClearTask?.cancel()
        hookDirSource?.cancel()
        settingsFileSource?.cancel()
        settingsWatcherDebounce?.cancel()
        hookHealTimer?.invalidate()
        cleatConfigDirSource?.cancel()
        cleatConfigFileSource?.cancel()
        cleatConfigRetryTimer?.invalidate()
    }

    convenience init() {
        self.init(
            processMonitor: ProcessMonitor(),
            terminalLauncher: TerminalLauncher(),
            notificationService: NotificationService(),
            attentionMonitor: AttentionMonitor(),
            pushService: PushService()
        )
    }

    convenience init(processMonitor: ProcessMonitor) {
        self.init(
            processMonitor: processMonitor,
            terminalLauncher: TerminalLauncher(),
            notificationService: NotificationService(),
            attentionMonitor: AttentionMonitor(),
            pushService: PushService()
        )
    }

    init(
        processMonitor: ProcessMonitor,
        terminalLauncher: TerminalLauncher,
        notificationService: NotificationService,
        attentionMonitor: AttentionMonitor,
        pushService: PushService
    ) {
        self.processMonitor = processMonitor
        self.terminalLauncher = terminalLauncher
        self.notificationService = notificationService
        self.attentionMonitor = attentionMonitor
        self.pushService = pushService
        self.activityLog = ActivityLog(
            processMonitor: processMonitor,
            attentionMonitor: attentionMonitor
        )
        self.coachmarks = CoachmarkController(
            onboardingShown: { UserDefaults.standard.bool(forKey: AppDelegate.onboardingShownKey) }
        )
        self.widgetVisible = (UserDefaults.standard.object(forKey: Self.widgetVisibleKey) as? Bool) ?? true

        processMonitor.onSessionBecameIdle = { [weak self] session in
            guard let self else { return }
            if session.isGhost { return }
            if self.attentionMonitor.attentionPIDs.contains(session.pid) {
                return
            }
            self.notificationService.sendNotification(for: session)
            self.notificationService.playReadySound(for: session)
            self.pushService.notifySessionIdle(session)
        }

        // Forward ProcessMonitor updates to our own observers.
        //
        // Historical note: we used to clear the attention flag here whenever a
        // session was seen as .busy, on the theory that "busy means user is
        // working in that session again". That was wrong — permission
        // requests happen *while* Claude is still busy (Stop hasn't fired),
        // so clearing attention on busy immediately wiped every permission
        // alert. Attention is now only cleared by the hook script
        // (PreToolUse = user answered, Stop = turn ended, SessionEnd =
        // session closed) or by process death (scan sees kill fails).
        processMonitor.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // Auto-prune expanded-subagent state when a session's active count
        // drops to 3 or fewer — the "show more" toggle becomes irrelevant.
        processMonitor.$sessions
            .sink { [weak self] sessions in
                guard let self else { return }
                self.expandedSubagentSessions = self.expandedSubagentSessions.filter { sid in
                    (sessions.first { $0.id == sid }?.activeSubagents.count ?? 0) > 3
                }
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
            self.notificationService.playAttentionSound(for: session)
            self.notificationService.sendNotification(for: session)
            self.pushService.notifyAttentionNeeded(session)
        }
    }

    /// Which shape the panel takes when it opens.
    enum PanelMode: String {
        case full
        case compact
    }

    static let panelModeKey = "panelMode"
    static let compactRowCapKey = "compactRowCap"

    static func storedPanelMode() -> PanelMode {
        UserDefaults.standard.string(forKey: panelModeKey)
            .flatMap(PanelMode.init(rawValue:)) ?? .full
    }

    static func storePanelMode(_ mode: PanelMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: panelModeKey)
    }

    /// The panel reopens in the mode it was left in.
    @Published var panelMode: PanelMode = AppViewModel.storedPanelMode() {
        didSet {
            guard panelMode != oldValue else { return }
            Self.storePanelMode(panelMode)
        }
    }

    /// How many rows compact shows before the quiet sessions drop off.
    @Published var compactRowCap: Int = {
        let saved = UserDefaults.standard.integer(forKey: AppViewModel.compactRowCapKey)
        return saved > 0 ? saved : CompactRootView.defaultRowCap
    }() {
        didSet { UserDefaults.standard.set(compactRowCap, forKey: Self.compactRowCapKey) }
    }

    /// Permission requests the hook is waiting on. Empty unless the
    /// user turned panel answering on — nothing writes a request
    /// otherwise.
    @Published private(set) var permissionRequests: [PermissionRequest] = []

    /// Off by default. While off, Clyde publishes no readiness marker,
    /// so the hook never waits and permission prompts behave exactly as
    /// they do without Clyde installed.
    @Published var answerPermissionsInPanel: Bool = UserDefaults.standard
        .bool(forKey: PermissionRequestStore.settingKey) {
        didSet {
            UserDefaults.standard.set(answerPermissionsInPanel,
                                      forKey: PermissionRequestStore.settingKey)
            // Take effect now rather than on the next tick: switching
            // off should stop sessions waiting immediately.
            permissionStore.scan()
        }
    }

    func answerPermissionRequest(_ request: PermissionRequest, with decision: PermissionDecision) {
        permissionStore.answer(request, with: decision)
    }

    private func startPermissionStore() {
        permissionStore.start()
        permissionStore.$pending
            .receive(on: RunLoop.main)
            .sink { [weak self] requests in self?.permissionRequests = requests }
            .store(in: &cancellables)
    }

    func toggleExpanded() {
        isCollapsed.toggle()
    }

    func toggleSubagentExpansion(_ sessionID: UUID) {
        if expandedSubagentSessions.contains(sessionID) {
            expandedSubagentSessions.remove(sessionID)
        } else {
            expandedSubagentSessions.insert(sessionID)
        }
    }

    func updatePollingInterval(_ interval: Double) {
        processMonitor.updatePollingInterval(interval)
    }

    func focusSession(_ session: Session) {
        // NOTE: we deliberately do NOT call clearAttention here.
        // Clicking a row means "show me the terminal" — the user
        // hasn't answered the permission prompt yet. The hook script
        // handles the cleanup: PreToolUse fires once the user grants
        // or denies, removing the event file, and the next
        // AttentionMonitor scan tick drops the PID from attentionPIDs.
        // Clearing attention eagerly on click caused "Needs Input" to
        // vanish the instant the user tapped the row, even though the
        // prompt was still sitting in the terminal unanswered.
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
        startPermissionStore()
        // One-shot legacy migration must run BEFORE the first health check,
        // otherwise the check sees the old `clyde-notify.sh` file in place
        // and reports "everything fine" while settings.json points nowhere.
        HookInstaller.migrateLegacyHookIfNeeded()
        ensureHookHealthy()

        // Coming back from System Settings is the moment a grant is
        // most likely to have just happened.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.hookHealthIssue != nil else { return }
                self.ensureHookHealthy()
            }
        }
        startHookSelfHealing()
        startCleatConfigWatching()
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
            // Explicit `[weak self]` on the Task — Swift 6 strict
            // concurrency won't let the outer weak ref cross the
            // Task boundary implicitly.
            Task { @MainActor [weak self] in self?.ensureHookHealthy() }
        }
    }

    /// Watch `~/.config/cleat/` for changes. When the user toggles
    /// cleat's `hooks` capability with `cleat config --enable/disable
    /// hooks`, cleat rewrites the `config` file in that directory; the
    /// `cleatHooksCapDisabled` advisory needs to fire (or clear)
    /// immediately, not after the 60-second `hookHealTimer` ticks.
    ///
    /// The dir may not exist yet if the user has never run cleat. In
    /// that case we set up a one-minute retry timer that keeps trying
    /// to attach until either the dir appears or the app exits — once
    /// attached, the timer is invalidated and the FSEvents source
    /// carries the load.
    private func startCleatConfigWatching() {
        attachCleatConfigWatcher()
        // If attach failed (dir didn't exist), retry on a slow tick.
        // 60 s matches `hookHealTimer` — same trade-off between
        // freshness and wakeups when the user is idle.
        cleatConfigRetryTimer?.invalidate()
        cleatConfigRetryTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.attachCleatConfigWatcher() }
        }
    }

    private func attachCleatConfigWatcher() {
        let configDir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".config/cleat", isDirectory: true)
        guard FileManager.default.fileExists(atPath: configDir.path) else {
            return
        }

        // Dir watcher catches `cleat config --disable hooks` (which
        // truncates the file via unlink+create on cleat ≥ 0.x) plus
        // first-time creation of the config file by `cleat config`.
        if cleatConfigDirSource == nil {
            let fd = open(configDir.path, O_EVTONLY)
            if fd >= 0 {
                cleatConfigDirFD = fd
                let source = DispatchSource.makeFileSystemObjectSource(
                    fileDescriptor: fd,
                    eventMask: [.write, .delete, .rename, .extend, .attrib],
                    queue: DispatchQueue.main
                )
                source.setEventHandler { [weak self] in
                    // The dir changed — could be add/delete/rename of
                    // the `config` file. Re-bind the file watcher so
                    // it tracks the (possibly new) inode, then trigger
                    // a recheck.
                    self?.rebindCleatConfigFileWatcher()
                    self?.scheduleCleatConfigRecheck()
                }
                // Capture the fd locally so we close the file
                // descriptor THIS handler was created for, not
                // whatever value `cleatConfigDirFD` happens to hold
                // when the cancel handler runs later. Belt-and-braces
                // even though the dir watcher isn't rebound today —
                // future-proofs against the file-watcher's rebind
                // pattern leaking into here.
                source.setCancelHandler { [weak self] in
                    close(fd)
                    if self?.cleatConfigDirFD == fd { self?.cleatConfigDirFD = -1 }
                }
                source.resume()
                cleatConfigDirSource = source
            }
        }

        // File watcher catches in-place content modifications, which
        // `cleat config --enable hooks` performs (writes the new caps
        // list into the existing inode without unlink+create). Without
        // this, enable→banner-clears never fires automatically.
        rebindCleatConfigFileWatcher()
    }

    /// (Re)bind the file-level watcher to the current `config` inode.
    /// Called both during initial attach and whenever the dir watcher
    /// fires, since the file we were tracking may have been deleted
    /// and re-created (a different inode → our old fd is stale).
    private func rebindCleatConfigFileWatcher() {
        cleatConfigFileSource?.cancel()
        cleatConfigFileSource = nil

        let configFile = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".config/cleat/config")
        guard FileManager.default.fileExists(atPath: configFile.path) else {
            // File doesn't exist (yet) — the dir watcher will catch
            // its eventual creation and call us back here.
            return
        }
        let fd = open(configFile.path, O_EVTONLY)
        guard fd >= 0 else { return }
        cleatConfigFileFD = fd
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .attrib, .delete, .rename],
            queue: DispatchQueue.main
        )
        source.setEventHandler { [weak self] in
            self?.scheduleCleatConfigRecheck()
        }
        // Capture the fd locally — the file watcher gets rebound on
        // every dir event, so by the time an old source's cancel
        // handler fires, `cleatConfigFileFD` may already point at a
        // newer fd belonging to a different watcher. Reading the
        // instance var would silently close the wrong fd and leak
        // the original one.
        source.setCancelHandler { [weak self] in
            close(fd)
            if self?.cleatConfigFileFD == fd { self?.cleatConfigFileFD = -1 }
        }
        source.resume()
        cleatConfigFileSource = source
    }

    private var cleatConfigDebounce: DispatchWorkItem?
    private func scheduleCleatConfigRecheck() {
        cleatConfigDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.ensureHookHealthy()
        }
        cleatConfigDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// Auto-install or auto-repair the hook on startup.
    ///
    /// Runs off the main actor — file IO + JSON parsing shouldn't block the
    /// app launch. Result is delivered back to the main actor for UI binding.
    ///
    /// We never silently overwrite a working install. We only act when:
    ///  - the hook is missing AND the user hasn't explicitly opted out, or
    ///  - the install is corrupt / outdated / missing events (always repair).
    /// Starts polling while a permission is missing, stops when it is
    /// not. Anything else — a broken install, a disabled cleat
    /// capability — is fixed by touching a file Clyde already watches.
    @MainActor
    private func updatePermissionRecheck(for issue: HookInstaller.HealthIssue?) {
        let waitingOnUserGrant: Bool
        switch issue {
        case .accessibilityNotTrusted, .inputMonitoringNotTrusted: waitingOnUserGrant = true
        default: waitingOnUserGrant = false
        }

        guard waitingOnUserGrant else {
            permissionRecheckTimer?.invalidate()
            permissionRecheckTimer = nil
            return
        }
        guard permissionRecheckTimer == nil else { return }

        permissionRecheckTimer = Timer.scheduledTimer(
            withTimeInterval: Self.permissionRecheckInterval, repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.ensureHookHealthy() }
        }
    }

    private func ensureHookHealthy() {
        let optedOut = UserDefaults.standard.bool(forKey: Self.hookOptOutKey)
        Task.detached(priority: .utility) {
            let issue = HookInstaller.healthCheck()
            guard let issue else {
                // No issue → clear the in-memory dismiss set so
                // banners reappear if the underlying state flips
                // back later in this same session.
                await MainActor.run {
                    self.dismissedBannerIdentities.removeAll()
                    self.hookHealthIssue = nil
                }
                return
            }
            // User clicked × on THIS issue's banner this session →
            // keep hidden until the issue resolves or Clyde restarts.
            // The detection itself still ticks normally, so the
            // moment it clears and recurs the banner is back.
            let identity = issue.dismissalIdentity
            let dismissed = await MainActor.run {
                identity.map { self.dismissedBannerIdentities.contains($0) } ?? false
            }
            if dismissed {
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
            case .scriptMissing, .scriptNotExecutable, .outdated, .scriptVersionUnreadable, .missingEvents, .staleEvents:
                shouldAutoInstall = true
            case .autoRepairFailed:
                shouldAutoInstall = false
            case .accessibilityNotTrusted, .inputMonitoringNotTrusted:
                // Only macOS can grant these; the banner links straight
                // to the right System Settings pane for whichever one is
                // missing. Reinstalling the hook would do nothing.
                shouldAutoInstall = false
            case .cleatHooksCapDisabled:
                // Pure advisory — Clyde can't enable cleat's capability
                // for the user (that requires `cleat config --enable
                // hooks` interactively). The banner tells them what
                // to do; reinstalling Clyde's hook wouldn't help.
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
            await MainActor.run {
                self.hookHealthIssue = finalIssue
                self.updatePermissionRecheck(for: finalIssue)
            }
        }
    }

    /// Dismiss the currently visible banner (× button). Snoozes the
    /// banner for the rest of this Clyde session — the issue keeps
    /// being detected, but the banner stays hidden until either:
    ///  • the issue resolves once (e.g. user enables the cap), then
    ///    reoccurs (set is cleared on resolve), or
    ///  • the user relaunches Clyde (set lives in memory only).
    /// No-op for non-dismissable issues.
    func dismissCurrentBanner() {
        guard let issue = hookHealthIssue,
              issue.isDismissable,
              let identity = issue.dismissalIdentity else {
            return
        }
        dismissedBannerIdentities.insert(identity)
        hookHealthIssue = nil
    }

    /// Banners the user clicked × on during the current session.
    /// Deliberately not persisted: relaunching Clyde is a fresh
    /// start, and the user gets the next reminder cheaply. Cleared
    /// inside `ensureHookHealthy` whenever the health check returns
    /// nil so an on/off toggle re-surfaces the banner without
    /// requiring a relaunch.
    private var dismissedBannerIdentities: Set<String> = []

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

    /// Wipe state for a single session: every hook-written marker
    /// (info / busy / error / subagent / tool / plan) plus any pending
    /// attention event. Used by the per-session reset action in the
    /// expanded view's context menu — the manual escape hatch when a
    /// marker (typically -plan) wedges in a state that no future hook
    /// event will resolve.
    func resetSession(_ session: Session) {
        if let sid = session.sessionId {
            let suffixes = ["info", "busy", "error", "subagent", "tool", "plan"]
            for suffix in suffixes {
                try? FileManager.default.removeItem(
                    at: AppPaths.stateDir.appendingPathComponent("\(sid)-\(suffix)")
                )
            }
            try? FileManager.default.removeItem(
                at: AppPaths.eventsDir.appendingPathComponent("\(sid).json")
            )
            try? FileManager.default.removeItem(
                at: AppPaths.stateDir.appendingPathComponent("\(sid)-agents")
            )
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
