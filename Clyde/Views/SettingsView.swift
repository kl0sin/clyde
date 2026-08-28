import SwiftUI
import AppKit

/// The Clyde UI is intentionally always-dark, even on light system mode,
/// so the menu-bar widget reads the same regardless of wallpaper or
/// appearance setting. Keeping the background colour in one named place
/// means future tweaks don't drift across multiple call sites.
enum SettingsTheme {
    static let panelBackground = Color(nsColor: NSColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1))
}

// MARK: - Settings Tab

enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case notifications
    case push
    case claude
    case advanced
    case about

    var id: String { rawValue }

    var label: String {
        switch self {
        case .general:       return "General"
        case .notifications: return "Notifications"
        case .push:          return "Push"
        case .claude:        return "Claude"
        case .advanced:      return "Advanced"
        case .about:         return "About"
        }
    }

    var icon: String {
        switch self {
        case .general:       return "gearshape"
        case .notifications: return "bell"
        case .push:          return "iphone.radiowaves.left.and.right"
        case .claude:        return "terminal"
        case .advanced:      return "wrench.and.screwdriver"
        case .about:         return "info.circle"
        }
    }
}

// MARK: - Root

struct SettingsView: View {
    @ObservedObject var appViewModel: AppViewModel
    @ObservedObject var notificationService: NotificationService
    @ObservedObject var pushService: PushService
    let historyStore: HistoryStore?
    @State private var selectedTab: SettingsTab = .general

    init(appViewModel: AppViewModel, historyStore: HistoryStore?) {
        self.appViewModel = appViewModel
        self.notificationService = appViewModel.notificationService
        self.pushService = appViewModel.pushService
        self.historyStore = historyStore
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar

            Rectangle()
                .fill(Color(white: 0.18))
                .frame(width: 1)

            detailContent
        }
        .frame(minWidth: 560, minHeight: 440)
        .background(SettingsTheme.panelBackground)
    }

    private static let accentPurple = SessionTheme.processingColor

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsTab.allCases) { tab in
                let isSelected = selectedTab == tab
                Button(action: { selectedTab = tab }) {
                    HStack(spacing: 8) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(isSelected ? .white : TextColor.tertiary)
                            .frame(width: 18)
                        Text(tab.label)
                            .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                            .foregroundStyle(isSelected ? .white : TextColor.tertiary)
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
                            .fill(isSelected ? Self.accentPurple.opacity(0.22) : Color.clear)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
                            .strokeBorder(isSelected ? Self.accentPurple.opacity(0.4) : Color.clear, lineWidth: 0.5)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(.isButton)
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
            Spacer()
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 8)
        .frame(width: 160)
        .background(Color(white: 0.07))
    }

    @ViewBuilder
    private var detailContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                switch selectedTab {
                case .general:
                    GeneralSettingsTab(appViewModel: appViewModel)
                case .notifications:
                    NotificationsSettingsTab(notificationService: notificationService)
                case .push:
                    PushSettingsTab(pushService: pushService)
                case .claude:
                    ClaudeSettingsTab(appViewModel: appViewModel)
                case .advanced:
                    AdvancedSettingsTab(appViewModel: appViewModel, historyStore: historyStore)
                case .about:
                    AboutSettingsTab()
                }
            }
            .padding(Spacing.lg)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(SettingsTheme.panelBackground)
        .tint(Self.accentPurple)
    }
}

// MARK: - General

struct GeneralSettingsTab: View {
    @ObservedObject var appViewModel: AppViewModel
    @AppStorage("pollingInterval") private var pollingInterval: Double = AppConstants.defaultPollingInterval
    @State private var replayQueued: Bool = false
    // Login-at-launch state. We bind the toggle to a local @State
    // mirror because the underlying SMAppService.status is a
    // snapshot — toggling the binding immediately while the system
    // call runs avoids a one-frame flicker if registration takes a
    // few milliseconds, and we refresh from the system on appear.
    @State private var launchAtLogin: Bool = LoginItemService.isEnabled
    @State private var launchAtLoginError: String?
    @State private var launchAtLoginRequiresApproval: Bool = false

