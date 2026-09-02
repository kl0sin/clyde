import Foundation

/// Whether answering permission requests from the panel is actually
/// working — as opposed to merely switched on.
///
/// A switch says what was asked for, not what is happening. With
/// answering on, a Clyde whose hook is missing and a Clyde nobody has
/// asked anything both sit silent, and the user has no way to tell the
/// broken one from the quiet one. This is that difference, named.
enum PermissionAnsweringStatus: Equatable {
    /// Off by choice. Questions go where they always did.
    case off
    /// On, but the hook cannot deliver a question.
    case blocked
    /// On and healthy, and no question has ever arrived. Usually the
    /// sessions simply never ask.
    case waiting
    /// On, and a question has come through — with when.
    case working(Date)

    static func resolve(enabled: Bool,
                        hookIssue: HookInstaller.HealthIssue?,
                        lastSeen: Date?) -> PermissionAnsweringStatus {
        // A hook problem the user is not relying on is not their
        // problem: off is off, and reporting a fault there would be
        // noise about a feature they declined.
        guard enabled else { return .off }
        if hookIssue != nil { return .blocked }
        guard let lastSeen else { return .waiting }
        return .working(lastSeen)
    }

    var message: String {
        switch self {
        case .off:
            return "Off — permission questions are asked in the terminal, as they always were."
        case .blocked:
            return "Not working — Clyde's hook is not installed or not running, so no question can reach the panel."
        case .waiting:
            return "On, but no question has arrived yet. Claude only asks when a session runs in a mode that requires it — try `claude --permission-mode manual`."
        case .working(let date):
            return "Working — last question \(Self.relative(date))."
        }
    }

    /// Formatted here rather than in the view so the phrasing is
    /// covered by the same tests as the states.
    private static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
