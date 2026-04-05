import Foundation

struct WarpAdapter: TerminalAdapter {
    let name = "Warp"
    let bundleIdentifier = "dev.warp.Warp-Stable"

    func openNewSession() async throws {
        guard isInstalled else { throw TerminalError.terminalNotInstalled }
        try runAppleScript("""
            tell application "Warp"
                activate
            end tell
            delay 0.5
            tell application "System Events"
                tell process "Warp"
                    keystroke "t" using command down
                    delay 0.3
                    keystroke "claude"
                    keystroke return
                end tell
            end tell
        """)
    }

    func focusSession(parentPID: pid_t) async throws {
        guard isInstalled else { throw TerminalError.terminalNotInstalled }
        try runAppleScript("""
            tell application "Warp"
                activate
            end tell
        """)
    }
}
