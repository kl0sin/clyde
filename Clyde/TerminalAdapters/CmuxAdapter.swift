import Foundation
import AppKit

/// cmux is its own app built on libghostty, not Ghostty, so it needs its
/// own adapter. It exports `CMUX_SURFACE_ID` into every terminal, and its
/// AppleScript dictionary (Ghostty's shape) names terminals by that same
/// id — so the session's surface is focused directly. Its socket CLI is
/// not used: it admits only processes started inside cmux, by design.
struct CmuxAdapter: TerminalAdapter {
    let name = "cmux"
    let bundleIdentifier = "com.cmuxterm.app"

    func focusSession(parentPID: pid_t, claudePID: pid_t) async throws {
        guard isInstalled else { throw TerminalError.terminalNotInstalled }
        let environment = (try? await RealShellExecutor().run("ps -E -ww -o command= -p \(claudePID)")) ?? ""
        guard let surface = Self.surfaceID(inProcessEnvironment: environment) else {
            activateApp()
            return
        }
        do {
            try runAppleScript(focusScript(surfaceID: surface))
        } catch {
            activateApp()
        }
    }

    /// A UUID and nothing else: it lands inside the script. Last match,
    /// as for Warp — `ps -E` prints argv before the environment.
    static func surfaceID(inProcessEnvironment output: String) -> String? {
        output.matches(of: #/(?:^|\s)CMUX_SURFACE_ID=([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})(?=\s|$)/#)
            .last.map { String($0.1) }
    }

    func focusScript(surfaceID: String) -> String {
        """
            tell application id "\(bundleIdentifier)"
                activate
                repeat with t in terminals
                    if id of t is "\(surfaceID)" then
                        focus t
                        return
                    end if
                end repeat
            end tell
        """
    }
}
