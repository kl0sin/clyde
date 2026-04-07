import SwiftUI
import AppKit

/// The Clyde UI is intentionally always-dark, even on light system mode,
/// so the menu-bar widget reads the same regardless of wallpaper or
/// appearance setting. Keeping the background colour in one named place
/// means future tweaks don't drift across multiple call sites.
enum SettingsTheme {
    static let panelBackground = Color(nsColor: NSColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1))
}

struct SettingsView: View {
    @ObservedObject var appViewModel: AppViewModel
    @ObservedObject var notificationService: NotificationService
    @AppStorage("pollingInterval") private var pollingInterval: Double = AppConstants.defaultPollingInterval
    @State private var copiedDiagnostics = false
    @State private var resetConfirmation = false
    @State private var resetDone = false
    /// Currently-playing preview sound, kept so we can stop it before
    /// starting another. Without this, rapidly clicking through the picker
    /// stacks every selected sound on top of the previous one.
    @State private var previewSound: NSSound?

    init(appViewModel: AppViewModel) {
        self.appViewModel = appViewModel
        self.notificationService = appViewModel.notificationService
    }

    private let availableSounds = [
        "Glass", "Blow", "Bottle", "Frog", "Funk", "Hero",
        "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink"
    ]

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    appearanceSection
                    monitoringSection
                    soundSection
                    SettingsSection(title: "Claude Integration") { ClaudeHooksRow(appViewModel: appViewModel) }
                    maintenanceSection
                    aboutSection
                }
                .padding(16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SettingsTheme.panelBackground)
    }

    private var header: some View {
        HStack {
            Text("Settings")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
            Spacer()
            Button(action: { appViewModel.showSettings = false }) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.gray)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(white: 0.13))
        .overlay(
            Rectangle().frame(height: 1).foregroundStyle(Color(white: 0.2)),
            alignment: .bottom
        )
    }

    private var appearanceSection: some View {
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
    }

    private var monitoringSection: some View {
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
                // Use `onEditingChanged` so we only restart the polling
                // task once the user releases the slider, instead of on
                // every drag tick.
                Slider(value: $pollingInterval, in: 1...10, step: 1, onEditingChanged: { editing in
                    if !editing {
                        appViewModel.updatePollingInterval(pollingInterval)
                    }
                })
            }
        }
    }

    private var soundSection: some View {
        SettingsSection(title: "Notifications") {
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

            Divider().background(Color(white: 0.2))

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
                    // Stop the previous preview before starting the next
                    // one — otherwise rapid picker clicks stack every
                    // sound on top of each other.
                    previewSound?.stop()
                    let next = NSSound(named: NSSound.Name(newSound))
                    next?.play()
                    previewSound = next
                }
            }
        }
    }

    private var maintenanceSection: some View {
        SettingsSection(title: "Maintenance") {
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
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var aboutSection: some View {
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
                    Text("Check for updates…")
                        .font(.system(size: 12))
                }
                .foregroundStyle(Color(white: 0.7))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(Color(white: 0.16))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)

            Divider().background(Color(white: 0.2))

            Button(action: {
                appViewModel.copyDiagnosticInfoToPasteboard()
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
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)

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
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
        }
    }
}

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
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                    Text(issue.bannerMessage)
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                }
                .padding(8)
                .background(Color.orange.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 6))
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
                .clipShape(RoundedRectangle(cornerRadius: 6))
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
            Text("·")
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
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color(white: 0.4))
                .tracking(0.5)

            VStack(alignment: .leading, spacing: 10) {
                content
            }
            .padding(12)
            .background(Color(white: 0.13))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}
