import XCTest
@testable import Clyde

/// The two grants ⌃⌘C needs, and how the app sends a user to them.
///
/// Input Monitoring has a trap that cost a user their afternoon: the
/// pane lists only applications that have *asked* for the permission.
/// Checking it — which is all Clyde did — registers nothing, so the
/// button opened a pane with no Clyde row in it and no way to add one.
final class ShortcutPermissionTests: XCTestCase {

    func testBothPermissionsAreOffered() {
        XCTAssertEqual(ShortcutPermission.allCases,
                       [.accessibility, .inputMonitoring])
    }

    func testEachOneOpensItsOwnPane() {
        XCTAssertEqual(ShortcutPermission.accessibility.settingsURL?.absoluteString,
                       "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        XCTAssertEqual(ShortcutPermission.inputMonitoring.settingsURL?.absoluteString,
                       "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
    }

    func testInputMonitoringAsksBeforeSendingTheUserToThePane() {
        var events: [String] = []

        ShortcutPermission.inputMonitoring.reveal(
            request: { events.append("request") },
            open: { _ in events.append("open") })

        // Order is the whole point: opening first shows a pane that does
        // not list Clyde, and the user has nothing to click.
        XCTAssertEqual(events, ["request", "open"])
    }

    func testAccessibilityDoesNotNeedAsking() {
        // Its pane lets a user add an application that never asked, and
        // Clyde is registered there the moment it queries trust — so a
        // prompt here would be a modal with nothing behind it.
        var events: [String] = []

        ShortcutPermission.accessibility.reveal(
            request: { events.append("request") },
            open: { _ in events.append("open") })

        XCTAssertEqual(events, ["open"])
    }

    func testTheUrlHandedToTheOpenerIsThePermissionsOwn() {
        var opened: URL?

        ShortcutPermission.inputMonitoring.reveal(request: {}, open: { opened = $0 })

        XCTAssertEqual(opened, ShortcutPermission.inputMonitoring.settingsURL)
    }
}
