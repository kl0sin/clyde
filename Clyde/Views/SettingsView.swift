import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @ObservedObject var appViewModel: AppViewModel
    @AppStorage("pollingInterval") private var pollingInterval: Double = 3.0
    @AppStorage("notificationsEnabled") private var notificationsEnabled: Bool = true
    @AppStorage("launchAtLogin") private var launchAtLogin: Bool = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Settings")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
                Button(action: { appViewModel.showSettings = false }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12))
                        .foregroundColor(.gray)
                }
                .buttonStyle(.plain)
            }

            Divider().background(Color(white: 0.2))

            VStack(alignment: .leading, spacing: 6) {
                Text("Default Terminal")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.gray)
                    .textCase(.uppercase)

                Picker("", selection: .init(
                    get: { appViewModel.terminalLauncher.selectedTerminalName },
                    set: { appViewModel.terminalLauncher.selectedTerminalName = $0 }
                )) {
                    ForEach(appViewModel.terminalLauncher.availableTerminals, id: \.name) { terminal in
                        Text(terminal.name).tag(terminal.name)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Polling Interval")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.gray)
                    .textCase(.uppercase)

                HStack {
                    Slider(value: $pollingInterval, in: 1...10, step: 1)
                    Text("\(Int(pollingInterval))s")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.white)
                        .frame(width: 30)
                }
            }

            Toggle(isOn: $notificationsEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Notifications")
                        .font(.system(size: 13))
                        .foregroundColor(.white)
                    Text("Alert when a session becomes idle")
                        .font(.system(size: 11))
                        .foregroundColor(.gray)
                }
            }
            .toggleStyle(.switch)

            Toggle(isOn: $launchAtLogin) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Launch at Login")
                        .font(.system(size: 13))
                        .foregroundColor(.white)
                    Text("Start Clyde automatically")
                        .font(.system(size: 11))
                        .foregroundColor(.gray)
                }
            }
            .toggleStyle(.switch)
            .onChange(of: launchAtLogin) { newValue in
                do {
                    if newValue {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                } catch {
                    launchAtLogin = !newValue
                }
            }

            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: NSColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1)))
    }
}
