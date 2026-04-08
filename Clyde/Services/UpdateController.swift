import Foundation
import Sparkle
import AppKit

/// Thin wrapper around `SPUStandardUpdaterController` so the rest of the
/// app doesn't have to import Sparkle directly. Holds the standard
/// updater configured to read its feed URL + EdDSA public key from
/// `Info.plist` (`SUFeedURL` and `SUPublicEDKey`).
///
/// Sparkle requires a proper `.app` bundle with `Sparkle.framework` in
/// `Contents/Frameworks/`. When running via `swift run Clyde` (development)
/// there's no bundle and Sparkle's XPC bring-up hangs the main thread,
/// freezing the entire UI. We detect that case and disable Sparkle
/// gracefully — menu items still appear but the action is a no-op.
@MainActor
final class UpdateController: NSObject {
    static let shared = UpdateController()

    private let updaterController: SPUStandardUpdaterController?

    /// True only when we're running from a real `.app` bundle and Sparkle
    /// could be safely instantiated.
    let isAvailable: Bool

    override init() {
        // Heuristic: a real bundled app has its executable inside
        // `<Something>.app/Contents/MacOS/`. `swift run` puts the binary
        // in `.build/.../debug/Clyde` instead. Skip Sparkle in the
        // development path so the UI doesn't lock up.
        let bundlePath = Bundle.main.bundlePath
        if bundlePath.hasSuffix(".app") {
            self.isAvailable = true
            self.updaterController = SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: nil,
                userDriverDelegate: nil
            )
        } else {
            self.isAvailable = false
            self.updaterController = nil
            ClydeLog.general.info("Sparkle disabled — not running from a .app bundle (development build)")
        }
        super.init()
    }

    /// Trigger a user-initiated check. Bound to the menu bar item and the
    /// Settings button. Sparkle handles all UI from here on.
    @objc func checkForUpdates(_ sender: Any?) {
        guard let updaterController else {
            ClydeLog.general.info("Update check requested but Sparkle is unavailable in this build")
            return
        }
        updaterController.checkForUpdates(sender)
    }

    /// Whether the user can currently trigger a check (Sparkle disables
    /// the action while one is already in flight).
    var canCheckForUpdates: Bool {
        updaterController?.updater.canCheckForUpdates ?? false
    }
}
