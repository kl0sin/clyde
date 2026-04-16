import SwiftUI

@main
struct ClydeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // SwiftUI requires at least one Scene. The `Settings` scene would
        // normally create a native Preferences window tied to the Cmd+,
        // shortcut — but our actual Settings UI lives in a window managed
        // by AppDelegate (`showSettingsWindow`). We keep the Settings
        // scene here only to satisfy the App protocol, and replace its
        // default Cmd+, command so the shortcut always routes to our
        // custom window instead of opening the empty SwiftUI scene.
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings...") {
                    NotificationCenter.default.post(name: .clydeOpenSettings, object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
