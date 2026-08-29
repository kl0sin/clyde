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

    // MARK: - When the busy split can be drawn

    /// Found by looking at a freshly upgraded install: the tiles read
    /// "Busy 0s" while the bar underneath drew a full-width "Tools 46s".
    /// Tool time is recorded as each call ends, but busy time only exists
    /// once a turn reaches its Stop — so mid-turn the parts can exceed the
    /// whole. There is nothing to divide, and drawing it anyway states an
    /// impossibility.
    func testNoSplitWhenThereIsNoBusyTimeToDivide() {
        XCTAssertFalse(ReviewView.showsBusySplit(working: 0, tools: 46))
    }

    /// The same situation less starkly: a turn is open, its tools have
    /// already been counted, and the completed turns before it total less.
    func testNoSplitWhenToolsExceedBusy() {
        XCTAssertFalse(ReviewView.showsBusySplit(working: 30, tools: 46))
    }

    /// History written before the hook reported durations has no tool time
    /// at all, and must not be drawn as if every second were thinking.
    func testNoSplitWithoutRecordedToolTime() {
        XCTAssertFalse(ReviewView.showsBusySplit(working: 600, tools: 0))
    }

    func testSplitShownWhenToolsFitInsideBusy() {
        XCTAssertTrue(ReviewView.showsBusySplit(working: 600, tools: 240))
        XCTAssertTrue(ReviewView.showsBusySplit(working: 600, tools: 600),
                      "a turn that was entirely tool calls still divides")
    }
}
