import XCTest
@testable import Clyde

final class UsageLimitsStatusTests: XCTestCase {
    func testOffIsOffWhateverElseIsWrong() {
        XCTAssertEqual(UsageLimitsStatus.resolve(enabled: false, issue: .scriptMissing, installError: "x", lastSnapshot: nil), .off)
    }

    func testAnInstallErrorBlocks() {
        XCTAssertEqual(UsageLimitsStatus.resolve(enabled: true, issue: nil, installError: "Failed to write", lastSnapshot: nil),
                       .blocked("Failed to write"))
    }

    func testAHealthIssueBlocks() {
        XCTAssertEqual(UsageLimitsStatus.resolve(enabled: true, issue: .displaced(by: "x.sh"), installError: nil, lastSnapshot: nil),
                       .blocked(UsageLimitsInstaller.Issue.displaced(by: "x.sh").message))
    }

    func testHealthyWithNothingYetIsWaiting() {
        XCTAssertEqual(UsageLimitsStatus.resolve(enabled: true, issue: nil, installError: nil, lastSnapshot: nil), .waiting)
    }

    func testASnapshotMeansWorking() {
        let date = Date()
        XCTAssertEqual(UsageLimitsStatus.resolve(enabled: true, issue: nil, installError: nil, lastSnapshot: date), .working(date))
    }

    func testMessagesSayWhereTheNumbersAre() {
        XCTAssertTrue(UsageLimitsStatus.off.message.contains("/usage"))
        XCTAssertTrue(UsageLimitsStatus.waiting.message.contains("Pro or Max"))
    }
}
