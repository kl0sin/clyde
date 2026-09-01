import XCTest
import SwiftUI
@testable import Clyde

/// The status indicator: a grid of pixels with light crossing it on the
/// diagonal, one object in three states. A coloured dot says which
/// state a session is in and nothing about whether anything is
/// happening; across a column of rows, motion is what separates working
/// from waiting.
@MainActor
final class PixelStatusIndicatorTests: XCTestCase {

    private func session(status: SessionStatus = .idle,
                         attention: Bool = false,
                         agents: [ActiveSubagent] = []) -> Session {
        var s = Session(pid: 1, workingDirectory: "/repo", status: status)
        s.needsAttention = attention
        s.activeSubagents = agents
        return s
    }

    private var cells: [(row: Int, col: Int)] {
        (0..<PixelStatusIndicator.columns).flatMap { row in
            (0..<PixelStatusIndicator.columns).map { (row: row, col: $0) }
        }
    }

    // MARK: - Which state a session is in

    func testABusySessionIsWorking() {
        XCTAssertEqual(PixelStatusIndicator.state(for: session(status: .busy)), .working)
    }

    func testAnIdleSessionIsIdle() {
        XCTAssertEqual(PixelStatusIndicator.state(for: session()), .idle)
    }

    /// A session waiting on an answer is not merely busy, and in
    /// compact mode the row is the only place that says so.
    func testAttentionOutranksWork() {
        XCTAssertEqual(PixelStatusIndicator.state(for: session(status: .busy, attention: true)),
                       .needsAttention)
    }

    func testASessionWhoseAgentsAreWorkingIsWorking() {
        let agent = ActiveSubagent(id: "a1", type: "explorer", summary: "", startedAt: Date())
        XCTAssertEqual(PixelStatusIndicator.state(for: session(agents: [agent])), .working)
    }

    // MARK: - What moves

    func testOnlyWorkAnimates() {
        XCTAssertTrue(PixelStatusIndicator.animates(.working))
        XCTAssertFalse(PixelStatusIndicator.animates(.idle))
    }

    /// Attention holds still on purpose: an indicator that keeps
    /// flashing until you act is the pattern everybody mutes.
    func testAttentionHoldsStill() {
        XCTAssertFalse(PixelStatusIndicator.animates(.needsAttention))
    }

    /// This window is meant to stay open beside the work, so the cycle
    /// stays under one hertz.
    func testTheCycleIsSlowEnoughToLiveWith() {
        XCTAssertGreaterThan(PixelStatusIndicator.cycle, 1.0)
    }

    // MARK: - Colour and rest

    func testEachStateKeepsTheColourItAlreadyHasElsewhere() {
        XCTAssertEqual(PixelStatusIndicator.color(for: .working), SessionTheme.processingColor)
        XCTAssertEqual(PixelStatusIndicator.color(for: .idle), SessionTheme.readyColor)
        XCTAssertEqual(PixelStatusIndicator.color(for: .needsAttention), SessionTheme.attentionColor)
    }

    /// The states read apart with the colour removed.
    func testRestingBrightnessSeparatesTheStates() {
        let idle = PixelStatusIndicator.restingOpacity(.idle)
        let attention = PixelStatusIndicator.restingOpacity(.needsAttention)
        let working = PixelStatusIndicator.restingOpacity(.working)

        XCTAssertLessThan(working, idle)
        XCTAssertLessThan(idle, attention)
    }

    /// Low enough that the crest is unmistakable, high enough that the
    /// grid never stops being a grid.
    func testAWorkingCellNeverGoesFullyDark() {
        XCTAssertGreaterThan(PixelStatusIndicator.restingOpacity(.working), 0.15)
    }

    // MARK: - The wave, as a function of time

    /// Driven by a clock rather than by `.repeatForever` in `onAppear`:
    /// `SessionStatusIndicator` carries a note that the latter is
    /// unreliable for rows that have just appeared, which is every row
    /// in a panel that was closed a second ago.

    /// Light travels the diagonal, so a cell's place in the queue is
    /// row + column: the two cells either side of the main diagonal
    /// light together, and the corners never do.
    func testCellsOnTheSameDiagonalLightTogether() {
        let time = 0.37
        XCTAssertEqual(PixelStatusIndicator.brightness(row: 0, col: 3, at: time),
                       PixelStatusIndicator.brightness(row: 3, col: 0, at: time),
                       accuracy: 0.0001)
        XCTAssertNotEqual(PixelStatusIndicator.brightness(row: 0, col: 0, at: time),
                          PixelStatusIndicator.brightness(row: 3, col: 3, at: time),
                          accuracy: 0.05)
    }