    var body: some View {
        SettingsSection(title: "Appearance") {
            Toggle(isOn: $appViewModel.widgetVisible) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Show floating widget")
                        .font(.system(size: 12))
                        .foregroundStyle(.white)
                    Text("When off, Clyde lives only in the menu bar — click the icon to open the session list.")
                        .font(.system(size: 10))
                        .foregroundStyle(Color(white: 0.45))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
        }

        SettingsSection(title: "Startup") {
            VStack(alignment: .leading, spacing: 6) {
                Toggle(isOn: Binding(
                    get: { launchAtLogin },
                    set: { newValue in
                        // Optimistic update — flips the UI immediately,
                        // then reconciles with the system status once
                        // the SMAppService call returns.
                        launchAtLogin = newValue
                        do {
                            try LoginItemService.setEnabled(newValue)
                            launchAtLoginError = nil
                        } catch {
                            launchAtLoginError = error.localizedDescription
                            // Reconcile back to the truth so the
                            // toggle doesn't lie to the user.
                            launchAtLogin = LoginItemService.isEnabled
                        }
                        launchAtLoginRequiresApproval = (LoginItemService.currentStatus == .requiresApproval)
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Launch at login")
                            .font(.system(size: 12))
                            .foregroundStyle(.white)
                        Text("Start Clyde automatically when you sign in to your Mac.")
                            .font(.system(size: 10))
                            .foregroundStyle(Color(white: 0.45))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)

                if launchAtLoginRequiresApproval {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Approval needed")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.orange)
                            Text("macOS hasn't approved Clyde as a login item yet. Open Login Items in System Settings to enable it.")
                                .font(.system(size: 10))
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Button("Open Login Items") {
                            LoginItemService.openSystemLoginItemsSettings()
                        }
                    }
                    .padding(8)
                    .background(Color.orange.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: Radius.small))
                }

                if let error = launchAtLoginError {
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .onAppear {
                // Refresh from the system in case the user changed it
                // via System Settings while we were running.
                launchAtLogin = LoginItemService.isEnabled
                launchAtLoginRequiresApproval = (LoginItemService.currentStatus == .requiresApproval)
            }
        }

        SettingsSection(title: "Monitoring") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Fallback poll interval")
                            .font(.system(size: 12))
                            .foregroundStyle(.white)
                        Text("Used when the Claude hook isn't installed")
                            .font(.system(size: 10))
                            .foregroundStyle(Color(white: 0.45))
                    }
                    Spacer()
                    Text("\(Int(pollingInterval))s")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color(white: 0.6))
                }
                Slider(value: $pollingInterval, in: 1...10, step: 1, onEditingChanged: { editing in
                    if !editing {
                        appViewModel.updatePollingInterval(pollingInterval)
                    }
                })
                .accessibilityLabel("Polling interval")
                .accessibilityValue("\(Int(pollingInterval)) seconds")
                .accessibilityHint("Drag to adjust how often Clyde polls for session changes")
            }
        }

        SettingsSection(title: "Keyboard Shortcuts") {
            VStack(alignment: .leading, spacing: 8) {
                ShortcutRow(keys: "⌃⌘C", description: "Toggle the expanded panel from anywhere")
                ShortcutRow(keys: "⌘,",  description: "Open Settings")
                ShortcutRow(keys: "⌘Q",  description: "Quit Clyde (from menu bar menu)")
            }
        }

        SettingsSection(title: "Welcome Tour") {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Welcome tour")
                            .font(.system(size: 12, weight: .medium))
                        Text("Replay the first-run tour that points out the session row, snooze, and the global hotkey.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer()

                    Button("Replay welcome tour") {
                        appViewModel.coachmarks.replay()
                        if !appViewModel.isCollapsed {
                            appViewModel.coachmarks.maybeStart(hasSessions: appViewModel.hasLiveSessions)
                        } else {
                            replayQueued = true
                        }
                    }
                    .accessibilityHint("Restarts the first-run tour")
                }
                .padding(.vertical, 8)

                if replayQueued {
                    Text("Tour will replay next time you open the panel.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }
            }
        }
        .onReceive(appViewModel.$isCollapsed) { isCollapsed in
            if !isCollapsed { replayQueued = false }
        }
    }
}

