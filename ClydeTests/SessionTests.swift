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

    func testDisplayNameWithoutSessionIdUsesCWDWhenMeaningful() {
        // A pgrep-discovered session with a proper project cwd still shows
        // the project name — even without a hook session_id.
        let session = Session(pid: 123, workingDirectory: "/Users/me/Projects/shipyard")
        XCTAssertEqual(session.displayName, "shipyard")
    }

    func testDisplayNameFallsBackToUntitledForHomeDirectoryCWD() {
        // The classic "lsof found only the global settings file" case:
        // cwd is the home directory, which tells us nothing about the
        // project. Fall back to the friendly generic label.
        let session = Session(pid: 123, workingDirectory: NSHomeDirectory())
        XCTAssertEqual(session.displayName, "Untitled session")
    }

    func testDisplayNameFallsBackToUntitledForEmptyCWD() {
        let session = Session(pid: 123, workingDirectory: "")
        XCTAssertEqual(session.displayName, "Untitled session")
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
