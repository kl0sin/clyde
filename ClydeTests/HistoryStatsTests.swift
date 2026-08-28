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

    // MARK: - Activity trail

    /// The trail answers "what did Claude actually do", so it carries the
    /// tool calls and drops the bookkeeping: PostToolUse and PostToolBatch
    /// mirror every PreToolUse, and listing all three would treat one
    /// action as three lines of history.
    func testTrailListsToolCallsNewestFirstAndSkipsTheirEchoes() throws {
        let store = try makeStore()
        try store.insert([
            event("PreToolUse", at: 100, tool: "Read"),
            event("PostToolUse", at: 101, tool: "Read"),
            event("PostToolBatch", at: 102, tool: "Read"),
            event("PreToolUse", at: 200, tool: "Bash"),
            event("PostToolUse", at: 201, tool: "Bash"),
        ])

        let trail = HistoryStats(store: store).trail(from: wholeRange.from, to: wholeRange.to, limit: 10)

        XCTAssertEqual(trail.map(\.tool), ["Bash", "Read"])
    }

    func testTrailHonoursItsLimit() throws {
        let store = try makeStore()
        try store.insert((1...30).map { event("PreToolUse", at: $0 * 10, tool: "Bash") })

        XCTAssertEqual(HistoryStats(store: store)
            .trail(from: wholeRange.from, to: wholeRange.to, limit: 12).count, 12)
    }

    /// Clicking a project narrows the trail to it — the same filter the
    /// spec asked for, and the reason the trail is worth having next to
    /// the project table rather than on its own.
    func testTrailFiltersByProject() throws {
        let store = try makeStore()
        try store.insert([
            event("PreToolUse", at: 100, project: "/repos/a", tool: "Read"),
            event("PreToolUse", at: 200, project: "/repos/b", tool: "Bash"),
        ])

        let trail = HistoryStats(store: store)
            .trail(from: wholeRange.from, to: wholeRange.to, project: "/repos/a", limit: 10)

        XCTAssertEqual(trail.count, 1)
        XCTAssertEqual(trail.first?.tool, "Read")
    }

    /// Subagent dispatches belong in the trail: "Claude fanned out to three
    /// agents" is exactly the kind of thing this view exists to show.
    func testTrailIncludesSubagentDispatches() throws {
        let store = try makeStore()
        try store.insert([
            event("SubagentStart", at: 100, tool: nil),
            event("PreToolUse", at: 200, tool: "Bash"),
        ])

        let trail = HistoryStats(store: store).trail(from: wholeRange.from, to: wholeRange.to, limit: 10)

        XCTAssertEqual(trail.map(\.event), ["PreToolUse", "SubagentStart"])
    }

    // MARK: - Daily activity (the heatmap's data)

    /// Buckets are local-time days, because the grid a person reads is
    /// their calendar, not UTC. Built from the same turn pairing as the
    /// totals so a day's minutes always add up to the period's minutes.
    func testDailyActivitySplitsWorkAcrossLocalDays() throws {
        let store = try makeStore()
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let yesterday = cal.date(byAdding: .day, value: -1, to: today)!
        func at(_ day: Date, _ hour: Int, _ minute: Int = 0) -> Int {
            Int(cal.date(bySettingHour: hour, minute: minute, second: 0, of: day)!.timeIntervalSince1970)
        }
        try store.insert([
            event("UserPromptSubmit", at: at(yesterday, 10)),
            event("Stop", at: at(yesterday, 10, 5)),
            event("UserPromptSubmit", at: at(today, 9)),
            event("Stop", at: at(today, 9, 2)),
            event("UserPromptSubmit", at: at(today, 14)),
            event("Stop", at: at(today, 14, 3)),
        ])

        let days = HistoryStats(store: store).dailyActivity(
            from: cal.date(byAdding: .day, value: -7, to: today)!,
            to: cal.date(byAdding: .day, value: 1, to: today)!)

        XCTAssertEqual(days.count, 2)
        XCTAssertEqual(days.first?.day, yesterday)
        XCTAssertEqual(days.first?.workingSeconds, 300)
        XCTAssertEqual(days.first?.turns, 1)
        XCTAssertEqual(days.last?.day, today)
        XCTAssertEqual(days.last?.workingSeconds, 300)
        XCTAssertEqual(days.last?.turns, 2)
    }

    /// A day whose turn never finished still counts as a day you worked —
    /// it has a turn — but contributes no minutes, matching the totals.
    func testDailyActivityCountsAnUnfinishedTurnWithoutMinutes() throws {
        let store = try makeStore()
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let ts = Int(cal.date(bySettingHour: 11, minute: 0, second: 0, of: today)!.timeIntervalSince1970)
        try store.insert([event("UserPromptSubmit", at: ts)])

        let days = HistoryStats(store: store).dailyActivity(
            from: cal.date(byAdding: .day, value: -7, to: today)!,
            to: cal.date(byAdding: .day, value: 1, to: today)!)

        XCTAssertEqual(days.count, 1)
        XCTAssertEqual(days.first?.workingSeconds, 0)
        XCTAssertEqual(days.first?.turns, 1)
    }

    /// The tooltip needs something to say beyond minutes: which project a
    /// day went to is the first question anyone asks of a busy square.
    func testDailyActivityNamesTheBusiestProjectOfTheDay() throws {
        let store = try makeStore()
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        func at(_ hour: Int, _ minute: Int = 0) -> Int {
            Int(cal.date(bySettingHour: hour, minute: minute, second: 0, of: today)!.timeIntervalSince1970)
        }
        try store.insert([
            event("UserPromptSubmit", at: at(9), session: "s1", project: "/repos/small"),
            event("Stop", at: at(9, 2), session: "s1", project: "/repos/small"),
            event("UserPromptSubmit", at: at(10), session: "s2", project: "/repos/big"),
            event("Stop", at: at(10, 30), session: "s2", project: "/repos/big"),
        ])

        let days = HistoryStats(store: store).dailyActivity(
            from: cal.date(byAdding: .day, value: -1, to: today)!,
            to: cal.date(byAdding: .day, value: 1, to: today)!)

        XCTAssertEqual(days.first?.topProject, "/repos/big")
    }

    func testDailyActivityIsEmptyWithoutEvents() throws {
        let store = try makeStore()

        XCTAssertTrue(HistoryStats(store: store)
            .dailyActivity(from: wholeRange.from, to: wholeRange.to).isEmpty)
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
