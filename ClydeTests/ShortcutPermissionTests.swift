import XCTest
@testable import Clyde

/// The grant ⌃⌘C needs, and how the app sends a user to it.
///
/// The pane lists only applications that have *asked* for the
/// permission. Checking it — which is all Clyde did — registers
/// nothing, so a user whose row was missing or stale found a pane with
/// no Clyde in it and no way to add one.
final class ShortcutPermissionTests: XCTestCase {

    func testAccessibilityIsTheOnlyGrantTheShortcutNeeds() {
        XCTAssertEqual(ShortcutPermission.allCases, [.accessibility])
    }

    func testItOpensItsOwnPane() {
        XCTAssertEqual(ShortcutPermission.accessibility.settingsURL?.absoluteString,
                       "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    func testAccessibilityAsksTooRatherThanAssumingTheRowExists() {
        // Believed for a while that this pane lists an application that
        // never asked. It does not: a user who removes Clyde's row, or
        // whose row is stale, finds nothing to switch on and gets no
        // prompt offering to put one back.
        var events: [String] = []

        ShortcutPermission.accessibility.reveal(
            request: { events.append("request") },
            open: { _ in events.append("open") })

        XCTAssertEqual(events, ["request", "open"])
    }

    func testTheUrlHandedToTheOpenerIsThePermissionsOwn() {
        var opened: URL?

        ShortcutPermission.accessibility.reveal(request: {}, open: { opened = $0 })

        XCTAssertEqual(opened, ShortcutPermission.accessibility.settingsURL)
    }
}
