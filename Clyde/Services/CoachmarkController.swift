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
        case .snooze:   return false
        default:        return false
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
        currentStep = hasSessions ? .sessionRow : .emptyState
    }
}