private struct ShortcutRow: View {
    let keys: String
    let description: String

    var body: some View {
        HStack(spacing: 12) {
            Text(keys)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color(white: 0.18))
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .frame(minWidth: 56, alignment: .leading)
            Text(description)
                .font(.system(size: 12))
                .foregroundStyle(Color(white: 0.75))
            Spacer()
        }
    }
}

// MARK: - Notifications

struct NotificationsSettingsTab: View {
    @ObservedObject var notificationService: NotificationService
    @State private var previewSound: NSSound?

    private let availableSounds = [
        "Glass", "Blow", "Bottle", "Frog", "Funk", "Hero",
        "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink"
    ]

    var body: some View {
        SettingsSection(title: "System Notifications") {
            Toggle(isOn: $notificationService.systemNotificationsEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("System notifications")
                        .font(.system(size: 12))
                        .foregroundStyle(.white)
                    Text("Show banners in macOS Notification Center")
                        .font(.system(size: 10))
                        .foregroundStyle(Color(white: 0.45))
                }
            }
            .toggleStyle(.switch)
        }

        SettingsSection(title: "Sounds") {
            Toggle(isOn: $notificationService.soundEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Play sound on state changes")
                        .font(.system(size: 12))
                        .foregroundStyle(.white)
                    Text("Different sounds for ready vs needs-input")
                        .font(.system(size: 10))
                        .foregroundStyle(Color(white: 0.45))
                }
            }
            .toggleStyle(.switch)

            if notificationService.soundEnabled {
                Divider().background(Color(white: 0.2))

                soundPickerRow(
                    label: "When session becomes ready",
                    selection: $notificationService.readySound
                )

                Divider().background(Color(white: 0.2))

                soundPickerRow(
                    label: "When permission is required",
                    selection: $notificationService.attentionSound
                )
            }
        }
    }

    private func soundPickerRow(label: String, selection: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(Color(white: 0.5))
            HStack {
                Spacer()
                Picker("", selection: selection) {
                    ForEach(availableSounds, id: \.self) { sound in
                        Text(sound).tag(sound)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 130)
                .onChange(of: selection.wrappedValue) { newSound in
                    previewSound?.stop()
                    let next = NSSound(named: NSSound.Name(newSound))
                    next?.play()
                    previewSound = next
                }
            }
        }
    }
}

// MARK: - Push Notifications

struct PushSettingsTab: View {
    @ObservedObject var pushService: PushService
    @State private var isTesting = false

