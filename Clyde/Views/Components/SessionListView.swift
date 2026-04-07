import SwiftUI

// MARK: - Session List

struct SessionListView: View {
    let sessions: [Session]
    let onRename: (UUID, String) -> Void
    let onFocus: (Session) -> Void
    let onReset: (Session) -> Void
    let notificationService: NotificationService?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(disambiguated, id: \.session.pid) { item in
                    SessionRow(
                        session: item.session,
                        disambiguator: item.suffix,
                        onRename: { name in onRename(item.session.id, name) },
                        onFocus: { onFocus(item.session) },
                        onReset: { onReset(item.session) },
                        notificationService: notificationService
                    )
                    if item.session.pid != sessions.last?.pid {
                        Divider()
                            .background(Color(white: 0.15))
                            .padding(.leading, 52)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    /// Add numbered suffix for sessions sharing the same project name
    private var disambiguated: [(session: Session, suffix: String?)] {
        var counts: [String: Int] = [:]
        var indices: [String: Int] = [:]

        // Count duplicates
        for s in sessions {
            counts[s.displayName, default: 0] += 1
        }

        return sessions.map { session in
            let name = session.displayName
            if (counts[name] ?? 0) > 1 {
                let nextIndex = (indices[name] ?? 0) + 1
                indices[name] = nextIndex
                return (session, "#\(nextIndex)")
            }
            return (session, nil)
        }
    }
}
