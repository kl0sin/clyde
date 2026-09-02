import XCTest
@testable import Clyde

/// What the settings screen says about answering permission requests.
///
/// The switch alone cannot tell the user whether the feature works.
/// Turned on, a Clyde whose hook is broken and a Clyde nobody has asked
/// anything look identical — and the difference matters, because one
/// needs fixing and the other needs no attention at all.
final class PermissionAnsweringStatusTests: XCTestCase {

    func testOffSaysWhereTheQuestionsGoInstead() {
        let status = PermissionAnsweringStatus.resolve(enabled: false,
                                                       hookIssue: nil,
                                                       lastSeen: Date())
        XCTAssertEqual(status, .off)
        XCTAssertTrue(status.message.contains("terminal"))
    }

    func testOffStaysOffEvenWhenTheHookIsBroken() {
        // Nothing is broken from the user's point of view: they turned
        // it off, and a hook problem they are not relying on is noise.
        let status = PermissionAnsweringStatus.resolve(enabled: false,
                                                       hookIssue: .notInstalled,
                                                       lastSeen: nil)
        XCTAssertEqual(status, .off)
    }

    func testABrokenHookIsReportedRatherThanLookingQuiet() {
        let status = PermissionAnsweringStatus.resolve(enabled: true,
                                                       hookIssue: .notInstalled,
                                                       lastSeen: Date())
        XCTAssertEqual(status, .blocked)
    }

    func testOnButNothingHasEverArrivedIsItsOwnState() {
        let status = PermissionAnsweringStatus.resolve(enabled: true,
                                                       hookIssue: nil,
                                                       lastSeen: nil)
        XCTAssertEqual(status, .waiting)
        // The likeliest cause is a session that never asks, so the line
        // has to name what makes Claude ask.
        XCTAssertTrue(status.message.contains("permission-mode"))
    }

    func testAQuestionHavingArrivedIsTheOnlyProofItWorks() throws {
        let arrived = Date().addingTimeInterval(-90)
        let status = PermissionAnsweringStatus.resolve(enabled: true,
                                                       hookIssue: nil,
                                                       lastSeen: arrived)
        XCTAssertEqual(status, .working(arrived))
        XCTAssertTrue(status.message.lowercased().contains("last"))
    }
}
