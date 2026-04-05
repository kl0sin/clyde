import Foundation
import Combine

@MainActor
final class TerminalSession: ObservableObject, Identifiable {
    let id = UUID()
    let pty: PseudoTerminal

    @Published var outputText: String = ""
    @Published var isRunning: Bool = true
    @Published var title: String

    private var readSource: DispatchSourceRead?
    private let maxOutputLength = 100_000

    init(pty: PseudoTerminal, title: String = "Terminal") {
        self.pty = pty
        self.title = title
        startReading()
    }

    private func startReading() {
        // Use GCD dispatch source for efficient PTY reading
        let source = DispatchSource.makeReadSource(
            fileDescriptor: pty.masterFD,
            queue: DispatchQueue.global(qos: .userInteractive)
        )

        source.setEventHandler { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 8192)
            let bytesRead = Darwin.read(self.pty.masterFD, &buffer, buffer.count)
            if bytesRead > 0 {
                let data = Data(buffer[0..<bytesRead])
                if let text = String(data: data, encoding: .utf8) {
                    DispatchQueue.main.async {
                        self.appendOutput(text)
                    }
                }
            } else if bytesRead == 0 {
                // EOF — process ended
                DispatchQueue.main.async {
                    self.isRunning = false
                }
                source.cancel()
            }
        }

        source.setCancelHandler { [weak self] in
            DispatchQueue.main.async {
                self?.isRunning = false
            }
        }

        // Need to set FD back to blocking for dispatch source
        let flags = fcntl(pty.masterFD, F_GETFL)
        _ = fcntl(pty.masterFD, F_SETFL, flags & ~O_NONBLOCK)

        source.resume()
        readSource = source
    }

    private func appendOutput(_ text: String) {
        outputText += text
        if outputText.count > maxOutputLength {
            let startIndex = outputText.index(outputText.endIndex, offsetBy: -maxOutputLength)
            outputText = String(outputText[startIndex...])
        }
    }

    func sendInput(_ string: String) {
        pty.write(string)
    }

    func sendKey(_ key: UInt8) {
        pty.write(Data([key]))
    }

    func resize(cols: UInt16, rows: UInt16) {
        pty.resize(cols: cols, rows: rows)
    }

    func terminate() {
        readSource?.cancel()
        readSource = nil
    }

    deinit {
        readSource?.cancel()
    }

    static func createShell(cwd: String? = nil) throws -> TerminalSession {
        let pty = try PseudoTerminal.spawn(cwd: cwd)
        let dirName = cwd.map { ($0 as NSString).lastPathComponent } ?? "Terminal"
        return TerminalSession(pty: pty, title: dirName)
    }

    static func createClaude(cwd: String? = nil) throws -> TerminalSession {
        let pty = try PseudoTerminal.spawn(cwd: cwd, command: "claude")
        let dirName = cwd.map { ($0 as NSString).lastPathComponent } ?? "claude"
        return TerminalSession(pty: pty, title: dirName)
    }
}
