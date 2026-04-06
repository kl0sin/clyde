import Foundation
import AppKit

/// Ghostty has limited AppleScript — no API to enumerate or focus specific tabs.
/// focusSession only activates the app.
struct GhosttyAdapter: TerminalAdapter {
    let name = "Ghostty"
    let bundleIdentifier = "com.mitchellh.ghostty"

    func focusSession(parentPID: pid_t) async throws {
        guard isInstalled else { throw TerminalError.terminalNotInstalled }
        activateApp()
    }
}
