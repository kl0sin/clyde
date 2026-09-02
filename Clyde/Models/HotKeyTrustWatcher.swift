import Foundation

/// Remembers whether the global shortcut's monitor was installed while
/// macOS trusted the app.
///
/// `NSEvent.addGlobalMonitorForEvents` binds its access at install time:
/// a monitor created before the accessibility grant keeps receiving
/// nothing afterwards, and the app looks broken with the permission
/// visibly switched on. Restarting fixed it, which is not an
/// instruction a user should have to discover.
struct HotKeyTrustWatcher {
    private var installedWhileTrusted = false

    mutating func recordInstall(trusted: Bool) {
        installedWhileTrusted = trusted
    }

    /// True when the monitor on hand cannot work but a new one could.
    func needsReinstall(trustedNow: Bool) -> Bool {
        trustedNow && !installedWhileTrusted
    }
}
