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
    @State private var showAcknowledgements = false
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
                    supportSection
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
                    .clipShape(RoundedRectangle(cornerRadius: 6))
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
                    // Make sure the parent dir exists, then touch the
                    // file if it doesn't, so Finder always has something
                    // to select instead of silently no-op'ing.
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
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)

                Divider().background(Color(white: 0.2))

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
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $showAcknowledgements) {
                AcknowledgementsSheet(isPresented: $showAcknowledgements)
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
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
        }
    }

    private var supportSection: some View {
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
                    .clipShape(RoundedRectangle(cornerRadius: 6))
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
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
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

/// Third-party license display. Lists every dependency Clyde links
/// against and reproduces the upstream license verbatim, as required
/// by their respective terms.
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
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    /// Verbatim copy of the Sparkle LICENSE file (MIT). Bundled inline so
    /// the acknowledgements screen works without filesystem access and
    /// survives any future bundling changes. Update if Sparkle is upgraded
    /// across a license boundary.
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
