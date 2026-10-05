import Foundation

struct TerminalAppAdapter: TerminalAdapter {
    let name = "Terminal"
    let bundleIdentifier = "com.apple.Terminal"

    func focusSession(parentPID: pid_t, claudePID: pid_t) async throws {
        guard isInstalled else { throw TerminalError.terminalNotInstalled }

        guard let tty = await tty(of: parentPID) else { throw TerminalError.hostingTerminalNotFound }
        try runAppleScript(focusScript(tty: "/dev/\(tty)"))
    }

    /// See `ITermAdapter.focusScript` — the target is resolved by
    /// identifier so the script cannot disagree with `isInstalled`.
    func focusScript(tty: String) -> String {
        """
            tell application id "\(bundleIdentifier)"
                activate
                repeat with w in windows
                    repeat with t in tabs of w
                        try
                            if tty of t is "\(tty)" then
                                set selected tab of w to t
                                set index of w to 1
                                return
                            end if
                        end try
                    end repeat
                end repeat
            end tell
        """
    }
}
