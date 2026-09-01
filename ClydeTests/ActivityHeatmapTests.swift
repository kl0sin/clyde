import XCTest
@testable import Clyde

/// The heatmap's arithmetic, which is the part that can be wrong without
/// looking wrong: a grid that silently starts on the wrong weekday, or an
/// intensity scale that flattens every day into one shade.
final class ActivityHeatmapTests: XCTestCase {

    // MARK: - Intensity levels

    /// Level 0 is reserved for "nothing happened". Any activity at all has
    /// to lift a day off the empty shade, however small — otherwise a day
    /// with one short turn is indistinguishable from a day you did not work
    /// at all, which is the single most misleading thing this grid could do.
    func testAnyActivityIsAtLeastLevelOne() {
        XCTAssertEqual(ActivityHeatmap.level(seconds: 0, max: 3600), 0)
        XCTAssertEqual(ActivityHeatmap.level(seconds: 1, max: 3600), 1)
        XCTAssertEqual(ActivityHeatmap.level(seconds: 30, max: 3600), 1)
    }

    /// The busiest day in the range anchors the top of the scale, so the
    /// grid stays readable for a light user and a heavy one alike.
    func testBusiestDayReachesTheTopLevel() {
        XCTAssertEqual(ActivityHeatmap.level(seconds: 3600, max: 3600), 4)
    }

    func testLevelsSpreadAcrossTheRange() {
        XCTAssertEqual(ActivityHeatmap.level(seconds: 900, max: 3600), 1)
        XCTAssertEqual(ActivityHeatmap.level(seconds: 1800, max: 3600), 2)
        XCTAssertEqual(ActivityHeatmap.level(seconds: 2700, max: 3600), 3)
    }

    /// A range where nothing happened must not divide by zero.
    func testEmptyRangeHasNoLevels() {
        XCTAssertEqual(ActivityHeatmap.level(seconds: 0, max: 0), 0)
    }

    // MARK: - Grid layout

    /// Columns are weeks and rows are weekdays, so the grid has to begin on
    /// a week boundary or every column mixes two weeks and the shape stops
    /// meaning anything.
    func testGridStartsOnTheFirstWeekdayOfItsCalendar() {
        let days = ActivityHeatmap.days(endingOn: Date(), weeks: 12)

        let calendar = Calendar.current
        XCTAssertEqual(calendar.component(.weekday, from: days[0]), calendar.firstWeekday)
    }

    func testGridCoversWholeWeeks() {
        let days = ActivityHeatmap.days(endingOn: Date(), weeks: 12)

        XCTAssertEqual(days.count % 7, 0)
        XCTAssertGreaterThanOrEqual(days.count, 12 * 7)
        XCTAssertLessThanOrEqual(days.count, 13 * 7, "at most one partial week is padded out")
    }

    /// Ambiguity check: the single-letter weekday symbols give "T" for both
    /// Tuesday and Thursday and "S" for both Saturday and Sunday, so the
    /// gutter must use the three-letter ones.
    func testWeekdayGutterLabelsAreUnambiguous() {
        let labels = (0..<7).map { ActivityHeatmap.weekdayLabel(row: $0) }.filter { !$0.isEmpty }

        XCTAssertEqual(labels.count, 4, "every other row carries a label")
        XCTAssertEqual(Set(labels).count, labels.count, "no two rows share a label")
        XCTAssertTrue(labels.allSatisfy { $0.count > 1 }, "single letters cannot name a weekday")
    }

    /// A three-letter label over an eleven-point column collides with its
    /// neighbour unless months are kept apart — the first render printed
    /// "FebMar" where February had a single column in range.
    func testMonthLabelsNeverLandOnAdjacentColumns() {
        let days = ActivityHeatmap.days(endingOn: Date(), weeks: 26)
        let columns = stride(from: 0, to: days.count, by: 7).map { Array(days[$0..<min($0 + 7, days.count)]) }

        let labels = ActivityHeatmap.monthLabels(for: columns)

        let labelled = labels.enumerated().filter { !$0.element.isEmpty }.map(\.offset)
        XCTAssertFalse(labelled.isEmpty, "half a year must name some months")
        for (a, b) in zip(labelled, labelled.dropFirst()) {
            XCTAssertGreaterThanOrEqual(b - a, 3, "labels at columns \(a) and \(b) would overlap")
        }
    }

