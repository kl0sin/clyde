import Foundation

/// An editor's integrated terminal — VS Code and its forks. None of them
/// expose terminals to other apps (that would take an editor extension),
/// so the session's editor is brought forward and the tab is left to the
/// user. One instance per app, so a click activates the editor the
/// session runs in rather than whichever of them happens to be open.
struct EditorAdapter: TerminalAdapter {
    let name: String
    let bundleIdentifier: String

    static let vsCode = EditorAdapter(name: "VS Code", bundleIdentifier: "com.microsoft.VSCode")
    static let vsCodeInsiders = EditorAdapter(name: "VS Code Insiders", bundleIdentifier: "com.microsoft.VSCodeInsiders")
    static let cursor = EditorAdapter(name: "Cursor", bundleIdentifier: "com.todesktop.230313mzl4w4u92")

    func focusSession(parentPID: pid_t, claudePID: pid_t) async throws {
        guard isInstalled else { throw TerminalError.terminalNotInstalled }
        activateApp()
    }
}
