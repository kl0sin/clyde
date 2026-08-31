import XCTest
import SwiftUI
@testable import Clyde

/// The status indicator: four pixels from the mascot's world, one
/// object in three states. A coloured dot says which state a session is
/// in and nothing about whether anything is happening; across a column
/// of rows, motion is what separates working from waiting.
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

    // MARK: - Which state a session is in

    func testABusySessionIsWorking() {
        XCTAssertEqual(PixelStatusIndicator.state(for: session(status: .busy)), .working)
    }

    func testAnIdleSessionIsIdle() {
        XCTAssertEqual(PixelStatusIndicator.state(for: session()), .idle)
    }

    /// Attention outranks everything: a session that wants an answer is
    /// not merely busy, and the row is the only place that says so once
    /// the panel is compact.
    func testAttentionOutranksWorking() {
        XCTAssertEqual(PixelStatusIndicator.state(for: session(status: .busy, attention: true)),
                       .needsAttention)
    }

    /// The agent-aware busy rule reaches the indicator too — a session
    /// whose turn ended while a subagent runs on is still working.
    func testASessionWithRunningAgentsIsWorking() {
        let agent = ActiveSubagent(id: "a", type: "general-purpose", summary: "", startedAt: Date())
        XCTAssertEqual(PixelStatusIndicator.state(for: session(agents: [agent])), .working)
    }

    // MARK: - Motion

    func testOnlyWorkingAnimates() {
        XCTAssertTrue(PixelStatusIndicator.animates(.working))
        XCTAssertFalse(PixelStatusIndicator.animates(.idle))
    }

    /// Attention is noticed once and then stays legible. An indicator
    /// that flashes until you act is the pattern everybody mutes.
    func testAttentionDoesNotAnimateForever() {
        XCTAssertFalse(PixelStatusIndicator.animates(.needsAttention))
        XCTAssertEqual(PixelStatusIndicator.arrivalPulses, 3)
    }

    /// The fourth pixel has to hand off to the first with no gap, so the
    /// cycle is exactly four delay steps long.
    func testTheWaveLoopsWithoutAPause() {
        XCTAssertEqual(PixelStatusIndicator.cycle,
                       PixelStatusIndicator.delayStep * 3,
                       accuracy: 0.0001)
    }

    /// Slow enough to be ambient, in a window meant to stay open.
    func testTheCycleStaysUnderOneHertz() {
        XCTAssertGreaterThan(PixelStatusIndicator.cycle, 1.0)
    }

    func testEachCellStartsOneStepAfterTheLast() {
        for index in 0..<3 {
            XCTAssertEqual(PixelStatusIndicator.delay(forPixel: index),
                           Double(index) * PixelStatusIndicator.delayStep,
                           accuracy: 0.0001)
        }
        XCTAssertEqual(PixelStatusIndicator.delay(forPixel: 2) + PixelStatusIndicator.delayStep,
                       PixelStatusIndicator.cycle,
                       accuracy: 0.0001,
                       "the last pixel's step ends where the cycle restarts")
    }

    // MARK: - Colour and shape

    func testEachStateTakesItsColourFromTheTheme() {
        XCTAssertEqual(PixelStatusIndicator.color(for: .working), SessionTheme.processingColor)
        XCTAssertEqual(PixelStatusIndicator.color(for: .idle), SessionTheme.readyColor)
        XCTAssertEqual(PixelStatusIndicator.color(for: .needsAttention), SessionTheme.attentionColor)
    }

    /// Colour is a confirmation, not the carrier: filled, travelling and
    /// at rest have to be distinguishable with the colour removed.
    func testTheStatesDifferByFillAsWellAsColour() {
        let idle = PixelStatusIndicator.restingOpacity(.idle)
        let attention = PixelStatusIndicator.restingOpacity(.needsAttention)
        let working = PixelStatusIndicator.restingOpacity(.working)
        XCTAssertEqual(attention, 1.0, "needing you is the filled square")
        XCTAssertLessThan(idle, attention)
        XCTAssertLessThan(working, attention)
    }

    // MARK: - The wave, as a function of time

    /// Driven by a clock rather than by `.repeatForever` in `onAppear`:
    /// `SessionStatusIndicator` carries a note that the latter is
    /// unreliable for rows that have just appeared, which is every row
    /// in a panel that was closed a second ago.

    /// Each bar peaks a step after the last, so the three read as one
    /// movement rather than three blinks.
    func testTheBarsPeakInTurn() {
        let step = PixelStatusIndicator.delayStep

        for index in 0..<3 {
            XCTAssertEqual(PixelStatusIndicator.brightness(pixel: index,
                                                           at: Double(index) * step),
                           1.0, accuracy: 0.01)
        }
    }

    /// Shape carries the state: moving and uneven, flat, or all raised.
    func testTheBarsSayTheStateWithoutColour() {
        XCTAssertEqual(PixelStatusIndicator.height(bar: 0, at: 0, state: .needsAttention), 1)
        XCTAssertLessThan(PixelStatusIndicator.height(bar: 0, at: 0, state: .idle), 0.5)
        // 0.2s happens to fall where two bars cross; 0.1 does not.
        XCTAssertNotEqual(PixelStatusIndicator.height(bar: 0, at: 0.1, state: .working),
                          PixelStatusIndicator.height(bar: 1, at: 0.1, state: .working))
    }

    /// Four cells, four distinct moments, one cycle — no two lighting
    /// together and none left out.
    func testEveryCellGetsItsOwnMoment() {
        let peaks = (0..<3).map { index -> Double in
            stride(from: 0.0, to: PixelStatusIndicator.cycle, by: 0.01)
                .max(by: { PixelStatusIndicator.brightness(pixel: index, at: $0)
                         < PixelStatusIndicator.brightness(pixel: index, at: $1) })!
        }
        let rounded = Set(peaks.map { (($0 / PixelStatusIndicator.delayStep).rounded()) })
        XCTAssertEqual(rounded.count, 3, "each bar peaks on a different step")
    }

    func testAPixelIsDimmestHalfACycleFromItsPeak() {
        let trough = PixelStatusIndicator.brightness(pixel: 0, at: PixelStatusIndicator.cycle / 2)
        XCTAssertEqual(trough, 0.0, accuracy: 0.01)
    }

    /// The wave repeats: the same instant one cycle later looks the same.
    func testTheWaveIsPeriodic() {
        let now = PixelStatusIndicator.brightness(pixel: 2, at: 0.37)
        let later = PixelStatusIndicator.brightness(pixel: 2, at: 0.37 + PixelStatusIndicator.cycle)
        XCTAssertEqual(now, later, accuracy: 0.0001)
    }

    /// At every instant something is lit — otherwise the row blinks off
    /// between laps, which is the pause that got rejected in the mockup.
    func testSomethingIsAlwaysLit() {
        for tick in stride(from: 0.0, to: PixelStatusIndicator.cycle, by: 0.05) {
            let brightest = (0..<3).map { PixelStatusIndicator.brightness(pixel: $0, at: tick) }.max()!
            XCTAssertGreaterThan(brightest, 0.3, "the wave went dark at t=\(tick)")
        }
    }

    func testOpacityStaysBetweenRestingAndFull() {
        for tick in stride(from: 0.0, to: PixelStatusIndicator.cycle, by: 0.05) {
            let opacity = PixelStatusIndicator.opacity(pixel: 1, at: tick, state: .working)
            XCTAssertGreaterThanOrEqual(opacity, PixelStatusIndicator.restingOpacity(.working) - 0.001)
            XCTAssertLessThanOrEqual(opacity, 1.001)
        }
    }

    /// A state that does not animate ignores the clock entirely.
    func testAStillStateIgnoresTheClock() {
        XCTAssertEqual(PixelStatusIndicator.opacity(pixel: 0, at: 0.9, state: .needsAttention), 1.0)
        XCTAssertEqual(PixelStatusIndicator.opacity(pixel: 3, at: 0.4, state: .idle),
                       PixelStatusIndicator.restingOpacity(.idle))
    }

}
