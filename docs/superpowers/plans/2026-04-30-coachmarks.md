# Coachmarks First-Run Tour Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an in-context coachmark tour that fires the first time the user opens the expanded panel after the existing onboarding modal is dismissed. Four anchored popovers walk the user through a session row, the tool/plan indicator, the snooze button, and the collapse button (which doubles as the discovery moment for the `⌃⌘C` global hotkey). Persistent one-shot, skippable mid-tour, replayable from Settings, and suppressed for users upgrading from a Clyde version that didn't have the feature.

**Architecture:** A new `CoachmarkController` (`@MainActor ObservableObject`) owns all tour state — two `UserDefaults` flags (`coachmarksShown`, `coachmarksMigrated`) and an in-memory `@Published var currentStep: CoachmarkStep?`. SwiftUI views attach the popovers via a thin `.coachmarkAnchor(_:identity:)` modifier that reads the controller from the environment. Empty-state branch (no sessions yet) collapses the four-step tour to three (empty-state hint + snooze + collapse). Settings → General gets a `Replay welcome tour` button that clears the flag and re-fires the tour either immediately (if the panel is open) or on next expand.

**Tech Stack:** Swift 5.9, SwiftUI (macOS 13+), Combine (`@Published` already used elsewhere), XCTest, native `.popover(isPresented:)` modifier.

**Source spec:** `docs/superpowers/specs/2026-04-29-coachmarks-design.md`

---

## File Structure

**Create:**
- `Clyde/Services/CoachmarkController.swift` — controller, `CoachmarkStep` enum, all persistence + transition logic.
- `Clyde/Views/Components/CoachmarkPopover.swift` — popover content view AND the `.coachmarkAnchor(_:identity:)` view modifier that attaches `.popover` to any view.
- `ClydeTests/CoachmarkControllerTests.swift` — unit tests for the controller's pure logic.

**Modify:**
- `Clyde/ViewModels/AppViewModel.swift` — add a `let coachmarks: CoachmarkController` property, construct it in the existing initializer.
- `Clyde/App/AppDelegate.swift` — promote `onboardingShownKey` from `private static let` to `static let`, call `appViewModel.coachmarks.runMigrationIfNeeded()` once during launch, inject the controller into both panel hosts (expanded panel and settings window) via `.environmentObject`.
- `Clyde/Views/ExpandedRootView.swift` — `.onAppear` calls `maybeStart`, `.onDisappear` calls `reset`.
- `Clyde/Views/Components/ExpandedHeader.swift` — attach `.coachmarkAnchor(.snooze)` and `.coachmarkAnchor(.collapse)` to the corresponding header buttons.
- `Clyde/Views/Components/SessionRow.swift` — attach `.coachmarkAnchor(.sessionRow, identity: session.id)` to the row body and `.coachmarkAnchor(.toolPlan, identity: session.id)` to the tool/plan line.
- `Clyde/Views/Components/EmptyStateView.swift` — attach `.coachmarkAnchor(.emptyState)` to its content.
- `Clyde/Views/SettingsView.swift` — add a "Replay welcome tour" button to `GeneralSettingsTab` between the keyboard-shortcut help section and the polling-interval row.

**Decompose-by-responsibility note:** the controller owns logic + persistence + content; the popover file owns view + modifier. Two new files, no scattered `@AppStorage` calls. Each callsite that triggers a popover is a single-line annotation.

---

## Task 1: `CoachmarkStep` enum with content

**Files:**
- Create: `Clyde/Services/CoachmarkController.swift` (initial skeleton with the enum only — controller class is added in Task 2).
- Test: `ClydeTests/CoachmarkControllerTests.swift` (initial file).

- [ ] **Step 1: Write the failing test.**

Create `ClydeTests/CoachmarkControllerTests.swift`:

```swift
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
```

- [ ] **Step 2: Run the test to verify it fails.**

Run: `swift test --filter CoachmarkControllerTests`
Expected: FAIL with "cannot find type 'CoachmarkStep' in scope".

- [ ] **Step 3: Create the file with the enum and its content.**

Create `Clyde/Services/CoachmarkController.swift`:

