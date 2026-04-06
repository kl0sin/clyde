import Foundation

struct TerminalAppAdapter: TerminalAdapter {
    let name = "Terminal"
    let bundleIdentifier = "com.apple.Terminal"

    func focusSession(parentPID: pid_t) async throws {
        guard isInstalled else { throw TerminalError.terminalNotInstalled }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "ps -p \(parentPID) -o tty="]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let tty = (String(data: data, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !tty.isEmpty else { throw TerminalError.hostingTerminalNotFound }
        let fullTTY = tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"

        try runAppleScript("""
            tell application "Terminal"
                activate
                repeat with w in windows
                    repeat with t in tabs of w
                        try
                            if tty of t is "\(fullTTY)" then
                                set selected tab of w to t
                                set index of w to 1
                                return
                            end if
                        end try
                    end repeat
                end repeat
            end tell
        """)
    }
}
