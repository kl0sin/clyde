import Foundation
import AppKit

/// Ghostty has limited AppleScript — no API to enumerate or focus specific tabs.
/// focusSession only activates the app.
struct GhosttyAdapter: TerminalAdapter {
    let name = "Ghostty"
    let bundleIdentifier = "com.mitchellh.ghostty"

    func openNewSession() async throws {
        guard isInstalled else { throw TerminalError.terminalNotInstalled }
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)!
        let config = NSWorkspace.OpenConfiguration()
        try await NSWorkspace.shared.open(url, configuration: config)
        try await Task.sleep(for: .milliseconds(500))
        activateGhostty()
    }

    func focusSession(parentPID: pid_t) async throws {
        guard isInstalled else { throw TerminalError.terminalNotInstalled }
        activateGhostty()
    }

    private func activateGhostty() {
        let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        if let app = runningApps.first {
            app.activate(options: [.activateAllWindows])
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            NSWorkspace.shared.open(url)
        }
    }
}