    var body: some View {
        SettingsSection(title: "Push Provider") {
            VStack(alignment: .leading, spacing: 2) {
                Text("Send notifications to your phone when sessions change state.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(white: 0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Picker("Provider", selection: $pushService.provider) {
                ForEach(PushService.Provider.allCases) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }
            .pickerStyle(.segmented)
        }

        if pushService.provider != .none {
            providerConfig

            SettingsSection(title: "Triggers") {
                Toggle(isOn: $pushService.notifyOnIdle) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("When session becomes ready")
                            .font(.system(size: 12))
                            .foregroundStyle(.white)
                        Text("Claude finished processing and is waiting for input")
                            .font(.system(size: 10))
                            .foregroundStyle(Color(white: 0.45))
                    }
                }
                .toggleStyle(.switch)

                Divider().background(Color(white: 0.2))

                Toggle(isOn: $pushService.notifyOnAttention) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("When action is required")
                            .font(.system(size: 12))
                            .foregroundStyle(.white)
                        Text("Permission prompt or other input needed")
                            .font(.system(size: 10))
                            .foregroundStyle(Color(white: 0.45))
                    }
                }
                .toggleStyle(.switch)
            }

            SettingsSection(title: "Test") {
                testButton
            }
        }
    }

    @ViewBuilder
    private var providerConfig: some View {
        switch pushService.provider {
        case .none:
            EmptyView()
        case .ntfy:
            ntfyConfig
        case .pushover:
            pushoverConfig
        case .webhook:
            webhookConfig
        }
    }

    private var ntfyConfig: some View {
        SettingsSection(title: "ntfy Configuration") {
            settingsField(label: "Server", placeholder: "https://ntfy.sh", text: $pushService.ntfyServer)
            Divider().background(Color(white: 0.2))
            settingsField(label: "Topic", placeholder: "my-clyde-notifications", text: $pushService.ntfyTopic)
            Divider().background(Color(white: 0.2))
            settingsField(label: "Access token (optional)", placeholder: "tk_...", text: $pushService.ntfyToken, isSecure: true)

            VStack(alignment: .leading, spacing: 4) {
                Text("Install the ntfy app on your phone and subscribe to the same topic.")
                    .font(.system(size: 10))
                    .foregroundStyle(Color(white: 0.45))
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: {
                    if let url = URL(string: "https://ntfy.sh") {
                        NSWorkspace.shared.open(url)
                    }
                }) {
                    Text("ntfy.sh")
                        .font(.system(size: 10))
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var pushoverConfig: some View {
        SettingsSection(title: "Pushover Configuration") {
            settingsField(label: "User key", placeholder: "u...", text: $pushService.pushoverUserKey, isSecure: true)
            Divider().background(Color(white: 0.2))
            settingsField(label: "Application token", placeholder: "a...", text: $pushService.pushoverAppToken, isSecure: true)

            VStack(alignment: .leading, spacing: 4) {
                Text("Create an application at pushover.net to get your token, then install the Pushover app on your phone.")
                    .font(.system(size: 10))
                    .foregroundStyle(Color(white: 0.45))
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: {
                    if let url = URL(string: "https://pushover.net") {
                        NSWorkspace.shared.open(url)
                    }
                }) {
                    Text("pushover.net")
                        .font(.system(size: 10))
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var webhookConfig: some View {
        SettingsSection(title: "Webhook Configuration") {
            settingsField(label: "URL", placeholder: "https://example.com/webhook", text: $pushService.webhookURL)
            Divider().background(Color(white: 0.2))

            HStack {
                Text("Method")
                    .font(.system(size: 12))
                    .foregroundStyle(.white)
                Spacer()
                Picker("", selection: $pushService.webhookMethod) {
                    Text("POST").tag("POST")
                    Text("GET").tag("GET")
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 140)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("POST sends a JSON body with title, message, priority, and app fields. GET sends no body.")
                    .font(.system(size: 10))
                    .foregroundStyle(Color(white: 0.45))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func settingsField(label: String, placeholder: String, text: Binding<String>, isSecure: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(Color(white: 0.5))
            if isSecure {
                SecureField(placeholder, text: text)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
            } else {
                TextField(placeholder, text: text)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
            }
        }
    }

    private var testButton: some View {
        let isDisabled = !pushService.isConfigured || isTesting
        return VStack(alignment: .leading, spacing: 8) {
            Button(action: {
                isTesting = true
                pushService.lastTestResult = nil
                Task {
                    let result = await pushService.testPush()
                    pushService.lastTestResult = result
                    isTesting = false
                }
            }) {
                HStack {
                    if isTesting {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.7)
                    } else {
                        Image(systemName: isDisabled ? "paperplane.slash" : "paperplane")
                            .font(.system(size: 11))
                    }
                    Text(isTesting ? "Sending..." : "Send test notification")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(isDisabled ? TextColor.disabled : Color.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(Color(white: 0.18))
                .clipShape(RoundedRectangle(cornerRadius: Radius.small))
                .opacity(isDisabled ? 0.5 : 1.0)
            }
            .buttonStyle(.plain)
            .disabled(isDisabled)
            .help(isDisabled && !isTesting ? "Configure the push provider above to enable test sending" : "")

            if let result = pushService.lastTestResult {
                switch result {
                case .success(let msg):
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.green)
                        Text(msg)
                            .font(.system(size: 10))
                            .foregroundStyle(.green)
                    }
                case .failure(let err):
                    HStack(spacing: 4) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.red)
                        Text(err.message)
                            .font(.system(size: 10))
                            .foregroundStyle(.red)
                    }
                }
            }
        }
    }
}

// MARK: - Claude Integration

struct ClaudeSettingsTab: View {
    @ObservedObject var appViewModel: AppViewModel

    var body: some View {
        SettingsSection(title: "Claude Integration") {
            ClaudeHooksRow(appViewModel: appViewModel)
        }
    }
}

// MARK: - Advanced

struct AdvancedSettingsTab: View {
    @ObservedObject var appViewModel: AppViewModel
    let historyStore: HistoryStore?
    @State private var resetConfirmation = false
    @State private var resetDone = false

    // `eventCount`/`databaseSizeBytes`/`oldestEventDate` each take
    // `HistoryStore`'s serial ingest queue (mirroring the note on
    // `ReviewView.totals`/`projects`), so they're loaded once into state
    // rather than recomputed on every body pass — a computed property here
    // would retake that lock on every SwiftUI re-render and could stall the
    // main thread behind a 30s ingest tick. `.task` loads them when the
    // section appears; clearing reloads explicitly afterwards.
    @State private var historyEventCount: Int = 0
    @State private var historySizeBytes: Int64 = 0
    @State private var historyOldestDate: Date?
    @State private var clearHistoryConfirmation = false
    @State private var clearHistoryDone = false

    var body: some View {
        SettingsSection(title: "Data") {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Reveal Clyde data folder")
                        .font(.system(size: 12))
                        .foregroundStyle(.white)
                    Text("Opens ~/.clyde/ in Finder — useful when sharing diagnostics or inspecting hook state by hand.")
                        .font(.system(size: 10))
                        .foregroundStyle(Color(white: 0.45))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button(action: {
                    let dir = AppPaths.clydeDir
                    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(dir)
                }) {
                    HStack {
                        Image(systemName: "folder")
                            .font(.system(size: 11))
                        Text("Reveal in Finder")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(Color(white: 0.8))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(Color(white: 0.18))
                    .clipShape(RoundedRectangle(cornerRadius: Radius.small))
                }
                .buttonStyle(.plain)

                Divider().background(Color(white: 0.2))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Reveal hook log")
                        .font(.system(size: 12))
                        .foregroundStyle(.white)
                    Text("Selects ~/.clyde/logs/hook.log in Finder. Useful when reporting an issue — drag the file straight from there into a bug report.")
                        .font(.system(size: 10))
                        .foregroundStyle(Color(white: 0.45))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button(action: {
                    let logURL = AppPaths.clydeDir
                        .appendingPathComponent("logs")
                        .appendingPathComponent("hook.log")
                    try? FileManager.default.createDirectory(
                        at: logURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    if !FileManager.default.fileExists(atPath: logURL.path) {
                        FileManager.default.createFile(atPath: logURL.path, contents: nil)
                    }
                    NSWorkspace.shared.activateFileViewerSelecting([logURL])
                }) {
                    HStack {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 11))
                        Text("Reveal hook.log")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(Color(white: 0.8))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(Color(white: 0.18))
                    .clipShape(RoundedRectangle(cornerRadius: Radius.small))
                }
                .buttonStyle(.plain)
            }
        }

        SettingsSection(title: "History") {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Session history")
                        .font(.system(size: 12))
                        .foregroundStyle(.white)
                    // Retention is manual by design, so the cost has to be
                    // visible. Cleanup the user cannot see the need for is
                    // not cleanup.
                    Text(historySummaryText)
                        .font(.system(size: 10))
                        .foregroundStyle(Color(white: 0.45))
                        .fixedSize(horizontal: false, vertical: true)
                }

                if historyStore != nil {
                    Button(action: {
                        if clearHistoryConfirmation {
                            try? historyStore?.clear()
                            clearHistoryConfirmation = false
                            clearHistoryDone = true
                            Task {
                                await loadHistorySummary()
                                try? await Task.sleep(for: .seconds(2))
                                clearHistoryDone = false
                            }
                        } else {
                            clearHistoryConfirmation = true
                            Task {
                                try? await Task.sleep(for: .seconds(4))
                                clearHistoryConfirmation = false
                            }
                        }
                    }) {
                        HStack {
                            Image(systemName: clearHistoryDone ? "checkmark" : (clearHistoryConfirmation ? "exclamationmark.triangle.fill" : "trash"))
                                .font(.system(size: 11))
                            Text(clearHistoryDone ? "History cleared" : (clearHistoryConfirmation ? "Click again to confirm" : "Clear history"))
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(clearHistoryDone ? .green : (clearHistoryConfirmation ? .orange : Color(white: 0.8)))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background((clearHistoryDone ? Color.green : (clearHistoryConfirmation ? Color.orange : Color(white: 0.18))).opacity(clearHistoryConfirmation ? 0.15 : 0.6))
                        .clipShape(RoundedRectangle(cornerRadius: Radius.small))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .task {
            await loadHistorySummary()
        }

        SettingsSection(title: "Reset") {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Reset tracking state")
                        .font(.system(size: 12))
                        .foregroundStyle(.white)
                    Text("Wipes all session and event files in ~/.clyde/. Sessions will reappear on the next hook fire or pgrep poll. Use this if Clyde gets stuck in a wrong state.")
                        .font(.system(size: 10))
                        .foregroundStyle(Color(white: 0.45))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button(action: {
                    if resetConfirmation {
                        appViewModel.resetAllHookState()
                        resetConfirmation = false
                        resetDone = true
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            resetDone = false
                        }
                    } else {
                        resetConfirmation = true
                        Task {
                            try? await Task.sleep(for: .seconds(4))
                            resetConfirmation = false
                        }
                    }
                }) {
                    HStack {
                        Image(systemName: resetDone ? "checkmark" : (resetConfirmation ? "exclamationmark.triangle.fill" : "trash"))
                            .font(.system(size: 11))
                        Text(resetDone ? "State cleared" : (resetConfirmation ? "Click again to confirm" : "Reset all state"))
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(resetDone ? .green : (resetConfirmation ? .orange : Color(white: 0.8)))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background((resetDone ? Color.green : (resetConfirmation ? Color.orange : Color(white: 0.18))).opacity(resetConfirmation ? 0.15 : 0.6))
                    .clipShape(RoundedRectangle(cornerRadius: Radius.small))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var historySummaryText: String {
        guard historyStore != nil else { return "History tracking is unavailable." }
        return Self.historySummary(
            eventCount: historyEventCount,
            sizeBytes: historySizeBytes,
            oldestDate: historyOldestDate
        )
    }

    // Runs on the main actor (so assigning back to `@State` is safe) but
    // hands the actual synchronous, lock-taking queries to a detached task,
    // mirroring `ReviewView.load()` — the wait for the ingest queue happens
    // off the main thread rather than blocking the settings window.
    @MainActor
    private func loadHistorySummary() async {
        guard let store = historyStore else { return }
        let (count, size, oldest) = await Task.detached(priority: .userInitiated) {
            (store.eventCount(), store.databaseSizeBytes(), store.oldestEventDate())
        }.value
        historyEventCount = count
        historySizeBytes = size
        historyOldestDate = oldest
    }

    static func historySummary(eventCount: Int, sizeBytes: Int64, oldestDate: Date?) -> String {
        guard eventCount > 0 else { return "No history recorded yet." }
        let oldest = oldestDate.map {
            DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .none)
        } ?? "—"
        return "\(eventCount) events, \(formatSize(bytes: sizeBytes)), since \(oldest)."
    }

    static func formatSize(bytes: Int64) -> String {
        let mb = Double(bytes) / 1_048_576
        return mb < 1
            ? String(format: "%.0f KB", Double(bytes) / 1024)
            : String(format: "%.1f MB", mb)
    }
}

// MARK: - About

struct AboutSettingsTab: View {
    @State private var copiedDiagnostics = false
    @State private var showAcknowledgements = false

    var body: some View {
        SettingsSection(title: "About") {
            HStack {
                ClydeAnimationView(state: .idle, pixelSize: 2)
                    .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Clyde")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("Claude Code Session Monitor")
                        .font(.system(size: 10))
                        .foregroundStyle(Color(white: 0.45))
                    if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
                        Text("Version \(version)")
                            .font(.system(size: 9))
                            .foregroundStyle(Color(white: 0.35))
                    }
                }
            }

            Divider().background(Color(white: 0.2))

            Button(action: {
                UpdateController.shared.checkForUpdates(nil)
            }) {
                HStack {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 11))
                    Text("Check for updates...")
                        .font(.system(size: 12))
                }
                .foregroundStyle(Color(white: 0.7))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(Color(white: 0.16))
                .clipShape(RoundedRectangle(cornerRadius: Radius.small))
            }
            .buttonStyle(.plain)

            Divider().background(Color(white: 0.2))

            Button(action: {
                // Access AppViewModel through NotificationCenter to copy diagnostics
                NotificationCenter.default.post(name: .clydeCopyDiagnostics, object: nil)
                copiedDiagnostics = true
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    copiedDiagnostics = false
                }
            }) {
                HStack {
                    Image(systemName: copiedDiagnostics ? "checkmark" : "doc.on.clipboard")
                        .font(.system(size: 11))
                    Text(copiedDiagnostics ? "Copied to clipboard" : "Copy diagnostic info")
                        .font(.system(size: 12))
                }
                .foregroundStyle(copiedDiagnostics ? .green : Color(white: 0.7))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(Color(white: 0.16))
                .clipShape(RoundedRectangle(cornerRadius: Radius.small))
            }
            .buttonStyle(.plain)

            Divider().background(Color(white: 0.2))

            Button(action: { showAcknowledgements = true }) {
                HStack {
                    Image(systemName: "doc.text")
                        .font(.system(size: 11))
                    Text("Acknowledgements")
                        .font(.system(size: 12))
                }
                .foregroundStyle(Color(white: 0.7))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(Color(white: 0.16))
                .clipShape(RoundedRectangle(cornerRadius: Radius.small))
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $showAcknowledgements) {
                AcknowledgementsSheet(isPresented: $showAcknowledgements)
            }
        }

        SettingsSection(title: "Support development") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Clyde is free and MIT-licensed. If it's saving you time, you can chip in — it's entirely optional and there's no paid tier.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(white: 0.55))
                    .fixedSize(horizontal: false, vertical: true)

                Button(action: {
                    if let url = URL(string: "https://github.com/sponsors/kl0sin") {
                        NSWorkspace.shared.open(url)
                    }
                }) {
                    HStack {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.pink)
                        Text("Sponsor on GitHub")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white)
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 10))
                            .foregroundStyle(Color(white: 0.5))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(white: 0.18))
                    .clipShape(RoundedRectangle(cornerRadius: Radius.small))
                }
                .buttonStyle(.plain)

                Button(action: {
                    if let url = URL(string: "https://www.buymeacoffee.com/kl0sin") {
                        NSWorkspace.shared.open(url)
                    }
                }) {
                    HStack {
                        Image(systemName: "cup.and.saucer.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Color(red: 1.0, green: 0.85, blue: 0.3))
                        Text("Buy me a coffee")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white)
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 10))
                            .foregroundStyle(Color(white: 0.5))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(white: 0.18))
                    .clipShape(RoundedRectangle(cornerRadius: Radius.small))
                }
                .buttonStyle(.plain)
            }
        }

        Divider().background(Color(white: 0.2))

        Button(action: { NSApplication.shared.terminate(nil) }) {
            HStack {
                Image(systemName: "power")
                    .font(.system(size: 11))
                Text("Quit Clyde")
                    .font(.system(size: 12))
            }
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(Color.red.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: Radius.small))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Shared Components

