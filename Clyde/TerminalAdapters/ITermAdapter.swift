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
        // Walk iTerm2's windows/tabs/sessions, matching session.pid to shell PID.
        // When found: select the session, tab, window + activate iTerm2.
        try runAppleScript("""
            tell application "iTerm2"
                activate
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            try
                                set sessPID to (variable named "session.pid") of s as integer
                                if sessPID is \(parentPID) then
                                    select s
                                    tell t to select
                                    tell w to select
                                    return
                                end if
                            end try
                        end repeat
                    end repeat
                end repeat
            end tell
        """)
    }
}
