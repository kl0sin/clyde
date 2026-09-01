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

    /// Air on every side, not a mark packed into its disc.
    func testTheMarkHasRoomInsideTheBadge() {
        let margin = (AttentionBadgeMark.badge - AttentionBadgeMark.height) / 2

        XCTAssertGreaterThanOrEqual(margin, 3)
        XCTAssertEqual(margin, margin.rounded(), "the mark centres on a half point")
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
        XCTAssertEqual(AttentionBadgeMark.badge.truncatingRemainder(dividingBy: 2), 0)
    }

    /// It has to read as an exclamation mark: a tall bar over a small
    /// separate dot, not two equal blocks.
    func testItReadsAsAnExclamationMark() {
        XCTAssertGreaterThan(AttentionBadgeMark.barHeight, AttentionBadgeMark.dot)
        XCTAssertGreaterThan(AttentionBadgeMark.gap, 0)
    }
}

/// The surface a row is drawn on. It lived only in the compact card
/// while the full panel used a flat tint, so the same state was a
/// textured card in one window and a block of colour in the other.
@MainActor
final class SessionSurfaceTests: XCTestCase {

    func testAQuietRowHasNoWash() {
        XCTAssertEqual(SessionSurface.washOpacity(for: .idle), 0)
    }

    /// Toned down from what compact ran: at 0.20 the card read as
    /// tinted rather than lit — a card the colour of the state instead
    /// of a card the state is happening on.
    func testTheWashIsLightNotPaint() {
        XCTAssertLessThan(SessionSurface.washOpacity(for: .working), 0.16)
        XCTAssertGreaterThan(SessionSurface.washOpacity(for: .working), 0.08)
    }

    /// A question is worth a shade more than work, and no more.
    func testAttentionIsSlightlyStrongerThanWork() {
        XCTAssertGreaterThan(SessionSurface.washOpacity(for: .needsAttention),
                             SessionSurface.washOpacity(for: .working))
        XCTAssertLessThan(SessionSurface.washOpacity(for: .needsAttention) -
                          SessionSurface.washOpacity(for: .working), 0.05)
    }

    /// Felt rather than seen. Above roughly an eighth the hatching
    /// stops being a texture and becomes stripes on the row.
    func testTheHatchingStaysAtTheThresholdOfVisible() {
        XCTAssertGreaterThan(SessionSurface.ditherOpacity, 0.05)
        XCTAssertLessThan(SessionSurface.ditherOpacity, 0.13)
    }

    /// The badge hangs off the slot's corner rather than resting inside
    /// it — tucked in, it read as something sitting on the grid.
    func testTheBadgeOverhangsTheSlot() {
        let slot: CGFloat = 34
        let outerEdge = AttentionBadgeMark.offset(slot: slot) + AttentionBadgeMark.badge / 2

        XCTAssertEqual(outerEdge - slot / 2, AttentionBadgeMark.overhang, accuracy: 0.001)
        XCTAssertGreaterThan(AttentionBadgeMark.overhang, 0)
    }
}

/// Where the mark sits in a row. Both panels put it the same distance
/// from three of the row's four edges — the fourth is the bottom, which
/// grows when a row carries more than one line.
@MainActor
final class RowInsetTests: XCTestCase {

    /// Left and right match. Top and bottom deliberately do not: a
    /// row's leading edge is the window's margin, shared with the
    /// footer, and a row inset less than its neighbours leaves the
    /// window with a ragged left edge.
    func testTheMarksLeftAndRightMatch() {
        XCTAssertEqual(CompactSessionRow.slotGap, CompactSessionRow.leadingInset)
        XCTAssertGreaterThan(CompactSessionRow.leadingInset, CompactSessionRow.verticalInset)
    }

    /// And the row lines up with the rest of the window rather than
    /// setting its own margin.
    func testTheRowSharesTheWindowsMargin() {
        XCTAssertEqual(CompactSessionRow.leadingInset, Spacing.sm)
    }

    /// Derived rather than written down, so enlarging the slot cannot
    /// leave the vertical inset behind.
    func testTheVerticalInsetFollowsTheSlot() {
        XCTAssertEqual(CompactSessionRow.verticalInset * 2 + CompactSessionRow.slotSize,
                       CompactSessionRow.cardHeight)
    }

    /// Past the slot column, so the line separates the text rather than
    /// cutting the row in two.
    func testTheSeparatorClearsTheSlot() {
        XCTAssertGreaterThan(CompactSessionRow.separatorInset,
                             CompactSessionRow.leadingInset + CompactSessionRow.slotSize)
    }

    /// Faint enough to be a seam rather than a rule.
    func testTheSeparatorIsAHairline() {
        XCTAssertLessThanOrEqual(SessionSurface.separatorHeight, 0.5)
    }
}
