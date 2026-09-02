import Foundation
import AppKit
import ApplicationServices
import IOKit.hid

/// The two grants the global ⌃⌘C shortcut needs, and how to send the
/// user to each one.
///
/// Input Monitoring's pane lists only applications that have asked for
/// the permission. `IOHIDCheckAccess`, which is how Clyde reads the
/// state, is a query and registers nothing — so a user who had removed
/// Clyde's entry found the button opening a pane with no Clyde row and
/// no way to create one. Asking first is what puts it there.
enum ShortcutPermission: CaseIterable, Equatable {
    case accessibility
    case inputMonitoring

    var title: String {
        switch self {
        case .accessibility:   return "Accessibility"
        case .inputMonitoring: return "Input Monitoring"
        }
    }

    var settingsURL: URL? {
        switch self {
        case .accessibility:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        case .inputMonitoring:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
        }
    }

    var isGranted: Bool {
        switch self {
        case .accessibility:   return HookInstaller.isAccessibilityTrusted()
        case .inputMonitoring: return HookInstaller.isInputMonitoringTrusted()
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
        // Ask before opening, for both. Neither pane creates a row on
        // its own: the row exists because the application asked, and a
        // user sent to a list that does not contain Clyde has nothing
        // to switch on.
        (request ?? requestAccess)()
        open(settingsURL)
    }

    /// Ask macOS for this permission, prompt and all.
    func requestAccess() {
        switch self {
        case .accessibility:   Self.requestAccessibility()
        case .inputMonitoring: Self.requestInputMonitoring()
        }
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

    /// Registers Clyde with TCC for listening to keys, which is what
    /// makes the row appear in System Settings. Returns immediately;
    /// macOS shows its own prompt when it decides to.
    @discardableResult
    static func requestInputMonitoring() -> Bool {
        let before = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        let granted = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        let after = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        // Logged because the failure this exists to fix is invisible:
        // the call returns, nothing prompts, and no row appears. The
        // three values together say which of those happened.
        ClydeLog.ui.info("""
            Input monitoring request: before=\(before.rawValue) \
            granted=\(granted) after=\(after.rawValue)
            """)
        return granted
    }
}
