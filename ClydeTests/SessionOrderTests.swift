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

/// Telling two identically named sessions apart — the full panel has
/// always done it, compact never did.
@MainActor
final class SessionDisambiguationTests: XCTestCase {

    private func session(_ name: String) -> Session {
        var s = Session(pid: pid_t.random(in: 1...30000),
                        workingDirectory: "/repo",
                        status: .idle)
        s.customName = name
        return s
    }

    func testUniqueNamesGetNoSuffix() {
        let sessions = [session("clyde"), session("tally-up")]

        XCTAssertTrue(SessionOrder.disambiguationSuffixes(for: sessions).isEmpty)
    }

    func testRepeatedNamesAreNumberedInOrder() {
        let sessions = [session("clyde"), session("tally-up"), session("clyde")]
        let suffixes = SessionOrder.disambiguationSuffixes(for: sessions)

        XCTAssertEqual(suffixes[sessions[0].id], "#1")
        XCTAssertEqual(suffixes[sessions[2].id], "#2")
        XCTAssertNil(suffixes[sessions[1].id])
    }

    /// The compact row wears it too, in its name — the panel and the
    /// compact window must not label the same session differently.
    func testTheCompactRowShowsTheSuffix() {
        let content = CompactSessionRow.content(for: session("clyde"), disambiguator: "#2")

        XCTAssertEqual(content.name, "clyde #2")
    }
}

/// The mark inside the attention badge. It used to be `Text("!")`,
/// centred by a layout box that reserves room for a descender the glyph
/// does not have — so it sat visibly high inside its circle.
@MainActor
final class AttentionBadgeMarkTests: XCTestCase {

    func testTheMarkFitsInsideTheBadge() {
        XCTAssertLessThan(AttentionBadgeMark.height, 12)
    }

    /// Whole points, and an even total, so the mark centres on the
    /// pixel grid of a 12-point circle rather than on a half point —
    /// which is how it would go soft, or land one pixel off.
    func testTheMarkCentresOnWholePoints() {
        for value in [AttentionBadgeMark.barWidth, AttentionBadgeMark.barHeight,
                      AttentionBadgeMark.gap, AttentionBadgeMark.dot] {
            XCTAssertEqual(value, value.rounded(), "\(value) is not a whole point")
        }
        XCTAssertEqual(AttentionBadgeMark.height.truncatingRemainder(dividingBy: 2), 0)
        XCTAssertEqual((12 - AttentionBadgeMark.height) / 2,
                       ((12 - AttentionBadgeMark.height) / 2).rounded())
    }

    /// It has to read as an exclamation mark: a tall bar over a small
    /// separate dot, not two equal blocks.
    func testItReadsAsAnExclamationMark() {
        XCTAssertGreaterThan(AttentionBadgeMark.barHeight, AttentionBadgeMark.dot)
        XCTAssertGreaterThan(AttentionBadgeMark.gap, 0)
    }
}
