import Foundation
import AppKit
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
    func reveal(request: () -> Void = { ShortcutPermission.requestInputMonitoring() },
                open: (URL?) -> Void = { url in
                    if let url { NSWorkspace.shared.open(url) }
                }) {
        // Accessibility's pane accepts an application that never asked,
        // and querying trust is enough to list Clyde there. A prompt
        // would be a second modal in front of the pane we are opening.
        if self == .inputMonitoring { request() }
        open(settingsURL)
    }

    /// Registers Clyde with TCC for listening to keys, which is what
    /// makes the row appear in System Settings. Returns immediately;
    /// macOS shows its own prompt when it decides to.
    @discardableResult
    static func requestInputMonitoring() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }
}
