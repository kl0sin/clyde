import XCTest
@testable import Clyde

/// One line per session, 30 points tall. The full panel's row is 44 and
/// spends its second line on a reply preview; compact keeps what says
/// whether to look at a session — its project, where it is working,
/// what is running, and for how long.
@MainActor
final class CompactSessionRowTests: XCTestCase {

    private func session(cwd: String = "/Users/me/work-hub",
                         status: SessionStatus = .idle,
                         attention: Bool = false,
                         worktree: String = "",
                         agents: Int = 0,
                         customName: String? = nil) -> Session {
        var s = Session(pid: 1, workingDirectory: cwd, status: status)
        s.needsAttention = attention
        s.worktreeName = worktree
        s.customName = customName
        s.activeSubagents = (0..<agents).map {
            ActiveSubagent(id: "a\($0)", type: "general-purpose", summary: "",
                           startedAt: Date().addingTimeInterval(-60))
        }
        return s
    }

    func testTheRowIsThirtyPoints() {
        XCTAssertEqual(CompactSessionRow.height, 30)
    }

    /// The worst case the row has to survive on one line: a worktree
    /// badge and an agent count beside the name and the elapsed time.
    func testAWorktreeAndAgentsFitTogether() {
        let content = CompactSessionRow.content(for: session(
            cwd: "/Users/me/work-hub/.claude/worktrees/external-wait",
            status: .busy, worktree: "external-wait", agents: 4))

        XCTAssertEqual(content.name, "work-hub")
        XCTAssertEqual(content.worktree, "external-wait")
        XCTAssertEqual(content.agentCount, 4)
        XCTAssertEqual(content.state, .working)
    }

    /// The name is the project, not the branch — a session that entered
    /// a worktree used to rename itself and print the same word twice.
    func testTheNameIsTheProjectNotTheWorktree() {
        let content = CompactSessionRow.content(for: session(
            cwd: "/Users/me/work-hub/.claude/worktrees/external-wait",
            worktree: "external-wait"))

        XCTAssertEqual(content.name, "work-hub")
    }

    func testACustomNameWins() {
        let content = CompactSessionRow.content(for: session(customName: "Client work"))

        XCTAssertEqual(content.name, "Client work")
    }

    /// No agents, no count — an empty mark beside a name is noise.
    func testASessionWithNoAgentsShowsNoCount() {
        XCTAssertNil(CompactSessionRow.content(for: session()).agentCount)
    }

    /// An agent that has gone idle is not working, and the count says
    /// how many are working.
    func testIdleTeammatesAreNotCounted() {
        var s = session(agents: 2)
        s.activeSubagents[0].isIdle = true

        XCTAssertEqual(CompactSessionRow.content(for: s).agentCount, 1)
    }

    func testNoWorktreeMeansNoBadge() {
        XCTAssertNil(CompactSessionRow.content(for: session()).worktree)
    }

    func testAttentionReachesTheRow() {
        XCTAssertEqual(CompactSessionRow.content(for: session(attention: true)).state,
                       .needsAttention)
    }

    // MARK: - The trailing text

    func testAWorkingSessionShowsHowLongItHasBeenWorking() {
        var s = session(status: .busy)
        s.statusChangedAt = Date().addingTimeInterval(-92)

        XCTAssertEqual(CompactSessionRow.content(for: s).trailing, "1m 32s")
    }

    func testAnIdleSessionShowsHowLongItHasBeenQuiet() {
        var s = session()
        s.statusChangedAt = Date().addingTimeInterval(-3720)

        XCTAssertEqual(CompactSessionRow.content(for: s).trailing, "waiting 1h 2m")
    }

    /// Seconds are noise past an hour, and minutes are noise past a day.
    func testLongDurationsShorten() {
        XCTAssertEqual(CompactSessionRow.duration(45), "45s")
        XCTAssertEqual(CompactSessionRow.duration(600), "10m")
        XCTAssertEqual(CompactSessionRow.duration(3600), "1h")
        XCTAssertEqual(CompactSessionRow.duration(90000), "1d 1h")
    }

    // MARK: - The slot, which is what makes a row look like Clyde's

    /// The full panel gives an idle session a numbered squircle and an
    /// active one the sprite. Compact keeps that language rather than
    /// inventing a list of dots — the numbered slot is the app's
    /// signature row element, and a row without it could belong to any
    /// application.
    func testAnIdleSessionKeepsItsNumber() {
        XCTAssertEqual(CompactSessionRow.slot(for: session(), index: 0), .number(1))
        XCTAssertEqual(CompactSessionRow.slot(for: session(), index: 4), .number(5))
    }

    func testAWorkingSessionShowsTheWave() {
        XCTAssertEqual(CompactSessionRow.slot(for: session(status: .busy), index: 0), .indicator)
    }

    func testASessionThatNeedsYouShowsTheIndicatorToo() {
        XCTAssertEqual(CompactSessionRow.slot(for: session(attention: true), index: 2), .indicator)
    }

    /// Numbers run from one, the way they read in the full panel.
    func testNumbersStartAtOne() {
        XCTAssertEqual(CompactSessionRow.slot(for: session(), index: 0), .number(1))
    }


    // MARK: - What a quiet row says

    /// Idle is not "nothing happening" — it means Claude finished and
    /// the ball is with the user. A row that shows only a name and a
    /// number withholds the one thing that state means.
    /// One phrase, not two columns saying half a thing each. "42s" on
    /// its own is forty-two seconds of what, and "waiting for you"
    /// repeated down every quiet row differentiates nothing.
    func testAQuietRowSaysWhatItHasBeenWaitingFor() {
        var s = session()
        s.statusChangedAt = Date().addingTimeInterval(-42)

        let content = CompactSessionRow.content(for: s)

        XCTAssertNil(content.meta, "the time carries it")
        XCTAssertEqual(content.trailing, "waiting 42s")
    }

    /// A working row spends the same space on what is actually running.
    func testAWorkingRowNamesWhatIsRunning() {
        var s = session(status: .busy)
        s.activeTool = ActiveTool(toolName: "Bash", summary: "npm test", startedAt: Date())

        XCTAssertEqual(CompactSessionRow.content(for: s).meta, "Bash")
        XCTAssertFalse(CompactSessionRow.content(for: s).trailing.contains("waiting"),
                       "a working row's time is how long it has been working")
    }

    func testAWorkingRowWithNoToolYetSaysSo() {
        XCTAssertEqual(CompactSessionRow.content(for: session(status: .busy)).meta, "working")
    }

    /// Clicking a row opens its terminal, which nothing on the row said.
    func testHoveringOffersToOpenTheTerminal() {
        XCTAssertEqual(CompactSessionRow.hoverLabel, "Open")
    }

    func testARowThatNeedsYouSaysThat() {
        XCTAssertEqual(CompactSessionRow.content(for: session(attention: true)).meta,
                       "needs you")
    }

    /// Quiet rows are quieter: the name recedes so a session that
    /// starts working stands out without anything having to flash.
    func testIdleNamesAreDimmerThanActiveOnes() {
        XCTAssertFalse(CompactSessionRow.namesAreProminent(in: .idle))
        XCTAssertTrue(CompactSessionRow.namesAreProminent(in: .working))
        XCTAssertTrue(CompactSessionRow.namesAreProminent(in: .needsAttention))
    }

}
