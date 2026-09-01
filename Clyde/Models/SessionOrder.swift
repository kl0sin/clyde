import Foundation

/// The order sessions appear in, in every window that lists them.
///
/// The two panels used to disagree: compact ranked by state, the full
/// panel showed whatever order the user had dragged rows into. The same
/// four sessions read top-to-bottom differently depending on which
/// window you had open, which makes the two modes two applications.
///
/// State decides the group, the user's own order decides the rest. A
/// session waiting on an answer is the only one that requires
/// something, so it comes first; a working session is worth glancing
/// at; everything else follows. Inside a group the manual order is left
/// exactly as it is — dragging still means something, it just cannot
/// move a row out of its state.
enum SessionOrder {

    static func rank(_ session: Session) -> Int {
        if session.needsAttention { return 0 }
        return session.isWorking ? 1 : 2
    }

    /// Sorted by rank, stable within a rank.
    ///
    /// `sorted(by:)` makes no stability guarantee, and an unstable sort
    /// here would shuffle rows of the same state on every recompute —
    /// a list that reorders itself while you read it.
    static func ranked(_ sessions: [Session]) -> [Session] {
        sessions.enumerated()
            .sorted { lhs, rhs in
                let l = rank(lhs.element), r = rank(rhs.element)
                if l != r { return l < r }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    /// The `#1` / `#2` suffix a row wears when two sessions would
    /// otherwise show the same name, keyed by session.
    ///
    /// The full panel has done this since the beginning and compact
    /// never did — so two sessions called `clyde` were one row twice,
    /// with nothing on either to tell you which was which. That is the
    /// same complaint as the two identically named agents; a window
    /// that lists things has to let you tell them apart.
    static func disambiguationSuffixes(for sessions: [Session]) -> [UUID: String] {
        var counts: [String: Int] = [:]
        for session in sessions {
            counts[session.displayName, default: 0] += 1
        }

        var seen: [String: Int] = [:]
        var suffixes: [UUID: String] = [:]
        for session in sessions where (counts[session.displayName] ?? 0) > 1 {
            let next = (seen[session.displayName] ?? 0) + 1
            seen[session.displayName] = next
            suffixes[session.id] = "#\(next)"
        }
        return suffixes
    }
}
