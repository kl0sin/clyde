import Foundation
import Darwin

final class PseudoTerminal {
    let masterFD: Int32
    let childPID: pid_t

    private init(masterFD: Int32, childPID: pid_t) {
        self.masterFD = masterFD
        self.childPID = childPID
    }

    /// Spawn a shell process connected to a new PTY
    /// - Parameters:
    ///   - shell: Path to shell (default: /bin/zsh)
    ///   - cwd: Working directory for the shell
    ///   - command: Optional command to run after shell starts (e.g. "claude")
    static func spawn(
        shell: String = "/bin/zsh",
        cwd: String? = nil,
        command: String? = nil
    ) throws -> PseudoTerminal {
        var masterFD: Int32 = 0
        var winSize = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)

        let pid = forkpty(&masterFD, nil, nil, &winSize)

        if pid < 0 {
            throw PTYError.forkFailed(errno)
        }

        if pid == 0 {
            // Child process
            if let cwd = cwd {
                chdir(cwd)
            }

            // Set environment
            setenv("TERM", "xterm-256color", 1)
            setenv("LANG", "en_US.UTF-8", 1)

            if let command = command {
                // Run shell with command
                let args = [shell, "-l", "-c", command]
                let cArgs = args.map { strdup($0) } + [nil]
                execv(shell, cArgs)
            } else {
                // Interactive shell
                let args = [shell, "-l"]
                let cArgs = args.map { strdup($0) } + [nil]
                execv(shell, cArgs)
            }

            // If exec fails
            _exit(1)
        }

        // Parent process
        // Set non-blocking
        let flags = fcntl(masterFD, F_GETFL)
        _ = fcntl(masterFD, F_SETFL, flags | O_NONBLOCK)

        return PseudoTerminal(masterFD: masterFD, childPID: pid)
    }

    /// Read available data from the PTY
    func read() -> Data? {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let bytesRead = Darwin.read(masterFD, &buffer, buffer.count)
        if bytesRead > 0 {
            return Data(buffer[0..<bytesRead])
        }
        return nil
    }

    /// Write data to the PTY (user input)
    func write(_ data: Data) {
        data.withUnsafeBytes { ptr in
            if let baseAddress = ptr.baseAddress {
                Darwin.write(masterFD, baseAddress, data.count)
            }
        }
    }

    /// Write a string to the PTY
    func write(_ string: String) {
        if let data = string.data(using: .utf8) {
            write(data)
        }
    }

    /// Resize the terminal
    func resize(cols: UInt16, rows: UInt16) {
        var winSize = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(masterFD, TIOCSWINSZ, &winSize)
    }

    /// Check if the child process is still running
    var isRunning: Bool {
        var status: Int32 = 0
        let result = waitpid(childPID, &status, WNOHANG)
        return result == 0
    }

    deinit {
        close(masterFD)
        kill(childPID, SIGTERM)
    }
}

enum PTYError: Error {
    case forkFailed(Int32)
}
