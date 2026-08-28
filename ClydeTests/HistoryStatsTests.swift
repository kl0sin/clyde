import XCTest
@testable import Clyde

final class HistoryStatsTests: XCTestCase {

    private func makeStore() throws -> HistoryStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clyde-stats-\(UUID().uuidString)")
        return try HistoryStore(directory: dir)
    }

    private func event(_ name: String, at seconds: Int, session: String = "s1",
                       project: String = "/repo", tool: String? = nil) -> HistoryEvent {
        HistoryEvent(ts: Date(timeIntervalSince1970: TimeInterval(seconds)), event: name,
                     sessionID: session, project: project, tool: tool, summary: nil)
    }

    private let wholeRange = (from: Date(timeIntervalSince1970: 0),
                              to: Date(timeIntervalSince1970: 10_000))

    func testWorkingTimeIsTheSumOfPromptToStop() throws {
        let store = try makeStore()
        try store.insert([
            event("UserPromptSubmit", at: 100), event("Stop", at: 160),
            event("UserPromptSubmit", at: 300), event("Stop", at: 330),
        ])

        let totals = HistoryStats(store: store).totals(from: wholeRange.from, to: wholeRange.to)

        XCTAssertEqual(totals.workingSeconds, 90)
        XCTAssertEqual(totals.turns, 2)
    }

    func testWaitingTimeIsTheGapBetweenStopAndTheNextPrompt() throws {
        let store = try makeStore()
        try store.insert([
            event("UserPromptSubmit", at: 100), event("Stop", at: 160),
            event("UserPromptSubmit", at: 300), event("Stop", at: 330),
        ])

        let totals = HistoryStats(store: store).totals(from: wholeRange.from, to: wholeRange.to)

        XCTAssertEqual(totals.waitingSeconds, 140)
    }

    /// A turn still running when the window is opened must contribute
    /// nothing, or simply refreshing the view would grow yesterday's total.
    func testUnfinishedTurnContributesNoWorkingTime() throws {
        let store = try makeStore()
        try store.insert([event("UserPromptSubmit", at: 100)])

        let totals = HistoryStats(store: store).totals(from: wholeRange.from, to: wholeRange.to)

        XCTAssertEqual(totals.workingSeconds, 0)
        XCTAssertEqual(totals.turns, 1)
    }

    /// An interrupted turn followed by a fresh prompt leaves two
    /// `UserPromptSubmit` events in a row. Pairing them would bill the time
    /// the human spent typing as time Claude spent working.
    func testTwoPromptsInARowAreNotCountedAsWorkingTime() throws {
        let store = try makeStore()
        try store.insert([
            event("UserPromptSubmit", at: 100),
            event("UserPromptSubmit", at: 400),
            event("Stop", at: 430),
        ])

        let totals = HistoryStats(store: store).totals(from: wholeRange.from, to: wholeRange.to)

        XCTAssertEqual(totals.workingSeconds, 30)
        XCTAssertEqual(totals.turns, 2)
    }

    /// Two sessions interleaved in time must not pair across each other.
    func testTurnsArePairedWithinASessionNotAcrossSessions() throws {
        let store = try makeStore()
        try store.insert([
            event("UserPromptSubmit", at: 100, session: "a"),
            event("UserPromptSubmit", at: 110, session: "b"),
            event("Stop", at: 200, session: "a"),
            event("Stop", at: 210, session: "b"),
        ])

        let totals = HistoryStats(store: store).totals(from: wholeRange.from, to: wholeRange.to)

        XCTAssertEqual(totals.workingSeconds, 200)
        XCTAssertEqual(totals.sessions, 2)
    }

    func testProjectRowsSplitTimeAndNameTheTopTool() throws {
        let store = try makeStore()
        try store.insert([
            event("UserPromptSubmit", at: 100, project: "/a"), event("Stop", at: 160, project: "/a"),
            event("PreToolUse", at: 120, project: "/a", tool: "Bash"),
            event("PreToolUse", at: 130, project: "/a", tool: "Bash"),
            event("PreToolUse", at: 140, project: "/a", tool: "Read"),
            event("UserPromptSubmit", at: 400, session: "s2", project: "/b"),
            event("Stop", at: 410, session: "s2", project: "/b"),
        ])

        let rows = HistoryStats(store: store).projects(from: wholeRange.from, to: wholeRange.to)

        XCTAssertEqual(rows.map(\.project), ["/a", "/b"], "busiest project first")
        XCTAssertEqual(rows[0].workingSeconds, 60)
        XCTAssertEqual(rows[0].turns, 1)
        XCTAssertEqual(rows[0].topTool, "Bash")
        XCTAssertEqual(rows[1].workingSeconds, 10)
        XCTAssertEqual(rows[1].turns, 1)
    }

    /// `ProjectRow.turns` must count every `UserPromptSubmit`, matching
    /// `PeriodTotals.turns`, not just completed prompt/Stop pairs — otherwise
    /// a project with an in-flight turn is invisible in the per-project view
    /// even though it already shows up in the headline turn count.
    func testProjectWithUnfinishedTurnStillAppearsWithZeroWorkingTime() throws {
        let store = try makeStore()
        try store.insert([
            event("UserPromptSubmit", at: 100, project: "/a"), event("Stop", at: 160, project: "/a"),
            event("UserPromptSubmit", at: 200, session: "s2", project: "/b"),
        ])

        let rows = HistoryStats(store: store).projects(from: wholeRange.from, to: wholeRange.to)

        XCTAssertEqual(rows.map(\.project), ["/a", "/b"])
        XCTAssertEqual(rows[0].workingSeconds, 60)
        XCTAssertEqual(rows[0].turns, 1)
        XCTAssertEqual(rows[1].workingSeconds, 0)
        XCTAssertEqual(rows[1].turns, 1)
    }

    /// The range filter runs before turns are paired, so a turn whose prompt
    /// falls before the window and whose Stop falls inside it is missing its
    /// start and must not be credited — pinning the deliberate boundary
    /// behaviour documented on the range filter in HistoryStats.
    func testTurnStraddlingWindowStartContributesNoWorkingTime() throws {
        let store = try makeStore()
        try store.insert([
            event("UserPromptSubmit", at: 500),
            event("Stop", at: 1500),
        ])

        let totals = HistoryStats(store: store)
            .totals(from: Date(timeIntervalSince1970: 1000), to: Date(timeIntervalSince1970: 10_000))

        XCTAssertEqual(totals.workingSeconds, 0)
    }

    func testRangeExcludesEventsOutsideIt() throws {
        let store = try makeStore()
        try store.insert([
            event("UserPromptSubmit", at: 100), event("Stop", at: 160),
            event("UserPromptSubmit", at: 5000), event("Stop", at: 5100),
        ])

        let totals = HistoryStats(store: store)
            .totals(from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 1000))

        XCTAssertEqual(totals.turns, 1)
        XCTAssertEqual(totals.workingSeconds, 60)
    }
}