```swift
import Foundation
import SwiftUI

/// One step of the first-run coachmark tour. Each case carries the
/// copy that the popover renders, so all tour content lives in a
/// single source of truth.
enum CoachmarkStep: String, CaseIterable {
    case sessionRow
    case toolPlan
    case snooze
    case collapse
    case emptyState

    var title: String {
        switch self {
        case .sessionRow: return "Live Claude sessions"
        case .toolPlan:   return "See what Claude is doing"
        case .snooze:     return "Mute alerts on demand"
        case .collapse:   return "Hide and reopen fast"
        case .emptyState: return "No sessions yet"
        }
    }

    var body: String {
        switch self {
        case .sessionRow:
            return "Each row is a Claude Code session running on your Mac. The pill on the right shows status — Working, Ready, or Needs Input. Click a row to jump to its terminal."
        case .toolPlan:
            return "When Claude calls a tool, the second line shows it live — Edit · MyFile.swift · 3s. If Claude maps out a multi-step plan, a progress badge tracks it across turns."
        case .snooze:
            return "Going into a meeting or demo? Snooze pauses sounds and notifications until you toggle it back on."
        case .collapse:
            return "Collapse to the floating widget any time. Press ⌃⌘C from anywhere to open or hide Clyde — no menu-bar click needed."
        case .emptyState:
            return "Start a Claude session in your terminal — Clyde will pick it up automatically and show it right here."
        }
    }

    /// "1 of 4" / "2 of 4" etc. for the with-sessions branch. `nil` for
    /// the empty-state branch — the abbreviated tour does not show a
    /// numerical position.
    var counterText: String? {
        switch self {
        case .sessionRow: return "1 of 4"
        case .toolPlan:   return "2 of 4"
        case .snooze:     return "3 of 4"
        case .collapse:   return "4 of 4"
        case .emptyState: return nil
        }
    }

    /// The last step's primary button reads "Done ✓" instead of "Got it ›".
    var isFinal: Bool {
        switch self {
        case .collapse: return true
        case .snooze:   return false       // when in empty-state branch the controller asks; see step ordering.
        default:        return false
        }
    }
}
```

> **Note on `isFinal` for empty-state branch:** when the empty-state branch ends on `.collapse`, `.collapse.isFinal == true` already gives the right answer. The branch never ends on `.snooze`, so leaving `.snooze.isFinal == false` is correct.

- [ ] **Step 4: Run the test to verify it passes.**

Run: `swift test --filter CoachmarkControllerTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit.**

```bash
git add Clyde/Services/CoachmarkController.swift ClydeTests/CoachmarkControllerTests.swift
git commit -m "feat(coachmarks): add CoachmarkStep enum with tour copy"
```

---

## Task 2: `CoachmarkController` skeleton + migration

**Files:**
- Modify: `Clyde/Services/CoachmarkController.swift` — add the `CoachmarkController` class.
- Modify: `ClydeTests/CoachmarkControllerTests.swift` — add migration tests.

- [ ] **Step 1: Add the failing tests.**

Append to `CoachmarkControllerTests.swift` (inside the same class):

```swift
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
```

- [ ] **Step 2: Run tests to verify they fail.**

Run: `swift test --filter CoachmarkControllerTests`
Expected: FAIL with "cannot find 'CoachmarkController' in scope".

- [ ] **Step 3: Implement the controller skeleton.**

Append to `Clyde/Services/CoachmarkController.swift`:

```swift
/// Drives the first-run coachmark tour. State machine over
/// `CoachmarkStep`, persisted as two `UserDefaults` booleans.
///
/// - Owned by `AppViewModel`, injected into the expanded panel and
///   settings window via `.environmentObject`.
/// - All UI surfaces interact through this object; there are no
///   scattered `@AppStorage` calls or persistence in the views.
@MainActor
final class CoachmarkController: ObservableObject {
    @Published private(set) var currentStep: CoachmarkStep?

    private let defaults: UserDefaults
    private let onboardingShown: () -> Bool

    private var claimedAnchorID: AnyHashable?

    private enum Keys {
        static let shown = "coachmarksShown"
        static let migrated = "coachmarksMigrated"
    }

    init(defaults: UserDefaults = .standard,
         onboardingShown: @escaping () -> Bool) {
        self.defaults = defaults
        self.onboardingShown = onboardingShown
    }

