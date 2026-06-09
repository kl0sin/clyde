import Foundation
import ServiceManagement

/// Abstraction over the slice of `SMAppService` that
/// `LoginItemService` touches, so tests can substitute a mock —
/// the real thing talks to launchd and can't be exercised in CI.
protocol LoginItemBackend {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

extension SMAppService: LoginItemBackend {}

/// Thin wrapper around `SMAppService.mainApp` — the macOS 13+ API
/// for registering an app as a login item. We use SMAppService
/// directly (no fallback to the deprecated `SMLoginItemSetEnabled`
/// path) because Clyde's deployment target is already macOS 13+.
///
/// The system tracks the registration state itself — no
/// UserDefaults storage needed. The UI binds to `isEnabled` and
/// reads it fresh on every appearance.
enum LoginItemService {
    /// Override for tests so we don't register the test runner as a
    /// real login item. `nil` means "use `SMAppService.mainApp`".
    nonisolated(unsafe) static var backendOverride: LoginItemBackend?

    private static var backend: LoginItemBackend {
        backendOverride ?? SMAppService.mainApp
    }

    /// True iff Clyde is currently registered to launch at login.
    /// SMAppService can also report `.requiresApproval` (the user
    /// needs to approve in System Settings → General → Login Items)
    /// — we treat that as "not enabled" from a binding perspective,
    /// since the toggle won't actually launch us yet, and surface
    /// the approval-needed state separately via `currentStatus`.
    static var isEnabled: Bool {
        backend.status == .enabled
    }

    /// Raw status for the UI to differentiate `.requiresApproval`
    /// from `.notRegistered` — we want to show the user an "open
    /// Login Items in System Settings" hint when approval is
    /// pending instead of pretending the toggle is just off.
    static var currentStatus: SMAppService.Status {
        backend.status
    }

    /// Register or unregister Clyde as a login item. Throws on
    /// SMAppService failures (e.g. unsigned dev build that the
    /// system refuses to register). The caller is expected to
    /// surface the error in the UI rather than silently swallow it.
    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try backend.register()
        } else {
            try backend.unregister()
        }
    }

    /// Opens the macOS Login Items pane in System Settings. Used
    /// when SMAppService reports `.requiresApproval` — the user has
    /// to flip the switch there themselves the first time.
    static func openSystemLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
