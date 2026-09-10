import XCTest
@testable import Clyde

/// Where the app is running from, which decides whether a permission
/// granted to it can ever stick.
///
/// A user granted accessibility on a second machine, saw it listed as
/// granted, and the shortcut stayed dead until the row was removed by
/// hand. Every release since v0.5.0 carries the same designated
/// requirement, so an update cannot drop a TCC grant — but a *second
/// copy* at a second path is a second row, and a copy run straight from
/// a DMG or from Downloads is worse still: macOS translocates it to a
/// random read-only path, and the grant belongs to that path.
final class AppLocationTests: XCTestCase {

    override func tearDown() {
        // These are global switches; leaving one set makes an unrelated
        // test fail somewhere else entirely.
        AppLocation.override = nil
        HookInstaller.accessibilityTrustedOverride = nil
        UsageLimitsInstaller.offerOverride = nil
        super.tearDown()
    }

    func testACopyInApplicationsIsWhereItShouldBe() {
        XCTAssertEqual(AppLocation.classify(bundlePath: "/Applications/Clyde.app"),
                       .installed)
    }

    func testTranslocationIsRecognised() {
        // What macOS does to an app run straight from a downloaded DMG.
        let path = "/private/var/folders/xy/AppTranslocation/9F2A/d/Clyde.app"
        XCTAssertEqual(AppLocation.classify(bundlePath: path), .translocated)
    }

    func testRunningFromTheDiskImageIsRecognised() {
        XCTAssertEqual(AppLocation.classify(bundlePath: "/Volumes/Clyde 0.9.1/Clyde.app"),
                       .diskImage)
    }

    func testAnywhereElseIsJustElsewhere() {
        XCTAssertEqual(AppLocation.classify(bundlePath: "/Users/me/Downloads/Clyde.app"),
                       .elsewhere)
    }

    /// A user-level Applications folder is a real install, not a stray
    /// copy — plenty of people keep their apps there.
    func testTheUsersOwnApplicationsFolderCounts() {
        XCTAssertEqual(AppLocation.classify(bundlePath: "/Users/me/Applications/Clyde.app"),
                       .installed)
    }

    /// Only the installed case can hold a permission that survives.
    func testOnlyAnInstalledCopyCanKeepAPermission() {
        XCTAssertTrue(AppLocation.installed.canKeepPermissions)
        XCTAssertFalse(AppLocation.translocated.canKeepPermissions)
        XCTAssertFalse(AppLocation.diskImage.canKeepPermissions)
        XCTAssertFalse(AppLocation.elsewhere.canKeepPermissions)
    }

    // MARK: - What the health check makes of it

    /// Granting is futile from a copy that cannot hold the grant, so
    /// the advisory has to say that instead of pointing at a pane.
    func testAStrayCopyIsReportedInsteadOfTheUsualAdvice() throws {
        try HookInstaller.install()
        HookInstaller.accessibilityTrustedOverride = false
        AppLocation.override = .translocated

        XCTAssertEqual(HookInstaller.healthCheck(), .strayCopy(.translocated))
    }

    /// And an installed copy gets the ordinary advice, so the location
    /// is only ever mentioned when it is the actual obstacle.
    func testAnInstalledCopyGetsTheOrdinaryAdvice() throws {
        try HookInstaller.install()
        HookInstaller.accessibilityTrustedOverride = false
        AppLocation.override = .installed

        XCTAssertEqual(HookInstaller.healthCheck(), .accessibilityNotTrusted)
    }

    /// A copy in the wrong place with a working permission is left in
    /// peace — nothing is broken, so nothing is said.
    func testAWorkingPermissionIsNotLecturedAboutLocation() throws {
        UsageLimitsInstaller.offerOverride = false
        try HookInstaller.install()
        HookInstaller.accessibilityTrustedOverride = true
        AppLocation.override = .elsewhere

        XCTAssertNil(HookInstaller.healthCheck())
    }

    func testTheMessageSaysWhereToPutIt() {
        let message = HookInstaller.HealthIssue.strayCopy(.diskImage).bannerMessage
        XCTAssertTrue(message.contains("Applications"), message)
    }
}
