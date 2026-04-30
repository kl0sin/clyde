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

    // MARK: - Helpers for migration tests

    private func tempDefaults() -> UserDefaults {
        let suiteName = "coachmark-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeController(
        defaults: UserDefaults,
        onboardingShown: Bool
    ) -> CoachmarkController {
        CoachmarkController(defaults: defaults, onboardingShown: { onboardingShown })
    }

    // MARK: - Migration

    func test_migration_marksExistingUsersAsShown() {
        let defaults = tempDefaults()
        let controller = makeController(defaults: defaults, onboardingShown: true)

        controller.runMigrationIfNeeded()

        XCTAssertTrue(defaults.bool(forKey: "coachmarksShown"))
        XCTAssertTrue(defaults.bool(forKey: "coachmarksMigrated"))
    }

    func test_migration_skipsFreshInstall() {
        let defaults = tempDefaults()
        let controller = makeController(defaults: defaults, onboardingShown: false)

        controller.runMigrationIfNeeded()

        XCTAssertFalse(defaults.bool(forKey: "coachmarksShown"))
        XCTAssertTrue(defaults.bool(forKey: "coachmarksMigrated"))
    }

    func test_migration_isIdempotent() {
        let defaults = tempDefaults()
        let controller = makeController(defaults: defaults, onboardingShown: true)
        controller.runMigrationIfNeeded()

        // Simulate user clearing the flag manually after the first migration ran.
        defaults.set(false, forKey: "coachmarksShown")

        controller.runMigrationIfNeeded()

        // Second call must NOT flip `coachmarksShown` back to true.
        XCTAssertFalse(defaults.bool(forKey: "coachmarksShown"))
    }
}
