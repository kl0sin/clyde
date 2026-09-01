import XCTest
@testable import Clyde

/// One order, shared by every window that lists sessions. The two
/// panels used to disagree, which made the same four sessions read
/// differently depending on which one you had open.
@MainActor
final class SessionOrderTests: XCTestCase {

    private func session(_ name: String,
                         status: SessionStatus = .idle,
                         attention: Bool = false) -> Session {
        var s = Session(pid: pid_t(abs(name.hashValue % 30000) + 1),
                        workingDirectory: "/repo/\(name)",
                        status: status)
        s.customName = name
        s.needsAttention = attention
        return s
    }

    func testStateDecidesTheGroup() {
        let ordered = SessionOrder.ranked([
            session("idle"),
            session("working", status: .busy),
            session("asking", attention: true)
        ])

        XCTAssertEqual(ordered.map(\.displayName), ["asking", "working", "idle"])
    }

    /// Attention outranks work: a busy session that is also waiting on
    /// an answer belongs at the top, not in the middle.
    func testAttentionOutranksWork() {
        XCTAssertEqual(SessionOrder.rank(session("a", status: .busy, attention: true)), 0)
        XCTAssertEqual(SessionOrder.rank(session("b", status: .busy)), 1)
        XCTAssertEqual(SessionOrder.rank(session("c")), 2)
    }

    /// Inside a group nothing moves. `sorted(by:)` guarantees no
    /// stability, and an unstable sort here would reshuffle rows of the
    /// same state on every recompute — a list that reorders itself
    /// while you read it.
    func testTheOrderInsideAGroupIsLeftAlone() {
        let names = (0..<12).map { "s\($0)" }
        let ordered = SessionOrder.ranked(names.map { session($0) })

        XCTAssertEqual(ordered.map(\.displayName), names)
    }

    func testRankingTwiceChangesNothing() {
        let once = SessionOrder.ranked([
            session("idle"), session("working", status: .busy),
            session("idle2"), session("asking", attention: true)
        ])

        XCTAssertEqual(SessionOrder.ranked(once).map(\.displayName), once.map(\.displayName))
    }
}
