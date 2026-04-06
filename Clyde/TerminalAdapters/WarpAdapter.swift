import Foundation
import AppKit

/// Warp has very limited AppleScript support — no API to enumerate or focus
/// specific tabs. focusSession only activates the Warp app (bringing whichever
/// window was last active to the front). User may need to switch tabs manually.
struct WarpAdapter: TerminalAdapter {
    let name = "Warp"
    let bundleIdentifier = "dev.warp.Warp-Stable"

    func openNewSession() async throws {
        guard isInstalled else { throw TerminalError.terminalNotInstalled }
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)!
        let config = NSWorkspace.OpenConfiguration()
        config.arguments = []
        try await NSWorkspace.shared.open(url, configuration: config)
        try await Task.sleep(for: .milliseconds(800))
        activateWarp()
    }

    func focusSession(parentPID: pid_t) async throws {
        guard isInstalled else { throw TerminalError.terminalNotInstalled }
        activateWarp()
    }

    private func activateWarp() {
        // Activate via NSRunningApplication — no AppleScript authorization needed
        let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        if let app = runningApps.first {
            app.activate(options: [.activateAllWindows])
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            NSWorkspace.shared.open(url)
        }
    }
}
