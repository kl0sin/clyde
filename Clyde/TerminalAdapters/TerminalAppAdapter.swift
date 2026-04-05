import Foundation

struct TerminalAppAdapter: TerminalAdapter {
    let name = "Terminal"
    let bundleIdentifier = "com.apple.Terminal"

    func openNewSession() async throws {
        guard isInstalled else { throw TerminalError.terminalNotInstalled }
        try runAppleScript("""
            tell application "Terminal"
                activate
                do script "claude"
            end tell
        """)
    }

    func focusSession(parentPID: pid_t) async throws {
        guard isInstalled else { throw TerminalError.terminalNotInstalled }
        try runAppleScript("""
            tell application "Terminal"
                activate
                repeat with w in windows
                    repeat with t in tabs of w
                        if processes of t contains "\(parentPID)" then
                            set selected tab of w to t
                            set index of w to 1
                        end if
                    end repeat
                end repeat
            end tell
        """)
    }
}
