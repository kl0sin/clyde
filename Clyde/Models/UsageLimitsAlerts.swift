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
    /// Whether the last snapshot was spent, so the next one that is
    /// not can say so.
    var wasExhausted = false

    mutating func alerts(for limits: UsageLimits?, rateLimited: Bool) -> [Alert] {
        var result: [Alert] = []
        let window = limits?.fiveHour
        let level = window.map { UsageLimits.level(for: $0, rateLimited: rateLimited) } ?? .normal
        let exhausted = window != nil && level == .exhausted

        if let window, level != .normal, warnedResetsAt != window.resetsAt {
            warnedResetsAt = window.resetsAt
            result.append(.sessionNearLimit(resetsAt: window.resetsAt))
        }
        if wasExhausted && !exhausted {
            result.append(.sessionBackAfterReset)
        }
        wasExhausted = exhausted
        return result
    }
}
