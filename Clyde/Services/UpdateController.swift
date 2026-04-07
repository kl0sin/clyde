import Foundation
import Sparkle
import AppKit

/// Thin wrapper around `SPUStandardUpdaterController` so the rest of the
/// app doesn't have to import Sparkle directly. Holds the standard
/// updater configured to read its feed URL + EdDSA public key from
/// `Info.plist` (`SUFeedURL` and `SUPublicEDKey`).
@MainActor
final class UpdateController: NSObject {
    static let shared = UpdateController()

    private let updaterController: SPUStandardUpdaterController

    override init() {
        // `startingUpdater: true` lets Sparkle do its scheduled background
        // check immediately. `updaterDelegate` and `userDriverDelegate` are
        // both nil — the standard built-in driver covers everything we
        // need (modal "Update available" sheet, in-place install on quit).
        self.updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        super.init()
    }

    /// Trigger a user-initiated check. Bound to the menu bar item and the
    /// Settings button. Sparkle handles all UI from here on.
    @objc func checkForUpdates(_ sender: Any?) {
        updaterController.checkForUpdates(sender)
    }

    /// Whether the user can currently trigger a check (Sparkle disables
    /// the action while one is already in flight).
    var canCheckForUpdates: Bool {
        updaterController.updater.canCheckForUpdates
    }
}
