import XCTest
@testable import Clyde

final class ReviewViewTests: XCTestCase {

    func testZeroSecondsRendersAsSeconds() {
        XCTAssertEqual(ReviewView.duration(0), "0s")
    }

    func testUnderAMinuteRendersAsSeconds() {
        XCTAssertEqual(ReviewView.duration(59), "59s")
    }

    func testExactlyOneMinuteRendersAsMinutes() {
        XCTAssertEqual(ReviewView.duration(60), "1m")
    }

    func testUnderAnHourRendersAsMinutes() {
        XCTAssertEqual(ReviewView.duration(3599), "59m")
    }

    func testExactlyOneHourRendersAsHoursAndZeroMinutes() {
        XCTAssertEqual(ReviewView.duration(3600), "1h 0m")
    }

    func testOverAnHourRendersAsHoursAndMinutes() {
        XCTAssertEqual(ReviewView.duration(3660), "1h 1m")
    }

    func testOverADayRendersAsHoursNotDays() {
        // 25h 30m — the format has no day component, so it should keep
        // accumulating hours rather than wrapping.
        XCTAssertEqual(ReviewView.duration(91_800), "25h 30m")
    }

    func testZeroTurnsStaysPlural() {
        XCTAssertEqual(ReviewView.turnLabel(0), "0 turns")
    }

    func testOneTurnIsSingular() {
        XCTAssertEqual(ReviewView.turnLabel(1), "1 turn")
    }

    func testTwoTurnsIsPlural() {
        XCTAssertEqual(ReviewView.turnLabel(2), "2 turns")
    }
}