    /// The crest reaches each diagonal one step after the last —
    /// which is what makes the light travel rather than pulse. One step
    /// is one cell's worth of the wave.
    func testTheWaveCrossesTheGridOneDiagonalAtATime() {
        let step = PixelStatusIndicator.cycle / PixelStatusIndicator.wavelength

        for diagonal in 0..<3 {
            let here = peakTime(row: 0, col: diagonal)
            let next = peakTime(row: 0, col: diagonal + 1)
            XCTAssertEqual(next - here, step, accuracy: 0.01,
                           "diagonal \(diagonal) does not hand over one step later")
        }
    }

    private func peakTime(row: Int, col: Int) -> Double {
        stride(from: 0.0, to: PixelStatusIndicator.cycle, by: 0.005)
            .max(by: { PixelStatusIndicator.brightness(row: row, col: col, at: $0)
                     < PixelStatusIndicator.brightness(row: row, col: col, at: $1) })!
    }

    /// The complaint that produced this shape: the earlier drafts moved
    /// in steps. Brightness must not jump between two frames the view
    /// actually draws — measured at the rate it actually draws them.
    func testNoCellEverJumps() {
        let frame = PixelStatusIndicator.frameInterval

        for cell in cells {
            for tick in stride(from: 0.0, to: PixelStatusIndicator.cycle * 2, by: frame) {
                let now = PixelStatusIndicator.brightness(row: cell.row, col: cell.col, at: tick)
                let next = PixelStatusIndicator.brightness(row: cell.row, col: cell.col, at: tick + frame)
                XCTAssertLessThan(abs(next - now), 0.08,
                                  "cell (\(cell.row),\(cell.col)) jumped at t=\(tick)")
            }
        }
    }

    /// No lap and no handover: the wave is one continuous function, so
    /// there is no instant where it visibly starts again.
    func testTheWaveIsPeriodicWithNoSeam() {
        for cell in cells {
            let now = PixelStatusIndicator.brightness(row: cell.row, col: cell.col, at: 0.37)
            let later = PixelStatusIndicator.brightness(row: cell.row, col: cell.col,
                                                        at: 0.37 + PixelStatusIndicator.cycle)
            XCTAssertEqual(now, later, accuracy: 0.0001)
        }
    }

    /// At every instant something is lit — otherwise the grid blinks
    /// off between laps, which is the pause that got rejected.
    func testSomethingIsAlwaysLit() {
        for tick in stride(from: 0.0, to: PixelStatusIndicator.cycle, by: 0.02) {
            let brightest = cells.map {
                PixelStatusIndicator.brightness(row: $0.row, col: $0.col, at: tick)
            }.max()!
            XCTAssertGreaterThan(brightest, 0.8, "the wave went dark at t=\(tick)")
        }
    }

    /// The grid's longest diagonal is seven cells; a wavelength of
    /// eight keeps the crest always mid-travel.
    func testTheWaveIsLongerThanTheGrid() {
        let longestDiagonal = Double((PixelStatusIndicator.columns - 1) * 2)
        XCTAssertGreaterThan(PixelStatusIndicator.wavelength, longestDiagonal)
    }

    func testOpacityStaysBetweenRestingAndFull() {
        for tick in stride(from: 0.0, to: PixelStatusIndicator.cycle, by: 0.05) {
            let opacity = PixelStatusIndicator.opacity(row: 1, col: 2, at: tick, state: .working)
            XCTAssertGreaterThanOrEqual(opacity, PixelStatusIndicator.restingOpacity(.working) - 0.001)
            XCTAssertLessThanOrEqual(opacity, 1.001)
        }
    }

    /// A state that does not animate ignores the clock entirely.
    func testAStillStateIgnoresTheClock() {
        XCTAssertEqual(PixelStatusIndicator.opacity(row: 0, col: 0, at: 0.9, state: .needsAttention), 1.0)
        XCTAssertEqual(PixelStatusIndicator.opacity(row: 3, col: 1, at: 0.4, state: .idle),
                       PixelStatusIndicator.restingOpacity(.idle))
    }

    // MARK: - One mark at two sizes

    /// The compact slot is 24 points and the full panel's is 34. Both
    /// derive from the slot, so the mark cannot drift into two dialects
    /// the way it did when each mode was tuned by hand.
    func testTheMarkIsTheSameShapeInBothModes() {
        let compact = PixelStatusIndicator.metrics(slot: 24)
        let full = PixelStatusIndicator.metrics(slot: 34)

        XCTAssertEqual(compact.pixel / compact.spacing,
                       full.pixel / full.spacing,
                       accuracy: 0.0001)
        XCTAssertEqual(compact.span / 24, full.span / 34, accuracy: 0.0001)
    }

    /// And it leaves room to breathe inside the slot rather than
    /// filling it corner to corner.
    func testTheMarkSitsInsideItsSlot() {
        for slot in [CGFloat(24), 34] {
            let span = PixelStatusIndicator.metrics(slot: slot).span
            XCTAssertGreaterThan(span, slot * 0.4)
            XCTAssertLessThan(span, slot * 0.55)
        }
    }

}
