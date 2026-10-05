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
        let environment = (try? await RealShellExecutor().run("ps -E -ww -o command= -p \(claudePID)")) ?? ""
        guard let url = Self.focusURL(inProcessEnvironment: environment),
              NSWorkspace.shared.open(url) else {
            activateApp()
            return
        }
    }

    /// Only a Warp session link is accepted — the value comes from
    /// another process's environment, and anything else in it is not
    /// something Clyde should be opening. `ps -E` prints argv before the
    /// environment, so the last whole-word match is the variable itself
    /// rather than the same text inside an argument.
    static func focusURL(inProcessEnvironment output: String) -> URL? {
        guard let match = output.matches(of: #/(?:^|\s)WARP_FOCUS_URL=(warp[a-z]*://session/[0-9a-fA-F]+)(?=\s|$)/#).last else {
            return nil
        }
        return URL(string: String(match.1))
    }
}
