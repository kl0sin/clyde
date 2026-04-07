import XCTest
@testable import Clyde

final class SessionTests: XCTestCase {
    func testDisplayNameUsesCustomNameWhenSet() {
        var session = Session(pid: 123, workingDirectory: "/Users/me/Projects/shipyard")
        session.customName = "Backend"
        XCTAssertEqual(session.displayName, "Backend")
    }

    func testDisplayNameFallsBackToCWDBasename() {
        let session = Session(
            pid: 123,
            workingDirectory: "/Users/me/Projects/shipyard",
            sessionId: UUID().uuidString
        )
        XCTAssertEqual(session.displayName, "shipyard")
    }

    func testDisplayNameIgnoresEmptyCustomName() {
        var session = Session(
            pid: 123,
            workingDirectory: "/Users/me/Projects/shipyard",
            sessionId: UUID().uuidString
        )
        session.customName = ""
        XCTAssertEqual(session.displayName, "shipyard")
    }

    func testDisplayNameWithoutSessionIdShowsGenericLabel() {
        // pgrep-discovered sessions (no hook -info) don't have a trustworthy
        // cwd, so the display falls back to "Session <pid>".
        let session = Session(pid: 123, workingDirectory: "/Users/me/Projects/shipyard")
        XCTAssertEqual(session.displayName, "Session 123")
    }

    func testInitialStatusIsBusy() {
        let session = Session(pid: 456)
        XCTAssertEqual(session.status, .busy)
    }

    func testSessionsAreIdentifiable() {
        let a = Session(pid: 100)
        let b = Session(pid: 100)
        XCTAssertNotEqual(a.id, b.id)
    }
}
