import Foundation
import AppKit

/// Warp has no AppleScript, but since May 2026 it exports
/// `WARP_FOCUS_URL=warp://session/<uuid>` into every shell it starts,
/// and opening that URL focuses the exact window, tab and pane. The
/// variable is set during shell bootstrap rather than at exec, so it is
/// in claude's environment but not the login shell's — read it there.
/// Older Warp builds without it fall back to activating the app.
struct WarpAdapter: TerminalAdapter {
    let name = "Warp"
    let bundleIdentifier = "dev.warp.Warp-Stable"
    let bundleIdentifiers = ["dev.warp.Warp-Stable", "dev.warp.Warp-Preview"]

    func focusSession(parentPID: pid_t, claudePID: pid_t) async throws {
        guard isInstalled else { throw TerminalError.terminalNotInstalled }
        guard let value = await environmentValue("WARP_FOCUS_URL", of: claudePID),
              let url = Self.focusURL(value),
              NSWorkspace.shared.open(url) else {
            activateApp()
            return
        }
    }

    /// Only a Warp session link is accepted — the value comes from
    /// another process's environment, and anything else in it is not
    /// something Clyde should be opening.
    static func focusURL(_ value: String) -> URL? {
        guard value.wholeMatch(of: #/warp[a-z]*://session/[0-9a-fA-F]+/#) != nil else { return nil }
        return URL(string: value)
    }
}
