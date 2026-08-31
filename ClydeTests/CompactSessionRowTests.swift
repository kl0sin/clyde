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

        XCTAssertEqual(CompactSessionRow.content(for: s).trailing, "1h 2m")
    }

    /// Seconds are noise past an hour, and minutes are noise past a day.
    func testLongDurationsShorten() {
        XCTAssertEqual(CompactSessionRow.duration(45), "45s")
        XCTAssertEqual(CompactSessionRow.duration(600), "10m")
        XCTAssertEqual(CompactSessionRow.duration(3600), "1h")
        XCTAssertEqual(CompactSessionRow.duration(90000), "1d 1h")
    }
}
