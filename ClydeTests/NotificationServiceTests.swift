import XCTest
@testable import Clyde

@MainActor
final class NotificationServiceTests: XCTestCase {
    func testNotificationContentForSession() {
        let service = NotificationService()
        var session = Session(pid: 123, workingDirectory: "/Users/me/Projects/shipyard")
        session.customName = "Shipyard"

        let content = service.buildNotificationContent(for: session)
        XCTAssertEqual(content.title, "Clyde")
        XCTAssertEqual(content.body, "Shipyard is ready")
    }

    func testNotificationContentUsesCWDWhenNoCustomName() {
        let service = NotificationService()
        let session = Session(pid: 123, workingDirectory: "/Users/me/Projects/tally-up")

        let content = service.buildNotificationContent(for: session)
        XCTAssertEqual(content.body, "tally-up is ready")
    }
}