struct ClaudeHooksRow: View {
    @ObservedObject var appViewModel: AppViewModel
    @State private var isInstalled: Bool = HookInstaller.isInstalled
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Real-time session tracking")
                    .font(.system(size: 12))
                    .foregroundStyle(.white)
                Text("Reports busy/idle and permission requests instantly via Claude Code hooks")
                    .font(.system(size: 10))
                    .foregroundStyle(Color(white: 0.45))
            }

            VStack(alignment: .leading, spacing: 4) {
                hookEventRow(name: "SessionStart", description: "Discovers a new session")
                hookEventRow(name: "SessionEnd", description: "Removes a closed session")
                hookEventRow(name: "UserPromptSubmit", description: "Marks session busy")
                hookEventRow(name: "Stop", description: "Marks session ready")
                hookEventRow(name: "PermissionRequest", description: "Triggers attention alert")
            }
            .padding(.vertical, 4)

            if let issue = appViewModel.hookHealthIssue, isInstalled {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            if let title = issue.bannerTitle {
                                Text(title)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.orange)
                            }
                            Text(issue.bannerMessage)
                                .font(.system(size: 10))
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if let command = issue.bannerCommand {
                        CopyableCommandChip(command: command)
                    }
                }
                .padding(8)
                .background(Color.orange.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: Radius.small))
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
            }

            Button(action: toggle) {
                HStack {
                    Image(systemName: isInstalled ? "checkmark.circle.fill" : "arrow.down.circle")
                        .font(.system(size: 11))
                    Text(isInstalled ? "Installed — click to remove" : "Install Claude hook")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(isInstalled ? .green : .blue)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background((isInstalled ? Color.green : Color.blue).opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: Radius.small))
            }
            .buttonStyle(.plain)
        }
    }

    private func hookEventRow(name: String, description: String) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isInstalled ? Color.green : Color(white: 0.3))
                .frame(width: 5, height: 5)
            Text(name)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(Color(white: 0.7))
            Text("\u{00B7}")
                .font(.system(size: 10))
                .foregroundStyle(Color(white: 0.35))
            Text(description)
                .font(.system(size: 10))
                .foregroundStyle(Color(white: 0.5))
            Spacer()
        }
    }

    private func toggle() {
        errorMessage = nil
        do {
            if isInstalled {
                try HookInstaller.uninstall()
                appViewModel.setHookOptOut(true)
            } else {
                try HookInstaller.install()
                appViewModel.setHookOptOut(false)
            }
            isInstalled = HookInstaller.isInstalled
            appViewModel.refreshHookHealth()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(TextColor.tertiary)
                .tracking(0.5)

            VStack(alignment: .leading, spacing: 10) {
                content
            }
            .padding(Spacing.sm)
            .background(Color(white: 0.13))
            .clipShape(RoundedRectangle(cornerRadius: Radius.medium))
        }
    }
}

