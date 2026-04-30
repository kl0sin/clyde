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

    // MARK: - maybeStart

    func test_maybeStart_blockedIfShown() {
        let defaults = tempDefaults()
        defaults.set(true, forKey: "coachmarksShown")
        let controller = makeController(defaults: defaults, onboardingShown: true)

        controller.maybeStart(hasSessions: true)

        XCTAssertNil(controller.currentStep)
    }

    func test_maybeStart_blockedIfOnboardingNotShown() {
        let defaults = tempDefaults()
        let controller = makeController(defaults: defaults, onboardingShown: false)

        controller.maybeStart(hasSessions: true)

        XCTAssertNil(controller.currentStep)
    }

    func test_maybeStart_picksSessionRow_whenSessionsExist() {
        let defaults = tempDefaults()
        let controller = makeController(defaults: defaults, onboardingShown: true)

        controller.maybeStart(hasSessions: true)

        XCTAssertEqual(controller.currentStep, .sessionRow)
    }

    func test_maybeStart_picksEmptyState_whenNoSessions() {
        let defaults = tempDefaults()
        let controller = makeController(defaults: defaults, onboardingShown: true)

        controller.maybeStart(hasSessions: false)

        XCTAssertEqual(controller.currentStep, .emptyState)
    }

    // MARK: - advance

    func test_advance_walksFullTour_withSessions() {
        let defaults = tempDefaults()
        let controller = makeController(defaults: defaults, onboardingShown: true)
        controller.maybeStart(hasSessions: true)

        XCTAssertEqual(controller.currentStep, .sessionRow)
        controller.advance()
        XCTAssertEqual(controller.currentStep, .toolPlan)
        controller.advance()
        XCTAssertEqual(controller.currentStep, .snooze)
        controller.advance()
        XCTAssertEqual(controller.currentStep, .collapse)
        controller.advance()
        XCTAssertNil(controller.currentStep)
        XCTAssertTrue(defaults.bool(forKey: "coachmarksShown"))
    }

    func test_advance_walksEmptyStateBranch() {
        let defaults = tempDefaults()
        let controller = makeController(defaults: defaults, onboardingShown: true)
        controller.maybeStart(hasSessions: false)

        XCTAssertEqual(controller.currentStep, .emptyState)
        controller.advance()
        XCTAssertEqual(controller.currentStep, .snooze)
        controller.advance()
        XCTAssertEqual(controller.currentStep, .collapse)
        controller.advance()
        XCTAssertNil(controller.currentStep)
        XCTAssertTrue(defaults.bool(forKey: "coachmarksShown"))
    }

    // MARK: - skip / reset / replay

    func test_skip_marksAsShownAndClears() {
        let defaults = tempDefaults()
        let controller = makeController(defaults: defaults, onboardingShown: true)
        controller.maybeStart(hasSessions: true)

        controller.skip()

        XCTAssertNil(controller.currentStep)
        XCTAssertTrue(defaults.bool(forKey: "coachmarksShown"))
    }

    func test_reset_clearsStepWithoutPersisting() {
        let defaults = tempDefaults()
        let controller = makeController(defaults: defaults, onboardingShown: true)
        controller.maybeStart(hasSessions: true)

        controller.reset()

        XCTAssertNil(controller.currentStep)
        XCTAssertFalse(defaults.bool(forKey: "coachmarksShown"))
    }

    func test_replay_clearsFlagWithoutStarting() {
        let defaults = tempDefaults()
        defaults.set(true, forKey: "coachmarksShown")
        let controller = makeController(defaults: defaults, onboardingShown: true)

        controller.replay()

        XCTAssertFalse(defaults.bool(forKey: "coachmarksShown"))
        XCTAssertNil(controller.currentStep)
    }

    func test_replay_clearsStaleStateFromPriorRun() {
        let defaults = tempDefaults()
        let controller = makeController(defaults: defaults, onboardingShown: true)

        // Simulate: tour started, partially advanced, panel closed mid-tour
        // (reset() does not persist `coachmarksShown`, so the flag is still
        // false — the user can run the tour again on next expand).
        controller.maybeStart(hasSessions: true)
        controller.advance() // .toolPlan
        // User explicitly hits "Replay" while the previous run's in-memory
        // state is still around because reset() hasn't fired yet (e.g. the
        // panel is still open and Settings is open in parallel).
        // Without the defensive cleanup, currentStep would stay at .toolPlan.

        controller.replay()

        XCTAssertNil(controller.currentStep)
    }

    func test_replay_thenMaybeStart_restartsTour() {
        let defaults = tempDefaults()
        defaults.set(true, forKey: "coachmarksShown")
        let controller = makeController(defaults: defaults, onboardingShown: true)

        controller.replay()
        controller.maybeStart(hasSessions: true)

        XCTAssertEqual(controller.currentStep, .sessionRow)
    }

    // MARK: - shouldAnchor

    func test_shouldAnchor_firstClaimWins() {
        let defaults = tempDefaults()
        let controller = makeController(defaults: defaults, onboardingShown: true)
        controller.maybeStart(hasSessions: true)

        XCTAssertTrue(controller.shouldAnchor(.sessionRow, identity: AnyHashable("a")))
        XCTAssertFalse(controller.shouldAnchor(.sessionRow, identity: AnyHashable("b")))
        XCTAssertTrue(controller.shouldAnchor(.sessionRow, identity: AnyHashable("a")))

        controller.advance()

        // After advance the claim is cleared, so a new anchor in the
        // *next* step can win.
        XCTAssertTrue(controller.shouldAnchor(.toolPlan, identity: AnyHashable("c")))
    }

    func test_shouldAnchor_falseWhenStepNotActive() {
        let defaults = tempDefaults()
        let controller = makeController(defaults: defaults, onboardingShown: true)
        controller.maybeStart(hasSessions: true)

        // Step is .sessionRow, not .snooze.
        XCTAssertFalse(controller.shouldAnchor(.snooze, identity: AnyHashable("x")))
    }
}
