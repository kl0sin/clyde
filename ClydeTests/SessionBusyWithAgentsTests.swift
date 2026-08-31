import XCTest
@testable import Clyde

/// A session whose turn has ended but whose subagents are still working
/// is not idle. The busy marker is written by `UserPromptSubmit` and
/// cleared by `Stop`, while `-agents/` records deliberately outlive
/// `Stop` — the hook says so in as many words, because subagents
/// routinely finish long after the parent's turn.
///
/// The visible cost was a "session finished" notification fired while
/// four agents were still running, and a row reading "ready" next to a
/// spinning agent.
@MainActor
final class SessionBusyWithAgentsTests: XCTestCase {

    private func agent(_ type: String, minutesAgo: Int = 1) -> ActiveSubagent {
        ActiveSubagent(id: UUID().uuidString,
                       type: type,
                       summary: "",
                       startedAt: Date().addingTimeInterval(TimeInterval(-60 * minutesAgo)))
    }

    func testASessionWithRunningAgentsIsNotIdle() {
        var session = Session(pid: 1, workingDirectory: "/repo", status: .idle)
        session.activeSubagents = [agent("general-purpose")]

        XCTAssertTrue(session.isWorking, "an agent is still doing the session's work")
    }

    func testASessionWithNoAgentsAndNoBusyMarkerIsIdle() {
        let session = Session(pid: 1, workingDirectory: "/repo", status: .idle)

        XCTAssertFalse(session.isWorking)
    }

    func testABusySessionIsWorkingRegardless() {
        let session = Session(pid: 1, workingDirectory: "/repo", status: .busy)

        XCTAssertTrue(session.isWorking)
    }

    /// An agent flagged idle by TeammateIdle is not doing work, so it
    /// must not hold the session open on its own.
    func testAnIdleTeammateDoesNotHoldTheSessionOpen() {
        var session = Session(pid: 1, workingDirectory: "/repo", status: .idle)
        var teammate = agent("general-purpose")
        teammate.isIdle = true
        session.activeSubagents = [teammate]

        XCTAssertFalse(session.isWorking)
    }

    /// One working agent among idle ones still counts.
    func testOneWorkingAgentAmongIdleOnesCounts() {
        var session = Session(pid: 1, workingDirectory: "/repo", status: .idle)
        var teammate = agent("Explore")
        teammate.isIdle = true
        session.activeSubagents = [teammate, agent("general-purpose")]

        XCTAssertTrue(session.isWorking)
    }
}