/// Third-party license display.
struct AcknowledgementsSheet: View {
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Acknowledgements")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                Button(action: { isPresented = false }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color(white: 0.6))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(Color(white: 0.11))

            Divider().background(Color(white: 0.2))

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Clyde is built on the open-source work of others. Their licenses are reproduced below.")
                        .font(.system(size: 11))
                        .foregroundStyle(Color(white: 0.55))

                    licenseEntry(
                        name: "Sparkle",
                        url: "https://sparkle-project.org",
                        body: Self.sparkleLicense
                    )
                }
                .padding(18)
            }
            .background(Color(white: 0.09))
        }
        .frame(width: 520, height: 460)
        .background(Color(white: 0.09))
    }

    @ViewBuilder
    private func licenseEntry(name: String, url: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
            Text(url)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color(white: 0.5))
            Text(body)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color(white: 0.7))
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(white: 0.13))
                .clipShape(RoundedRectangle(cornerRadius: Radius.small))
        }
    }

    private static let sparkleLicense = """
    Copyright (c) 2006-2013 Andy Matuschak.
    Copyright (c) 2009-2013 Elgato Systems GmbH.
    Copyright (c) 2011-2014 Kornel Lesiński.
    Copyright (c) 2015-2017 Mayur Pawashe.
    Copyright (c) 2014 C.W. Betts.
    Copyright (c) 2014 Petroules Corporation.
    Copyright (c) 2014 Big Nerd Ranch.
    All rights reserved.

    Permission is hereby granted, free of charge, to any person obtaining a copy of
    this software and associated documentation files (the "Software"), to deal in
    the Software without restriction, including without limitation the rights to
    use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
    the Software, and to permit persons to whom the Software is furnished to do so,
    subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all
    copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
    FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
    COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
    IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
    CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
    """
}

// MARK: - Notification Names

extension Notification.Name {
    static let clydeOpenSettings = Notification.Name("clydeOpenSettings")
    static let clydeCopyDiagnostics = Notification.Name("clydeCopyDiagnostics")
}
