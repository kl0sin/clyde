import Foundation
import AppKit

protocol TerminalAdapter {
    var name: String { get }
    var bundleIdentifier: String { get }
    var isInstalled: Bool { get }
    func openNewSession() async throws
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
}

enum TerminalError: Error {
    case scriptCreationFailed
    case scriptExecutionFailed(String)
    case terminalNotInstalled
}
