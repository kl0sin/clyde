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
