import Foundation
import AppKit

struct WarpAdapter: TerminalAdapter {
    let name = "Warp"
    let bundleIdentifier = "dev.warp.Warp-Stable"

    func openNewSession() async throws {
        guard isInstalled else { throw TerminalError.terminalNotInstalled }
        // Open Warp and run claude via shell command — no Accessibility permission needed
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)!
        let config = NSWorkspace.OpenConfiguration()
        config.arguments = []
        try await NSWorkspace.shared.open(url, configuration: config)
        // Give Warp time to open, then use AppleScript to type
        try await Task.sleep(for: .milliseconds(800))
        try runAppleScript("""
            tell application "Warp" to activate
        """)
    }

    func focusSession(parentPID: pid_t) async throws {
        guard isInstalled else { throw TerminalError.terminalNotInstalled }
        try runAppleScript("""
            tell application "Warp" to activate
        """)
    }
}
