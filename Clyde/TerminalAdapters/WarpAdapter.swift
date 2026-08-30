import Foundation
import AppKit

/// Warp has limited AppleScript support — no API to enumerate or focus
/// specific tabs. focusSession only brings the Warp app to front.
struct WarpAdapter: TerminalAdapter {
    let name = "Warp"
    let bundleIdentifier = "dev.warp.Warp-Stable"
    let bundleIdentifiers = ["dev.warp.Warp-Stable", "dev.warp.Warp-Preview"]

    func focusSession(parentPID: pid_t) async throws {
        guard isInstalled else { throw TerminalError.terminalNotInstalled }
        activateApp()
    }
}
