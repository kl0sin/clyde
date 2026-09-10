import Foundation

/// Whether the limits are actually arriving — as opposed to merely
/// switched on. The same shape as `PermissionAnsweringStatus`, for the
/// same reason: a switch says what was asked for, not what is happening.
enum UsageLimitsStatus: Equatable {
    case off
    case blocked(String)
    case waiting
    case working(Date)

    static func resolve(enabled: Bool,
                        issue: UsageLimitsInstaller.Issue?,
                        installError: String?,
                        lastSnapshot: Date?) -> UsageLimitsStatus {
        guard enabled else { return .off }
        if let installError { return .blocked(installError) }
        if let issue { return .blocked(issue.message) }
        guard let lastSnapshot else { return .waiting }
        return .working(lastSnapshot)
    }

    var message: String {
        switch self {
        case .off:
            return "Off — the limits are in Claude Code under /usage, as always."
        case .blocked(let reason):
            return "Not working — \(reason)"
        case .waiting:
            return "On, but nothing has arrived yet. The numbers come with the first response of a Claude Code session on a Pro or Max plan."
        case .working(let date):
            return "Working — last update \(Self.relative(date))."
        }
    }

    private static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
