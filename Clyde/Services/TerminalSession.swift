import Foundation
import Combine

@MainActor
final class TerminalSession: ObservableObject, Identifiable {
    let id = UUID()
    let pty: PseudoTerminal

    @Published var outputText: String = ""
    @Published var isRunning: Bool = true
    @Published var title: String

    private var readTask: Task<Void, Never>?
    private let maxOutputLength = 50_000 // Trim output to prevent memory bloat

    init(pty: PseudoTerminal, title: String = "Terminal") {
        self.pty = pty
        self.title = title
        startReading()
    }

    private func startReading() {
        let pty = self.pty
        readTask = Task.detached { [weak self] in
            while !Task.isCancelled {
                guard let self = self else { break }

                if let data = pty.read(),
                   let text = String(data: data, encoding: .utf8) {
                    await MainActor.run {
                        self.appendOutput(text)
                    }
                }

                // Check if process ended
                if !pty.isRunning {
                    await MainActor.run {
                        self.isRunning = false
                    }
                    break
                }

                try? await Task.sleep(for: .milliseconds(16)) // ~60fps read rate
            }
        }
    }

    private func appendOutput(_ text: String) {
        outputText += text
        // Trim if too long — keep the tail
        if outputText.count > maxOutputLength {
            let startIndex = outputText.index(outputText.endIndex, offsetBy: -maxOutputLength)
            outputText = String(outputText[startIndex...])
        }
    }

    func sendInput(_ string: String) {
        pty.write(string)
    }

    func sendKey(_ key: UInt8) {
        let data = Data([key])
        pty.write(data)
    }

    func resize(cols: UInt16, rows: UInt16) {
        pty.resize(cols: cols, rows: rows)
    }

    func terminate() {
        readTask?.cancel()
        // PTY deinit handles kill + close
    }

    deinit {
        readTask?.cancel()
    }

    /// Create a new terminal session with a shell
    static func createShell(cwd: String? = nil) throws -> TerminalSession {
        let pty = try PseudoTerminal.spawn(cwd: cwd)
        let dirName = cwd.map { ($0 as NSString).lastPathComponent } ?? "Terminal"
        return TerminalSession(pty: pty, title: dirName)
    }

    /// Create a new terminal session running claude
    static func createClaude(cwd: String? = nil) throws -> TerminalSession {
        let pty = try PseudoTerminal.spawn(cwd: cwd, command: "claude")
        let dirName = cwd.map { ($0 as NSString).lastPathComponent } ?? "claude"
        return TerminalSession(pty: pty, title: dirName)
    }
}
