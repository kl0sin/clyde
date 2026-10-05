import Foundation
import AppKit

/// Ghostty's AppleScript (1.3+) can focus a terminal, but exposes no pid
/// or tty to find it by, and every Claude session titles itself
/// "✳ Claude Code". So the session's tty gets a one-off title (OSC 2),
/// the terminal carrying it is focused, and its previous title is
/// written back. Sessions without a tty, a Ghostty too old to script,
/// or a refused Automation prompt fall back to activating the app.
struct GhosttyAdapter: TerminalAdapter {
    let name = "Ghostty"
    let bundleIdentifier = "com.mitchellh.ghostty"

    func focusSession(parentPID: pid_t, claudePID: pid_t) async throws {
        guard isInstalled else { throw TerminalError.terminalNotInstalled }
        guard let tty = await tty(of: claudePID) else {
            activateApp()
            return
        }
        do {
            try runAppleScript(focusScript(tty: "/dev/\(tty)", marker: "clyde-\(UUID().uuidString)"))
        } catch {
            activateApp()
        }
    }

    /// `do shell script` stays outside the `tell` blocks: inside one it
    /// would be sent to Ghostty as an Apple event and refused.
    func focusScript(tty: String, marker: String) -> String {
        """
            set marker to "\(marker)"
            tell application id "\(bundleIdentifier)"
                set termIDs to id of every terminal
                set termNames to name of every terminal
            end tell
            do shell script "printf '\\\\033]2;%s\\\\007' " & quoted form of marker & " > \(tty)"
            set focusedID to missing value
            repeat 20 times
                tell application id "\(bundleIdentifier)"
                    repeat with t in terminals
                        if name of t is marker then
                            set focusedID to id of t
                            activate
                            focus t
                            exit repeat
                        end if
                    end repeat
                end tell
                if focusedID is not missing value then exit repeat
                delay 0.05
            end repeat
            if focusedID is missing value then
                do shell script "printf '\\\\033]2;\\\\007' > \(tty)"
                tell application id "\(bundleIdentifier)" to activate
                return
            end if
            repeat with i from 1 to count of termIDs
                if item i of termIDs is focusedID then
                    do shell script "printf '\\\\033]2;%s\\\\007' " & quoted form of (item i of termNames) & " > \(tty)"
                end if
            end repeat
        """
    }
}
