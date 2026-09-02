import XCTest
@testable import Clyde

/// When the global shortcut's monitor has to be installed again.
///
/// `NSEvent.addGlobalMonitorForEvents` is installed once, at launch, and
/// a monitor installed before macOS trusted the app keeps receiving
/// nothing after the trust arrives. That is the shape of the bug a user
/// reported from the released build: accessibility granted, shortcut
/// still dead, and only a restart fixed it.
final class HotKeyTrustTests: XCTestCase {

    func testAMonitorInstalledWithoutTrustIsReinstalledOnceTrustArrives() {
        var watcher = HotKeyTrustWatcher()
        watcher.recordInstall(trusted: false)

        XCTAssertTrue(watcher.needsReinstall(trustedNow: true))
    }

    func testAMonitorInstalledWithTrustIsLeftAlone() {
        var watcher = HotKeyTrustWatcher()
        watcher.recordInstall(trusted: true)

        XCTAssertFalse(watcher.needsReinstall(trustedNow: true))
    }

    func testNothingHappensWhileTrustIsStillMissing() {
        var watcher = HotKeyTrustWatcher()
        watcher.recordInstall(trusted: false)

        XCTAssertFalse(watcher.needsReinstall(trustedNow: false))
    }

    func testReinstallingHappensOnceRatherThanEveryCheck() {
        var watcher = HotKeyTrustWatcher()
        watcher.recordInstall(trusted: false)
        XCTAssertTrue(watcher.needsReinstall(trustedNow: true))

        // The re-install records itself, so the fifteen-second poll does
        // not tear the monitor down and rebuild it forever.
        watcher.recordInstall(trusted: true)

        XCTAssertFalse(watcher.needsReinstall(trustedNow: true))
    }

    func testTrustLostAgainIsNoticedSoTheNextGrantStillReinstalls() {
        var watcher = HotKeyTrustWatcher()
        watcher.recordInstall(trusted: true)

        // Revoking the permission leaves a monitor that is dead again;
        // the next grant has to rebuild it.
        XCTAssertFalse(watcher.needsReinstall(trustedNow: false))
        watcher.recordInstall(trusted: false)

        XCTAssertTrue(watcher.needsReinstall(trustedNow: true))
    }
}
