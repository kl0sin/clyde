import XCTest
@testable import Clyde

@MainActor
final class CoachmarkControllerTests: XCTestCase {
    func test_step_sessionRow_carriesExpectedContent() {
        let step = CoachmarkStep.sessionRow
        XCTAssertEqual(step.title, "Live Claude sessions")
        XCTAssertTrue(step.body.contains("status — Working, Ready, or Needs Input"))
        XCTAssertEqual(step.counterText, "1 of 4")
        XCTAssertFalse(step.isFinal)
    }

    func test_step_collapse_isFinalAndCarriesHotkey() {
        let step = CoachmarkStep.collapse
        XCTAssertTrue(step.body.contains("⌃⌘C"))
        XCTAssertEqual(step.counterText, "4 of 4")
        XCTAssertTrue(step.isFinal)
    }

    func test_step_emptyState_hasNoCounter() {
        XCTAssertNil(CoachmarkStep.emptyState.counterText)
    }
}
