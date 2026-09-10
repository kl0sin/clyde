import Foundation

/// Which notifications a change in the limits earns. Pure and small so
/// the "once per window" rule can be tested without a notification
/// centre.
///
/// Two alerts only. The week crossing 80% is not one: a bar that has
/// been blue since Wednesday is not news on Thursday.
struct UsageLimitsAlerts: Equatable {
    enum Alert: Equatable {
        case sessionNearLimit(resetsAt: Date)
        case sessionBackAfterReset
    }

    /// The reset time of the window already warned about. A new window
    /// has a new reset time, which is what makes it warn again.
    var warnedResetsAt: Date?
    /// The `resetsAt` of the window that was exhausted, so a later
    /// snapshot can tell "that window turned over" apart from "the
    /// window merely vanished" or "the rate-limited session closed".
    var exhaustedResetsAt: Date?

    mutating func alerts(for limits: UsageLimits?, rateLimited: Bool, now: Date = Date()) -> [Alert] {
        var result: [Alert] = []
        let window = limits?.fiveHour
        let level = window.map { UsageLimits.level(for: $0, rateLimited: rateLimited) } ?? .normal
        let exhausted = window != nil && level == .exhausted

        if let window, level != .normal, warnedResetsAt != window.resetsAt {
            warnedResetsAt = window.resetsAt
            result.append(.sessionNearLimit(resetsAt: window.resetsAt))
        }

        // A window that is itself exhausted is never a reset, even if
        // it is a different window than the one already recorded — the
        // warn block above just said "used up" for this same tick.
        if !exhausted, let exhaustedResetsAt {
            let windowTurnedOver = window.map { $0.resetsAt != exhaustedResetsAt } ?? false
            if windowTurnedOver || now >= exhaustedResetsAt {
                result.append(.sessionBackAfterReset)
                self.exhaustedResetsAt = nil
            }
        }
        if exhausted {
            exhaustedResetsAt = window?.resetsAt
        }
        return result
    }
}