    /// The hover card is anchored from the layout arithmetic rather than
    /// measured per cell, so it has to be right at whatever size the
    /// grid ended up: each further column and row steps by exactly one
    /// cell plus one gap.
    func testTooltipAnchorsToTheHoveredCell() {
        let days = ActivityHeatmap.days(endingOn: Date(), weeks: 4)
        let columns = stride(from: 0, to: days.count, by: 7).map { Array(days[$0..<min($0 + 7, days.count)]) }

        for cell in [CGFloat(11), 16, 20] {
            let first = ActivityHeatmap.position(of: columns[0][0], in: columns, cell: cell, gap: 3)
            let nextColumn = ActivityHeatmap.position(of: columns[1][0], in: columns, cell: cell, gap: 3)
            let nextRow = ActivityHeatmap.position(of: columns[0][1], in: columns, cell: cell, gap: 3)

            XCTAssertNotNil(first)
            XCTAssertEqual((nextColumn?.x ?? 0) - (first?.x ?? 0), cell + 3, accuracy: 0.01)
            XCTAssertEqual((nextRow?.y ?? 0) - (first?.y ?? 0), cell + 3, accuracy: 0.01)
            XCTAssertEqual(nextRow?.x, first?.x, "same column, same x")
        }
    }

    /// A day outside the grid has no anchor, and asking for one must not
    /// crash or invent a position off-screen.
    func testTooltipHasNoAnchorForADayOutsideTheGrid() {
        let days = ActivityHeatmap.days(endingOn: Date(), weeks: 4)
        let columns = stride(from: 0, to: days.count, by: 7).map { Array(days[$0..<min($0 + 7, days.count)]) }
        let longAgo = Calendar.current.date(byAdding: .year, value: -1, to: Date())!

        XCTAssertNil(ActivityHeatmap.position(of: Calendar.current.startOfDay(for: longAgo), in: columns, cell: 11, gap: 3))
    }

    /// Today has to be in the grid — a calendar that stops yesterday looks
    /// broken the moment you glance at it.
    func testGridIncludesToday() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        let days = ActivityHeatmap.days(endingOn: Date(), weeks: 12)

        XCTAssertTrue(days.contains(today))
        XCTAssertEqual(days.last, calendar.startOfDay(for: days.last ?? Date()))
    }
}

/// The hover card carries the day's figures, so running past the
/// window's edge cuts off the thing it exists to show.
final class HeatmapTooltipClampTests: XCTestCase {

    private let gridWidth: CGFloat = 520
    private var width: CGFloat { 168 }   // ActivityHeatmap.tooltipWidth

    func testItCentresOnTheCellWhenThereIsRoom() {
        let x = ActivityHeatmap.tooltipX(centredOn: 260, gridWidth: gridWidth)

        XCTAssertEqual(x, 260 - width / 2, accuracy: 0.01)
    }

    /// Stops short of the edge rather than against it: flush, it read
    /// as part of the window's frame.
    func testItStopsShortOfTheRightEdge() {
        let x = ActivityHeatmap.tooltipX(centredOn: 515, gridWidth: gridWidth)

        XCTAssertEqual(gridWidth - (x + width), ActivityHeatmap.tooltipEdgeInset, accuracy: 0.01)
    }

    func testItStopsShortOfTheLeftEdge() {
        XCTAssertEqual(ActivityHeatmap.tooltipX(centredOn: 4, gridWidth: gridWidth),
                       ActivityHeatmap.tooltipEdgeInset)
    }

    /// A grid narrower than the card cannot satisfy both edges; it must
    /// pick one rather than going negative.
    func testANarrowGridPinsItToTheLeft() {
        XCTAssertEqual(ActivityHeatmap.tooltipX(centredOn: 40, gridWidth: 100), 0)
    }
}
