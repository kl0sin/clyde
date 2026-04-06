import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var appViewModel: AppViewModel
    @AppStorage("pollingInterval") private var pollingInterval: Double = 3.0
    @AppStorage("soundEnabled") private var soundEnabled: Bool = true
    @AppStorage("selectedSound") private var selectedSound: String = "Glass"
    @AppStorage("attentionSound") private var attentionSound: String = "Hero"

    private let availableSounds = ["Glass", "Blow", "Bottle", "Frog", "Funk", "Hero", "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink"]

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Settings")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
                Button(action: { appViewModel.showSettings = false }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.gray)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(white: 0.13))
            .overlay(
                Rectangle().frame(height: 1).foregroundColor(Color(white: 0.2)),
                alignment: .bottom
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {

                    // Monitoring section
                    SettingsSection(title: "Monitoring") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Check every")
                                    .font(.system(size: 12))
                                    .foregroundColor(.white)
                                Spacer()
                                Text("\(Int(pollingInterval))s")
                                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                                    .foregroundColor(Color(white: 0.6))
                            }
                            Slider(value: $pollingInterval, in: 1...10, step: 1)
                                .onChange(of: pollingInterval) { _ in
                                    appViewModel.updatePollingInterval(pollingInterval)
                                }
                        }
                    }

                    // Sound section
                    SettingsSection(title: "Sound") {
                        Toggle(isOn: $soundEnabled) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Play sound when ready")
                                    .font(.system(size: 12))
                                    .foregroundColor(.white)
                                Text("When a session finishes processing")
                                    .font(.system(size: 10))
                                    .foregroundColor(Color(white: 0.45))
                            }
                        }
                        .toggleStyle(.switch)
                        .onChange(of: soundEnabled) { _ in
                            appViewModel.notificationService.soundEnabled = soundEnabled
                        }

                        if soundEnabled {
                            Divider().background(Color(white: 0.2))

                            VStack(alignment: .leading, spacing: 4) {
                                Text("When session becomes ready")
                                    .font(.system(size: 10))
                                    .foregroundColor(Color(white: 0.5))
                                HStack {
                                    Spacer()
                                    Picker("", selection: $selectedSound) {
                                        ForEach(availableSounds, id: \.self) { sound in
                                            Text(sound).tag(sound)
                                        }
                                    }
                                    .labelsHidden()
                                    .pickerStyle(.menu)
                                    .frame(width: 130)
                                    .onChange(of: selectedSound) { newSound in
                                        appViewModel.notificationService.selectedSound = newSound
                                        NSSound(named: NSSound.Name(newSound))?.play()
                                    }
                                }
                            }

                            Divider().background(Color(white: 0.2))

                            VStack(alignment: .leading, spacing: 4) {
                                Text("When permission is required")
                                    .font(.system(size: 10))
                                    .foregroundColor(Color(white: 0.5))
                                HStack {
                                    Spacer()
                                    Picker("", selection: $attentionSound) {
                                        ForEach(availableSounds, id: \.self) { sound in
                                            Text(sound).tag(sound)
                                        }
                                    }
                                    .labelsHidden()
                                    .pickerStyle(.menu)
                                    .frame(width: 130)
                                    .onChange(of: attentionSound) { newSound in
                                        appViewModel.notificationService.attentionSound = newSound
                                        NSSound(named: NSSound.Name(newSound))?.play()
                                    }
                                }
                            }
                        }
                    }

                    // Claude integration section
                    SettingsSection(title: "Claude Integration") {
                        ClaudeHooksRow()
                    }

                    // About section
                    SettingsSection(title: "About") {
                        HStack {
                            ClydeAnimationView(state: .idle, pixelSize: 2)
                                .frame(width: 32, height: 32)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Clyde")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(.white)
                                Text("Claude Code Session Monitor")
                                    .font(.system(size: 10))
                                    .foregroundColor(Color(white: 0.45))
                            }
                        }

                        Divider().background(Color(white: 0.2))

                        Button(action: {
                            NSApplication.shared.terminate(nil)
                        }) {
                            HStack {
                                Image(systemName: "power")
                                    .font(.system(size: 11))
                                Text("Quit Clyde")
                                    .font(.system(size: 12))
                            }
                            .foregroundColor(.red)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(Color.red.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: NSColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1)))
        .onAppear {
            soundEnabled = appViewModel.notificationService.soundEnabled
            selectedSound = appViewModel.notificationService.selectedSound
            attentionSound = appViewModel.notificationService.attentionSound
        }
    }
}

struct ClaudeHooksRow: View {
    @State private var isInstalled: Bool = HookInstaller.isInstalled
    @State private var errorMessage: String?
    @State private var isWorking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Attention notifications")
                    .font(.system(size: 12))
                    .foregroundColor(.white)
                Text("Detect when Claude needs permission or input")
                    .font(.system(size: 10))
                    .foregroundColor(Color(white: 0.45))
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 10))
                    .foregroundColor(.red)
            }

            Button(action: toggle) {
                HStack {
                    Image(systemName: isInstalled ? "checkmark.circle.fill" : "arrow.down.circle")
                        .font(.system(size: 11))
                    Text(isInstalled ? "Installed — click to remove" : "Install Claude hook")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(isInstalled ? .green : .blue)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background((isInstalled ? Color.green : Color.blue).opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .disabled(isWorking)
        }
    }

    private func toggle() {
        isWorking = true
        errorMessage = nil
        do {
            if isInstalled {
                try HookInstaller.uninstall()
            } else {
                try HookInstaller.install()
            }
            isInstalled = HookInstaller.isInstalled
        } catch {
            errorMessage = error.localizedDescription
        }
        isWorking = false
    }
}

struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(Color(white: 0.4))
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
