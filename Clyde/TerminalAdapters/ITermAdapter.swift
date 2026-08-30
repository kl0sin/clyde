import Foundation

struct ITermAdapter: TerminalAdapter {
    let name = "iTerm2"
    let bundleIdentifier = "com.googlecode.iterm2"

    func focusSession(parentPID: pid_t) async throws {
        guard isInstalled else { throw TerminalError.terminalNotInstalled }
        try runAppleScript(focusScript(parentPID: parentPID))
    }

    /// `tell application id` resolves the target through LaunchServices
    /// rather than the app's scripting name, which is what `isInstalled`
    /// two lines up has always done. The name form fails with
    /// NSAppleScriptErrorAppName whenever that lookup comes back empty.
    func focusScript(parentPID: pid_t) -> String {
        """
            tell application id "\(bundleIdentifier)"
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
        """
    }
}
