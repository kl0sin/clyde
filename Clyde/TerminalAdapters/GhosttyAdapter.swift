import Foundation

struct GhosttyAdapter: TerminalAdapter {
    let name = "Ghostty"
    let bundleIdentifier = "com.mitchellh.ghostty"

    func openNewSession() async throws {
        guard isInstalled else { throw TerminalError.terminalNotInstalled }
        try runAppleScript("""
            tell application "Ghostty"
                activate
            end tell
            delay 0.3
            tell application "System Events"
                tell process "Ghostty"
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
            tell application "Ghostty"
                activate
            end tell
        """)
    }
}
