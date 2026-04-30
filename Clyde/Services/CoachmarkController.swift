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
        case .collapse:   return true
        case .sessionRow: return false
        case .toolPlan:   return false
        case .snooze:     return false
        case .emptyState: return false
        }
    }
}

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

    /// Captured at `maybeStart` so that `.snooze` / `.collapse` (shared
    /// between branches) advance to the right next step.
    private var startedBranch: [CoachmarkStep]?

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

    /// Called from `ExpandedRootView.onAppear`. No-op if the tour was
    /// already shown, or if the onboarding modal has not yet been
    /// dismissed (onboarding always wins; coachmarks come after).
    /// Picks the first step based on whether any session is currently
    /// being tracked.
    func maybeStart(hasSessions: Bool) {
        guard !defaults.bool(forKey: Keys.shown) else { return }
        guard onboardingShown() else { return }
        let sequence = hasSessions ? Self.withSessionsSequence : Self.emptyStateSequence
        startedBranch = sequence
        currentStep = sequence.first
    }

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
        currentStep = nil
        startedBranch = nil
        claimedAnchorID = nil
    }

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
}
