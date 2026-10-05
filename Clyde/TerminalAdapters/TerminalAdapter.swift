import Foundation
import AppKit

protocol TerminalAdapter {
    var name: String { get }
    var bundleIdentifier: String { get }
    /// Every identifier this terminal ships under, primary first. Warp
    /// has a separate one for its Preview channel, and an app the user
    /// runs is no less installed for being the beta.
    var bundleIdentifiers: [String] { get }
    var isInstalled: Bool { get }
    func focusSession(parentPID: pid_t, claudePID: pid_t) async throws
}

extension TerminalAdapter {
    var bundleIdentifiers: [String] { [bundleIdentifier] }

    var isInstalled: Bool {
        bundleIdentifiers.contains {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil
        }
    }

    func runAppleScript(_ source: String) throws {
        guard let script = NSAppleScript(source: source) else {
            throw TerminalError.scriptCreationFailed
        }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        if let error {
            throw TerminalError.scriptExecutionFailed(error.description)
        }
    }

    /// The controlling terminal of `pid` as `ps` names it (`ttys023`),
    /// or nil for a process without one (`??`). The name ends up inside
    /// scripts, so nothing but a tty name gets through.
    func tty(of pid: pid_t) async -> String? {
        let name = (try? await RealShellExecutor().run("ps -o tty= -p \(pid)")) ?? ""
        return name.wholeMatch(of: #/ttys?[0-9]+/#) != nil ? name : nil
    }

    func activateApp() {
        for identifier in bundleIdentifiers {
            let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            if let app = runningApps.first {
                app.activate(options: [.activateAllWindows])
                return
            }
        }
    }
}

enum TerminalError: LocalizedError {
    case scriptCreationFailed
    case scriptExecutionFailed(String)
    case terminalNotInstalled
    case hostingTerminalNotFound

    var errorDescription: String? {
        switch self {
        case .scriptCreationFailed: return "Failed to create AppleScript"
        case .scriptExecutionFailed(let msg): return "AppleScript error: \(msg)"
        case .terminalNotInstalled: return "Terminal application is not installed"
        case .hostingTerminalNotFound: return "Could not identify terminal hosting this session"
        }
    }
}
