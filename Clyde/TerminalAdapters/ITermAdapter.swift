import Foundation

struct ITermAdapter: TerminalAdapter {
    let name = "iTerm2"
    let bundleIdentifier = "com.googlecode.iterm2"

    func openNewSession() async throws {
        guard isInstalled else { throw TerminalError.terminalNotInstalled }
        try runAppleScript("""
            tell application "iTerm2"
                activate
                tell current window
                    create tab with default profile
                    tell current session
                        write text "claude"
                    end tell
                end tell
            end tell
        """)
    }

    func focusSession(parentPID: pid_t) async throws {
        guard isInstalled else { throw TerminalError.terminalNotInstalled }
        try runAppleScript("""
            tell application "iTerm2"
                activate
                repeat with w in windows
                    tell w
                        repeat with t in tabs
                            tell t
                                repeat with s in sessions
                                    tell s
                                        if (variable named "session.pid") is \(parentPID) then
                                            select
                                        end if
                                    end tell
                                end repeat
                            end tell
                        end repeat
                    end tell
                end repeat
            end tell
        """)
    }
}
