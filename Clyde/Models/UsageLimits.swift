import Foundation

/// One of the two rolling windows Claude Code meters a subscription in.
struct UsageWindow: Equatable {
    /// 0–100, as Claude Code reports it. Usage, not headroom.
    let usedPercentage: Double
    let resetsAt: Date
}

/// The two windows, as last reported by a status-line payload.
///
/// Four numbers and a timestamp. The timestamp is part of the data: the
/// status line only re-runs after an API response, so with no session
/// open these values stand still and the UI has to be able to say so.
struct UsageLimits: Equatable {
    let fiveHour: UsageWindow?
    let sevenDay: UsageWindow?
    /// When the snapshot was written — the file's mtime, not a field.
    let updatedAt: Date
    let sessionID: String?
    let modelName: String?

    enum Level: Equatable {
        case normal
        case warning
        case exhausted
    }

    static let warningThreshold: Double = 80
    static let staleAfter: TimeInterval = 30 * 60

    var hasAnyWindow: Bool { fiveHour != nil || sevenDay != nil }

    // MARK: - Parsing

    /// Reads the `rate_limits` object out of a whole status-line payload.
    /// Nil when there is none, or when neither window carries both of
    /// its fields — a half window is not worth drawing.
    static func parse(_ data: Data, modifiedAt: Date) -> UsageLimits? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rateLimits = root["rate_limits"] as? [String: Any] else {
            return nil
        }
        let fiveHour = window(from: rateLimits["five_hour"])
        let sevenDay = window(from: rateLimits["seven_day"])
        guard fiveHour != nil || sevenDay != nil else { return nil }
        let model = root["model"] as? [String: Any]
        return UsageLimits(
            fiveHour: fiveHour,
            sevenDay: sevenDay,
            updatedAt: modifiedAt,
            sessionID: root["session_id"] as? String,
            modelName: model?["display_name"] as? String
        )
    }

    private static func window(from any: Any?) -> UsageWindow? {
        guard let dict = any as? [String: Any],
              let used = number(dict["used_percentage"]),
              let resets = number(dict["resets_at"]) else {
            return nil
        }
        return UsageWindow(usedPercentage: used, resetsAt: Date(timeIntervalSince1970: resets))
    }

    private static func number(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let n = any as? NSNumber { return n.doubleValue }
        return nil
    }

    // MARK: - Rules

    /// Claude Code drops a window from the payload once its reset has
    /// passed. Between payloads this does the same, so a bar never
    /// shows the fill of a window that has already ended.
    func droppingExpiredWindows(now: Date) -> UsageLimits {
        UsageLimits(
            fiveHour: fiveHour.flatMap { $0.resetsAt > now ? $0 : nil },
            sevenDay: sevenDay.flatMap { $0.resetsAt > now ? $0 : nil },
            updatedAt: updatedAt,
            sessionID: sessionID,
            modelName: modelName
        )
    }

    static func level(for window: UsageWindow, rateLimited: Bool) -> Level {
        if rateLimited || window.usedPercentage >= 100 { return .exhausted }
        if window.usedPercentage >= warningThreshold { return .warning }
        return .normal
    }

    /// With a live session the numbers are at most one turn old. Without
    /// one, half an hour is where "current" stops being honest.
    func isStale(now: Date, hasLiveSession: Bool) -> Bool {
        if hasLiveSession { return false }
        return now.timeIntervalSince(updatedAt) >= Self.staleAfter
    }

    // MARK: - Text

    /// "resets in 1h 12m" under a day, "resets Sat 09:00" beyond it,
    /// and "resumes in …" when the window is spent, because the reset
    /// is then the moment work can continue.
    static func resetText(for window: UsageWindow, now: Date, level: Level) -> String {
        let remaining = max(0, window.resetsAt.timeIntervalSince(now))
        let verb = level == .exhausted ? "resumes" : "resets"
        if remaining < 24 * 3600 {
            let minutes = Int(remaining / 60)
            return "\(verb) in \(minutes / 60)h \(minutes % 60)m"
        }
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("EEE HH:mm")
        return "\(verb) \(formatter.string(from: window.resetsAt))"
    }

    static func percentText(for window: UsageWindow, level: Level) -> String {
        level == .exhausted ? "full" : "\(Int(window.usedPercentage.rounded()))%"
    }

    /// The line under the rows: where the numbers came from and how old
    /// they are. Without a live session they stop moving, and this is
    /// what tells the reader that.
    func freshnessText(now: Date, sessionName: String?, stale: Bool) -> String {
        let age = Self.age(now.timeIntervalSince(updatedAt))
        if stale {
            return "As of \(age) ago · refreshes with the next Claude Code turn"
        }
        if let sessionName {
            return "Updated \(age) ago from the \(sessionName) session"
        }
        return "Updated \(age) ago"
    }

    private static func age(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86_400 { return "\(s / 3600)h" }
        return "\(s / 86_400)d"
    }
}