    /// One-shot, idempotent. Suppresses the tour for users upgrading
    /// from a Clyde version that didn't have coachmarks: if they had
    /// already dismissed the onboarding modal before this version
    /// shipped, treat the tour as already-shown so it doesn't fire.
    func runMigrationIfNeeded() {
        guard !defaults.bool(forKey: Keys.migrated) else { return }
        if onboardingShown() {
            defaults.set(true, forKey: Keys.shown)
        }
        defaults.set(true, forKey: Keys.migrated)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass.**

Run: `swift test --filter CoachmarkControllerTests`
Expected: PASS (6 tests total: 3 from Task 1 + 3 migration).

- [ ] **Step 5: Commit.**

```bash
git add Clyde/Services/CoachmarkController.swift ClydeTests/CoachmarkControllerTests.swift
git commit -m "feat(coachmarks): add CoachmarkController with migration"
```

---

## Task 3: `maybeStart` and step picking

**Files:**
- Modify: `Clyde/Services/CoachmarkController.swift` — add `maybeStart(hasSessions:)`.
- Modify: `ClydeTests/CoachmarkControllerTests.swift` — add tests.

- [ ] **Step 1: Add the failing tests.**

Append to the test class:

```swift
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
```

- [ ] **Step 2: Run tests to verify they fail.**

Run: `swift test --filter CoachmarkControllerTests`
Expected: FAIL with "value of type 'CoachmarkController' has no member 'maybeStart'".

- [ ] **Step 3: Implement `maybeStart`.**

Add to the `CoachmarkController` class body:

```swift
    /// Called from `ExpandedRootView.onAppear`. No-op if the tour was
    /// already shown, or if the onboarding modal has not yet been
    /// dismissed (onboarding always wins; coachmarks come after).
    /// Picks the first step based on whether any session is currently
    /// being tracked.
    func maybeStart(hasSessions: Bool) {
        guard !defaults.bool(forKey: Keys.shown) else { return }
        guard onboardingShown() else { return }
        currentStep = hasSessions ? .sessionRow : .emptyState
    }
```

- [ ] **Step 4: Run tests to verify they pass.**

Run: `swift test --filter CoachmarkControllerTests`
Expected: PASS (10 tests total).

- [ ] **Step 5: Commit.**

```bash
git add Clyde/Services/CoachmarkController.swift ClydeTests/CoachmarkControllerTests.swift
git commit -m "feat(coachmarks): trigger tour on first panel expand"
```

---

## Task 4: `advance` for both branches

**Files:**
- Modify: `Clyde/Services/CoachmarkController.swift` — add `advance()` and the step-sequence table.
- Modify: `ClydeTests/CoachmarkControllerTests.swift` — add tests.

- [ ] **Step 1: Add the failing tests.**

Append:

```swift
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
```

- [ ] **Step 2: Run tests to verify they fail.**

Run: `swift test --filter CoachmarkControllerTests`
Expected: FAIL with "no member 'advance'".

- [ ] **Step 3: Implement `advance` with explicit branch tables.**

Add to `CoachmarkController`:

```swift
    /// Step ordering for each branch. The branch is locked in at
    /// `maybeStart` time — appending a session list mid-tour does NOT
    /// switch the user from the empty-state branch into the with-sessions
    /// branch.
    private static let withSessionsSequence: [CoachmarkStep] = [
        .sessionRow, .toolPlan, .snooze, .collapse
    ]
    private static let emptyStateSequence: [CoachmarkStep] = [
        .emptyState, .snooze, .collapse
    ]

    private var activeSequence: [CoachmarkStep]? {
        guard let step = currentStep else { return nil }
        if Self.emptyStateSequence.contains(step) && step == .emptyState {
            return Self.emptyStateSequence
        }
        // `.snooze` and `.collapse` exist in both sequences. Disambiguate
        // by remembering which branch was started.
        return startedBranch
    }

    /// Captured at `maybeStart` so that `.snooze` / `.collapse` (shared
    /// between branches) advance to the right next step.
    private var startedBranch: [CoachmarkStep]?

    /// Advance one step. Called from the popover's "Got it ›" / "Done ✓"
    /// button. Crossing past the last step persists the "shown" flag and
    /// clears the in-memory step.
    func advance() {
        guard let step = currentStep, let sequence = startedBranch else { return }
        guard let idx = sequence.firstIndex(of: step) else { return }
        let next = idx + 1
        claimedAnchorID = nil
        if next >= sequence.count {
            currentStep = nil
            defaults.set(true, forKey: Keys.shown)
        } else {
            currentStep = sequence[next]
        }
    }
```

Update `maybeStart` to capture the branch:

```swift
    func maybeStart(hasSessions: Bool) {
        guard !defaults.bool(forKey: Keys.shown) else { return }
        guard onboardingShown() else { return }
        let sequence = hasSessions ? Self.withSessionsSequence : Self.emptyStateSequence
        startedBranch = sequence
        currentStep = sequence.first
    }
```

Remove the now-dead `activeSequence` computed property (it was only an exploration scaffold for thinking — `advance` reads `startedBranch` directly):

```swift
    // (delete the `activeSequence` computed property entirely)
```

- [ ] **Step 4: Run tests to verify they pass.**

Run: `swift test --filter CoachmarkControllerTests`
Expected: PASS (12 tests total).

- [ ] **Step 5: Commit.**

```bash
git add Clyde/Services/CoachmarkController.swift ClydeTests/CoachmarkControllerTests.swift
git commit -m "feat(coachmarks): walk both branches with advance"
```

---

## Task 5: `skip`, `reset`, `replay`

**Files:**
- Modify: `Clyde/Services/CoachmarkController.swift` — add three methods.
- Modify: `ClydeTests/CoachmarkControllerTests.swift` — add tests.

- [ ] **Step 1: Add the failing tests.**

```swift
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

    func test_replay_thenMaybeStart_restartsTour() {
        let defaults = tempDefaults()
        defaults.set(true, forKey: "coachmarksShown")
        let controller = makeController(defaults: defaults, onboardingShown: true)

        controller.replay()
        controller.maybeStart(hasSessions: true)

        XCTAssertEqual(controller.currentStep, .sessionRow)
    }
```

- [ ] **Step 2: Run tests to verify they fail.**

Run: `swift test --filter CoachmarkControllerTests`
Expected: FAIL with "no member 'skip'".

- [ ] **Step 3: Implement.**

Append to `CoachmarkController`:

```swift
    /// "Skip tour" link in the popover footer. Treated identically to
    /// completion — the tour does not show again until replayed.
    func skip() {
        currentStep = nil
        startedBranch = nil
        claimedAnchorID = nil
        defaults.set(true, forKey: Keys.shown)
    }

    /// Called from `ExpandedRootView.onDisappear`. Clears in-memory state
    /// without persisting — the tour starts again from step 1 next time
    /// the panel opens.
    func reset() {
        currentStep = nil
        startedBranch = nil
        claimedAnchorID = nil
    }

    /// "Replay welcome tour" button in Settings. Clears the persisted
    /// flag but does not touch `currentStep`. The Settings view decides
    /// whether to call `maybeStart` immediately (panel open) or rely on
    /// `ExpandedRootView.onAppear` to fire on the next expand
    /// (panel collapsed).
    func replay() {
        defaults.set(false, forKey: Keys.shown)
    }
```

- [ ] **Step 4: Run tests to verify they pass.**

Run: `swift test --filter CoachmarkControllerTests`
Expected: PASS (16 tests total).

- [ ] **Step 5: Commit.**

```bash
git add Clyde/Services/CoachmarkController.swift ClydeTests/CoachmarkControllerTests.swift
git commit -m "feat(coachmarks): support skip, reset, and replay"
```

---

## Task 6: `shouldAnchor` first-claim-wins

**Files:**
- Modify: `Clyde/Services/CoachmarkController.swift` — add the method.
- Modify: `ClydeTests/CoachmarkControllerTests.swift` — add the test.

- [ ] **Step 1: Add the failing test.**

```swift
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
```

- [ ] **Step 2: Run tests to verify they fail.**

Run: `swift test --filter CoachmarkControllerTests`
Expected: FAIL with "no member 'shouldAnchor'".

- [ ] **Step 3: Implement.**

Add to `CoachmarkController`:

```swift
    /// True if this anchor should display the popover for the given
    /// step. The first call for an active step claims the anchor; later
    /// calls for the same step return true only if the identity matches
    /// the claim. Callers in `ForEach` lists pass a stable per-row
    /// identity so SwiftUI re-renders don't flip the popover from row
    /// to row.
    func shouldAnchor(_ step: CoachmarkStep, identity: AnyHashable) -> Bool {
        guard currentStep == step else { return false }
        if let claimed = claimedAnchorID {
            return claimed == identity
        }
        claimedAnchorID = identity
        return true
    }
```

- [ ] **Step 4: Run tests to verify they pass.**

Run: `swift test --filter CoachmarkControllerTests`
Expected: PASS (18 tests total).

- [ ] **Step 5: Commit.**

```bash
git add Clyde/Services/CoachmarkController.swift ClydeTests/CoachmarkControllerTests.swift
git commit -m "feat(coachmarks): claim anchors for repeated rows"
```

---

## Task 7: Wire controller into `AppViewModel`

**Files:**
- Modify: `Clyde/ViewModels/AppViewModel.swift` — add the property + initializer wiring.

- [ ] **Step 1: Read the existing `AppViewModel` initializer.**

Run: `grep -n "init(\|let notificationService\|self.notificationService" Clyde/ViewModels/AppViewModel.swift`
Expected: shows where `notificationService` is declared and constructed (mirrors the pattern we follow).

- [ ] **Step 2: Add the property.**

In `AppViewModel.swift`, near the other service property declarations (just below `let notificationService`):

```swift
    /// Drives the first-run coachmark tour. Owned here so the same
    /// instance is shared between the expanded panel and the Settings
    /// window via `.environmentObject`.
    let coachmarks: CoachmarkController
```

- [ ] **Step 3: Initialize it.**

In the initializer body, near where `notificationService` is initialized, add:

```swift
        self.coachmarks = CoachmarkController(
            onboardingShown: { UserDefaults.standard.bool(forKey: AppDelegate.onboardingShownKey) }
        )
```

(`AppDelegate.onboardingShownKey` is promoted to non-private in Task 8.)

- [ ] **Step 4: Build to verify the file still compiles in isolation.**

Run: `swift build 2>&1 | head -40`
Expected: still fails because `AppDelegate.onboardingShownKey` is private — that is fixed in Task 8. If you want to checkpoint here, temporarily inline the literal `"onboardingShown"` and undo it in Task 8.

For an isolated checkpoint, use the literal:

```swift
        self.coachmarks = CoachmarkController(
            onboardingShown: { UserDefaults.standard.bool(forKey: "onboardingShown") }
        )
```

- [ ] **Step 5: Build + run tests.**

Run: `swift build && swift test --filter CoachmarkControllerTests`
Expected: build succeeds, all coachmark tests still PASS.

- [ ] **Step 6: Commit.**

```bash
git add Clyde/ViewModels/AppViewModel.swift
git commit -m "feat(coachmarks): own controller on AppViewModel"
```

---

## Task 8: Promote `onboardingShownKey` and call migration from `AppDelegate`

**Files:**
- Modify: `Clyde/App/AppDelegate.swift` — change visibility of `onboardingShownKey`, add the migration call, and fix `AppViewModel` to use the named constant.
- Modify: `Clyde/ViewModels/AppViewModel.swift` — switch from the literal to `AppDelegate.onboardingShownKey`.

- [ ] **Step 1: Promote the constant.**

In `Clyde/App/AppDelegate.swift`, line 658, change:

```swift
    private static let onboardingShownKey = "onboardingShown"
```

to:

```swift
    static let onboardingShownKey = "onboardingShown"
```

- [ ] **Step 2: Update `AppViewModel`'s closure to use the constant.**

In `Clyde/ViewModels/AppViewModel.swift`, replace the literal closure body added in Task 7:

```swift
        self.coachmarks = CoachmarkController(
            onboardingShown: { UserDefaults.standard.bool(forKey: AppDelegate.onboardingShownKey) }
        )
```

- [ ] **Step 3: Add the migration call.**

In `Clyde/App/AppDelegate.swift`, find `applicationDidFinishLaunching` (it's the method that wires Combine subscribers around line 200). The existing line 201 reads `self?.showOnboardingIfNeeded()` inside a `Task { @MainActor in ... }` (see grep below if needed).

Run: `grep -n "showOnboardingIfNeeded\|applicationDidFinishLaunching" Clyde/App/AppDelegate.swift`
Expected: prints the surrounding lines.

Just before the `showOnboardingIfNeeded()` call, add:

```swift
            self?.appViewModel.coachmarks.runMigrationIfNeeded()
```

The order matters: migration runs **before** onboarding is shown, so the migration sees the prior-version state of `onboardingShown` (set true on a previous app run, untouched by this launch yet).

- [ ] **Step 4: Build + run all tests.**

Run: `swift build && swift test`
Expected: build succeeds, full suite passes (~80 tests including the 18 new ones).

- [ ] **Step 5: Commit.**

```bash
git add Clyde/App/AppDelegate.swift Clyde/ViewModels/AppViewModel.swift
git commit -m "feat(coachmarks): run migration at app launch"
```

---

## Task 9: `CoachmarkPopover` view

**Files:**
- Create: `Clyde/Views/Components/CoachmarkPopover.swift` — popover content view (the modifier comes in Task 10).

- [ ] **Step 1: Create the file with the popover view.**

Create `Clyde/Views/Components/CoachmarkPopover.swift`:

```swift
import SwiftUI

/// Content of a single coachmark popover. The system `.popover`
/// modifier hosts this view; we draw the title, body, footer with
/// counter / skip / advance.
///
/// `step.isFinal` swaps the primary button label from "Got it ›" to
/// "Done ✓".
struct CoachmarkPopover: View {
    let step: CoachmarkStep
    let onAdvance: () -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(step.title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            Text(step.body)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .center) {
                if let counter = step.counterText {
                    Text(counter)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .accessibilityLabel("Step \(counter)")
                }

                Spacer()

                Button("Skip tour", action: onSkip)
                    .buttonStyle(.link)
                    .accessibilityLabel("Skip the welcome tour")

                Button(step.isFinal ? "Done ✓" : "Got it ›", action: onAdvance)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
        .padding(14)
        .frame(width: 260)
    }
}
```

- [ ] **Step 2: Build to verify.**

Run: `swift build`
Expected: succeeds.

- [ ] **Step 3: Commit.**

```bash
git add Clyde/Views/Components/CoachmarkPopover.swift
git commit -m "feat(coachmarks): add popover content view"
```

---

## Task 10: `.coachmarkAnchor(_:identity:)` view modifier

**Files:**
- Modify: `Clyde/Views/Components/CoachmarkPopover.swift` — append the `View` extension and supporting modifier struct.

- [ ] **Step 1: Add the extension.**

Append to `Clyde/Views/Components/CoachmarkPopover.swift`:

```swift
extension View {
    /// Attaches a coachmark popover to this view. The popover is
    /// presented when `controller.currentStep == step` and this
    /// view's `identity` wins the first-claim-wins race (handled by
    /// `controller.shouldAnchor`).
    ///
    /// `identity` defaults to a per-call `UUID()` — fine for
    /// single-anchor steps (snooze, collapse, emptyState). Pass a
    /// stable per-row identity for steps anchored inside `ForEach`
    /// lists (sessionRow, toolPlan).
    func coachmarkAnchor(
        _ step: CoachmarkStep,
        identity: AnyHashable = AnyHashable(UUID())
    ) -> some View {
        modifier(CoachmarkAnchorModifier(step: step, identity: identity))
    }
}

private struct CoachmarkAnchorModifier: ViewModifier {
    let step: CoachmarkStep
    let identity: AnyHashable

    @EnvironmentObject private var controller: CoachmarkController

    func body(content: Content) -> some View {
        content.popover(
            isPresented: Binding(
                get: { controller.shouldAnchor(step, identity: identity) },
                set: { isShown in
                    // System closes the popover (click-outside, panel
                    // closes, etc.). Treat as "skip" so the tour does
                    // not re-fire; the caller has the dedicated
                    // .onDisappear hook on the panel root if they want
                    // a non-persisting reset instead.
                    if !isShown && controller.currentStep == step {
                        controller.skip()
                    }
                }
            ),
            arrowEdge: .trailing
        ) {
            CoachmarkPopover(
                step: step,
                onAdvance: { controller.advance() },
                onSkip: { controller.skip() }
            )
        }
    }
}
```

> **Why `arrowEdge: .trailing`:** the panel sits in the top-right of the screen by default; popovers anchored to its content need to point left toward the panel. SwiftUI is free to override this edge if there isn't enough room — we just hint at the preference.

> **Click-outside semantics:** macOS `.popover` dismisses on outside click. We treat outside-click as `skip()` so the user doesn't get re-prompted on the same step forever. The dedicated `.onDisappear` on the panel root handles the *panel-closes* case differently (calls `reset()` instead of `skip()`) — and `reset()` runs first because `.onDisappear` fires before the popover sees its own dismissal.

- [ ] **Step 2: Build to verify.**

Run: `swift build`
Expected: succeeds.

- [ ] **Step 3: Commit.**

```bash
git add Clyde/Views/Components/CoachmarkPopover.swift
git commit -m "feat(coachmarks): expose coachmarkAnchor view modifier"
```

---

## Task 11: Wire `ExpandedRootView` lifecycle + inject controller

**Files:**
- Modify: `Clyde/Views/ExpandedRootView.swift` — `.onAppear` / `.onDisappear` and inject controller via env.

- [ ] **Step 1: Update `ExpandedRootView`.**

Replace the contents of `Clyde/Views/ExpandedRootView.swift`:

```swift
import SwiftUI

/// Root view hosted inside the expanded panel. Always shows the session
/// list — settings now live in their own standalone window.
struct ExpandedRootView: View {
    @ObservedObject var appViewModel: AppViewModel
    @ObservedObject var sessionViewModel: SessionListViewModel

    var body: some View {
        ZStack(alignment: .top) {
            ExpandedView(
                appViewModel: appViewModel,
                sessionViewModel: sessionViewModel
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))

            if let error = appViewModel.lastError {
                ErrorBanner(message: error)
                    .padding(.top, 8)
                    .padding(.horizontal, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: appViewModel.lastError)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .environmentObject(appViewModel.coachmarks)
        .onAppear {
            appViewModel.coachmarks.maybeStart(
                hasSessions: !sessionViewModel.sessions.isEmpty
            )
        }
        .onDisappear {
            appViewModel.coachmarks.reset()
        }
    }
}
```

- [ ] **Step 2: Build.**

Run: `swift build`
Expected: succeeds.

- [ ] **Step 3: Commit.**

```bash
git add Clyde/Views/ExpandedRootView.swift
git commit -m "feat(coachmarks): drive lifecycle from ExpandedRootView"
```

---

## Task 12: Anchor `sessionRow` and `toolPlan` on `SessionRow`

**Files:**
- Modify: `Clyde/Views/Components/SessionRow.swift` — attach two anchors with stable identity.

- [ ] **Step 1: Read the row body.**

Run: `sed -n '30,160p' Clyde/Views/Components/SessionRow.swift`
Expected: shows the `var body` block. Locate (a) the outer `HStack` that contains the row, and (b) the line that renders the second-line text — the tool/plan label is rendered when `session.activeTool != nil` (search for `if let tool = session.activeTool` around line 105).

- [ ] **Step 2: Wrap the row body's outer HStack with the `sessionRow` anchor.**

Find the outermost `HStack(spacing: 12)` that opens the body (around line 31). Append a modifier *after the closing brace of the outer HStack and after any existing modifiers like `.padding`, `.background`, `.contentShape`, etc.*:

```swift
        .coachmarkAnchor(.sessionRow, identity: AnyHashable(session.id))
```

If the existing chain at the bottom of the row body already has many modifiers, append `.coachmarkAnchor` as the **last** one so the popover anchors to the fully-rendered row including its background.

- [ ] **Step 3: Wrap the tool/plan line with the `toolPlan` anchor.**

Find the block guarded by `if let tool = session.activeTool, let label = session.toolDisplayLabel { ... }` (around line 105). Append `.coachmarkAnchor(.toolPlan, identity: AnyHashable(session.id))` as the last modifier on the view inside that branch.

If the tool line is rendered as a single `Text(...)` with several modifiers, place the anchor at the end of the chain. If it is rendered inside an `HStack`, place the anchor on the `HStack`. Either is correct — the popover will anchor to whatever view receives the modifier.

- [ ] **Step 4: Build.**

Run: `swift build`
Expected: succeeds.

- [ ] **Step 5: Commit.**

```bash
git add Clyde/Views/Components/SessionRow.swift
git commit -m "feat(coachmarks): anchor session-row and tool-plan popovers"
```

---

## Task 13: Anchor `snooze` and `collapse` on `ExpandedHeader`

**Files:**
- Modify: `Clyde/Views/Components/ExpandedHeader.swift` — attach anchors to the header buttons.

- [ ] **Step 1: Update the snooze and collapse button declarations.**

In `ExpandedHeader.swift` (lines 49–63), the three header buttons are constructed inline in the right-side `HStack(spacing: 4)`. Wrap the snooze and collapse buttons with anchor modifiers:

Replace:

```swift
            HStack(spacing: 4) {
                headerButton(
                    icon: isSnoozed ? "moon.zzz.fill" : "moon.zzz",
                    action: onSnooze,
                    accessibilityLabel: isSnoozed ? "Resume notifications" : "Snooze notifications"
                )
                headerButton(
                    icon: "gearshape",
                    action: onSettings,
                    accessibilityLabel: "Open settings"
                )
                headerButton(
                    icon: "minus",
                    action: onCollapse,
                    accessibilityLabel: "Collapse to widget"
                )
            }
```

with:

```swift
            HStack(spacing: 4) {
                headerButton(
                    icon: isSnoozed ? "moon.zzz.fill" : "moon.zzz",
                    action: onSnooze,
                    accessibilityLabel: isSnoozed ? "Resume notifications" : "Snooze notifications"
                )
                .coachmarkAnchor(.snooze)

                headerButton(
                    icon: "gearshape",
                    action: onSettings,
                    accessibilityLabel: "Open settings"
                )

                headerButton(
                    icon: "minus",
                    action: onCollapse,
                    accessibilityLabel: "Collapse to widget"
                )
                .coachmarkAnchor(.collapse)
            }
```

(Settings button gets no anchor — it is not part of the four-step tour.)

- [ ] **Step 2: Build.**

Run: `swift build`
Expected: succeeds.

- [ ] **Step 3: Commit.**

```bash
git add Clyde/Views/Components/ExpandedHeader.swift
git commit -m "feat(coachmarks): anchor snooze and collapse popovers"
```

---

## Task 14: Anchor `emptyState` on `EmptyStateView`

**Files:**
- Modify: `Clyde/Views/Components/EmptyStateView.swift` — attach the empty-state anchor.

- [ ] **Step 1: Inspect the file.**

Run: `cat Clyde/Views/Components/EmptyStateView.swift`
Expected: the file has a `struct EmptyStateView: View` with a body containing the "no sessions" placeholder content.

- [ ] **Step 2: Append the anchor at the end of the body.**

Find the outermost view returned by `EmptyStateView.body` (likely a `VStack`). Append as the last modifier on that view:

```swift
        .coachmarkAnchor(.emptyState)
```

- [ ] **Step 3: Build.**

Run: `swift build`
Expected: succeeds.

- [ ] **Step 4: Commit.**

```bash
git add Clyde/Views/Components/EmptyStateView.swift
git commit -m "feat(coachmarks): anchor empty-state popover"
```

---

## Task 15: Settings → General "Replay welcome tour" button

**Files:**
- Modify: `Clyde/Views/SettingsView.swift` — add the button to `GeneralSettingsTab`.

- [ ] **Step 1: Locate the keyboard-shortcut help section.**

Run: `grep -n "Keyboard\|⌃⌘C\|polling\|Polling" Clyde/Views/SettingsView.swift | head -20`
Expected: identify the row that displays keyboard shortcuts (added in v0.2.2) and the row that wraps the polling-interval slider. The replay button goes between them.

- [ ] **Step 2: Add the button + confirmation label.**

Inside `GeneralSettingsTab`, between the keyboard-shortcuts section and the polling-interval row, insert:

```swift
            // MARK: - Replay welcome tour

            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Welcome tour")
                        .font(.system(size: 12, weight: .medium))
                    Text("Replay the first-run tour that points out the session row, snooze, and the global hotkey.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                Button("Replay welcome tour") {
                    appViewModel.coachmarks.replay()
                    if !appViewModel.isCollapsed {
                        appViewModel.coachmarks.maybeStart(
                            hasSessions: !appViewModel.processMonitor.sessions.filter { !$0.isGhost }.isEmpty
                        )
                    } else {
                        replayQueued = true
                    }
                }
            }
            .padding(.vertical, 8)

            if replayQueued {
                Text("Tour will replay next time you open the panel.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
```

Add a `@State private var replayQueued: Bool = false` near the top of `GeneralSettingsTab`. Add an `.onReceive(appViewModel.$isCollapsed)` near the body end to clear the flag when the panel reopens:

```swift
        .onReceive(appViewModel.$isCollapsed) { isCollapsed in
            if !isCollapsed { replayQueued = false }
        }
```

> **Why read `processMonitor.sessions` directly here:** `AppViewModel` already exposes a non-ghost session count via the same filter elsewhere (`processMonitor.sessions.filter { !$0.isGhost }`). If a higher-level `hasActiveSessions` accessor was added in another change, prefer it; otherwise this matches existing usage.

- [ ] **Step 3: Build.**

Run: `swift build`
Expected: succeeds.

- [ ] **Step 4: Commit.**

```bash
git add Clyde/Views/SettingsView.swift
git commit -m "feat(coachmarks): add Replay welcome tour to Settings"
```

---

## Task 16: Manual smoke + ROADMAP/CHANGELOG

**Files:**
- Modify: `ROADMAP.md` — tick the two coachmark items.
- Modify: `CHANGELOG.md` — add a `## [Unreleased]` bullet.
- Modify: `docs/hook-smoke-test.md` — append a "Coachmark scenarios" section (optional but documented in the spec).

- [ ] **Step 1: Run the full test suite.**

Run: `swift test`
Expected: all ~80 tests pass (62 existing + 18 new coachmark tests).

- [ ] **Step 2: Build and run the app for smoke testing.**

Run: `swift build -c debug && open .build/arm64-apple-macosx/debug/Clyde` *(adjust binary path if Swift Package builds the app under a different name on this machine — `swift build --show-bin-path` reveals it).*

If the package doesn't produce a runnable app bundle (Clyde uses an Xcode project for the actual app target — Swift Package only builds tests), fall back to: `xcodebuild -scheme Clyde -configuration Debug build && open <DerivedData>/Clyde.app`. Use whichever path the existing release process script (`.github/workflows/release.yml`) uses for local debug builds.

- [ ] **Step 3: Smoke scenarios.**

Run each scenario and confirm the observable result. Use `defaults` commands to manipulate state between runs:

1. **Fresh install path.**
   ```bash
   defaults delete com.kl0sin.Clyde
   ```
   Launch app → onboarding modal appears → click "Get Started" → click menu-bar icon → expanded panel opens → coachmark `.sessionRow` (or `.emptyState` if no sessions running) appears. Click `Got it ›` four times → tour completes. Confirm:
   ```bash
   defaults read com.kl0sin.Clyde coachmarksShown   # → 1
   defaults read com.kl0sin.Clyde coachmarksMigrated # → 1
   ```

2. **Existing-user upgrade path.**
   ```bash
   defaults delete com.kl0sin.Clyde
   defaults write com.kl0sin.Clyde onboardingShown -bool true
   ```
   Launch app → tour does **not** appear on first panel expand. Confirm:
   ```bash
   defaults read com.kl0sin.Clyde coachmarksShown    # → 1
   defaults read com.kl0sin.Clyde coachmarksMigrated # → 1
   ```

3. **Replay (panel open).**
   With panel currently expanded, open Settings → General → click "Replay welcome tour" → tour fires immediately in the panel.

4. **Replay (panel collapsed).**
   Collapse the panel. Open Settings → General → click "Replay welcome tour" → "Tour will replay next time you open the panel." appears under the button. Click menu-bar icon → tour fires.

5. **Mid-tour close.**
   Trigger replay, advance to step 2, click menu-bar icon to close the panel. Reopen → tour starts from step 1 (not step 2).

6. **Skip.**
   Trigger replay, click `Skip tour` on any step → popover dismisses, tour does not show on next expand.

- [ ] **Step 4: ROADMAP / CHANGELOG.**

In `ROADMAP.md`, replace the two unchecked items in the v0.3.0+ phase with `[x]` lines describing what shipped:

```
- [x] Coachmarks / "how to use" tour on first panel expand — four anchored popovers (session row + tool/plan line + snooze + collapse/⌃⌘C hotkey) using SwiftUI's native `.popover`. Empty-state branch handles "no sessions yet" with a three-step degraded tour. Migration suppresses the tour for users upgrading from a Clyde version without coachmarks. !md #ux
- [x] Coachmark re-trigger from Settings ("Replay welcome tour") — General tab button clears the persisted flag and either restarts the tour immediately (panel open) or queues it for the next expand. !lo #ux
```

In `CHANGELOG.md`, under `## [Unreleased]`, add:

```
- **First-run coachmark tour.** After the welcome modal, the first time you open the panel Clyde walks you through the four things that aren't obvious — what a session row shows, the live tool / plan progress on its second line, the snooze button in the header, and the global ⌃⌘C hotkey for opening or hiding the panel. Skippable mid-tour, replayable from Settings → General, and silent for anyone upgrading from a Clyde version that didn't have it.
```

- [ ] **Step 5: Commit.**

```bash
git add ROADMAP.md CHANGELOG.md
git commit -m "docs: tick coachmark roadmap items, add changelog entry"
```

---

## Self-review checklist (post-plan)

- [x] **Spec coverage.** Every section of `2026-04-29-coachmarks-design.md` maps to a task: enum + content (T1), controller + migration (T2), `maybeStart` (T3), `advance` (T4), `skip`/`reset`/`replay` (T5), `shouldAnchor` (T6), wiring through AppViewModel/AppDelegate (T7-T8), popover view + modifier (T9-T10), lifecycle + anchors (T11-T14), Settings replay (T15), smoke + docs (T16).
- [x] **Placeholder scan.** No "TBD"/"TODO"/"similar to". One inline note about path discovery for the debug build (Task 16 step 2) is acceptable because the surrounding repo has multiple build paths and the implementer must pick the one their machine produces.
- [x] **Type consistency.** `CoachmarkStep`, `CoachmarkController`, `CoachmarkPopover`, `coachmarkAnchor(_:identity:)`, `coachmarksShown`, `coachmarksMigrated`, `runMigrationIfNeeded()`, `maybeStart(hasSessions:)`, `advance()`, `skip()`, `reset()`, `replay()`, `shouldAnchor(_:identity:)` — all referenced consistently across tasks.
- [x] **Test count.** 18 unit tests across 6 task increments (matches the spec's ~14 estimate plus a few sub-divisions for clarity).
