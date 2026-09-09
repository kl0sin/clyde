import Foundation
import AppKit
import ApplicationServices

/// The grant the global ⌃⌘C shortcut needs, and how to send the user
/// to it.
///
/// The pane lists only applications that have asked for the permission,
/// and checking trust — which is all Clyde used to do — registers
/// nothing. A user whose row was missing or stale opened the pane to
/// find no Clyde in it and no way to add one. Asking is what puts it
/// there.
///
/// Input monitoring lived here too for a while, on the evidence of two
/// machines where accessibility was trusted and the shortcut was dead.
/// The real cause was a monitor that is never rebuilt after the grant;
/// with that fixed, ⌃⌘C fires with input monitoring explicitly denied.
enum ShortcutPermission: CaseIterable, Equatable {
    case accessibility

    var title: String {
        switch self {
        case .accessibility: return "Accessibility"
        }
    }

    var settingsURL: URL? {
        switch self {
        case .accessibility:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        }
    }

    var isGranted: Bool {
        switch self {
        case .accessibility: return HookInstaller.isAccessibilityTrusted()
        }
    }

    /// Put the permission where the user can grant it.
    ///
    /// Injectable so the order — ask, then open — is covered by a test
    /// rather than by having read the code.
    func reveal(request: (() -> Void)? = nil,
                open: (URL?) -> Void = { url in
                    if let url { NSWorkspace.shared.open(url) }
                }) {
        // Ask once. The pane does not create a row on its own — the
        // row exists because the application asked — but asking again
        // puts a second system modal on screen, behind the System
        // Settings window the first one just opened. From the user's
        // side the button then does nothing at all.
        if !Self.hasAsked {
            Self.hasAsked = true
            (request ?? requestAccess)()
        }
        open(settingsURL)
    }

    /// Whether the system prompt has been put up in this run.
    nonisolated(unsafe) private static var hasAsked = false

    /// Marks the prompt as asked for, so the launch path and the button
    /// do not both raise one.
    static func noteAsked() { hasAsked = true }

    static func resetAskedForTests() { hasAsked = false }

    /// Ask macOS for this permission, prompt and all.
    func requestAccess() {
        Self.requestAccessibility()
    }

    /// Asks macOS for accessibility, with its prompt.
    ///
    /// Nothing else in Clyde ever asked. Checking trust does not create
    /// the row in System Settings, so a user whose entry is missing or
    /// stale had nothing to switch on — and no prompt ever offered to
    /// put one there. Returns the trust state as it stands.
    @discardableResult
    static func requestAccessibility() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        let trusted = AXIsProcessTrustedWithOptions(options as CFDictionary)
        ClydeLog.ui.info("Accessibility request: trusted=\(trusted)")
        return trusted
    }
}
