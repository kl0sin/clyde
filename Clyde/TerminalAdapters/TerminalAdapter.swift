import Foundation
import AppKit

protocol TerminalAdapter {
    var name: String { get }
    var bundleIdentifier: String { get }
    var isInstalled: Bool { get }
    func focusSession(parentPID: pid_t) async throws
}

extension TerminalAdapter {
    var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil
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

    func activateApp() {
        let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        if let app = runningApps.first {
            app.activate(options: [.activateAllWindows])
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
