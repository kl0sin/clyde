import XCTest
@testable import Clyde

final class SessionTests: XCTestCase {
    func testDisplayNameUsesCustomNameWhenSet() {
        var session = Session(pid: 123, workingDirectory: "/Users/me/Projects/shipyard")
        session.customName = "Backend"
        XCTAssertEqual(session.displayName, "Backend")
    }

    func testDisplayNameFallsBackToCWDBasename() {
        let session = Session(
            pid: 123,
            workingDirectory: "/Users/me/Projects/shipyard",
            sessionId: UUID().uuidString
        )
        XCTAssertEqual(session.displayName, "shipyard")
    }

    func testDisplayNameIgnoresEmptyCustomName() {
        var session = Session(
            pid: 123,
            workingDirectory: "/Users/me/Projects/shipyard",
            sessionId: UUID().uuidString
        )
        session.customName = ""
        XCTAssertEqual(session.displayName, "shipyard")
    }

    func testDisplayNameWithoutSessionIdUsesCWDWhenMeaningful() {
        // A pgrep-discovered session with a proper project cwd still shows
        // the project name — even without a hook session_id.
        let session = Session(pid: 123, workingDirectory: "/Users/me/Projects/shipyard")
        XCTAssertEqual(session.displayName, "shipyard")
    }

    func testDisplayNameUsesHomeLabelForHomeDirectoryCWD() {
        // cwd == ~ tells us nothing about a project, but it IS distinctly
        // "the home directory". Surface that as "Home" rather than the
        // generic Untitled fallback.
        let session = Session(pid: 123, workingDirectory: NSHomeDirectory())
        XCTAssertEqual(session.displayName, "Home")
    }

    func testDisplayNameFallsBackToUntitledForEmptyCWD() {
        let session = Session(pid: 123, workingDirectory: "")
        XCTAssertEqual(session.displayName, "Untitled session")
    }

    func testInitialStatusIsBusy() {
        let session = Session(pid: 456)
        XCTAssertEqual(session.status, .busy)
    }

    func testSessionsAreIdentifiable() {
        let a = Session(pid: 100)
        let b = Session(pid: 100)
        XCTAssertNotEqual(a.id, b.id)
    }

    // MARK: - activeTool / toolDisplayLabel

    /// The Activity timeline's subagent entries used to be driven by the
    /// legacy single-agent `-subagent` marker. They now derive from the
    /// same `activeSubagents` list the panel renders, so one source of
    /// truth feeds both.
    func testPrimarySubagentTypeDerivesFromActiveSubagents() {
        var session = Session(pid: 123, workingDirectory: "/tmp")
        XCTAssertNil(session.primarySubagentType, "no agents means no timeline entry")

        session.activeSubagents = [
            ActiveSubagent(id: "a1", type: "Explore", summary: "find", startedAt: Date()),
            ActiveSubagent(id: "a2", type: "general-purpose", summary: "research", startedAt: Date()),
        ]
        XCTAssertEqual(session.primarySubagentType, "Explore", "oldest agent names the entry")
    }

    func testToolDisplayLabelIsNilWhenNoActiveTool() {
        let session = Session(pid: 123, workingDirectory: "/tmp")
        XCTAssertNil(session.toolDisplayLabel)
    }

    func testToolDisplayLabelCombinesNameAndSummary() {
        var session = Session(pid: 123, workingDirectory: "/tmp")
        session.activeTool = ActiveTool(
            toolName: "Edit",
            summary: "SessionRow.swift",
            startedAt: Date()
        )
        XCTAssertEqual(session.toolDisplayLabel, "Edit · SessionRow.swift")
    }

    func testToolDisplayLabelOmitsSeparatorWhenSummaryEmpty() {
        var session = Session(pid: 123, workingDirectory: "/tmp")
        session.activeTool = ActiveTool(
            toolName: "TodoWrite",
            summary: "",
            startedAt: Date()
        )
        XCTAssertEqual(session.toolDisplayLabel, "TodoWrite")
    }

    // MARK: - ActivePlan / activePlan

    func testActivePlanIsIncompleteWhenZeroTasks() {
        let plan = ActivePlan(taskCount: 0, doneCount: 0, startedAt: Date())
        XCTAssertFalse(plan.isComplete)
        XCTAssertEqual(plan.progress, 0.0)
    }

    func testActivePlanIsIncompleteWhenSomeDone() {
        let plan = ActivePlan(taskCount: 5, doneCount: 2, startedAt: Date())
        XCTAssertFalse(plan.isComplete)
        XCTAssertEqual(plan.progress, 0.4, accuracy: 0.001)
    }

    func testActivePlanIsCompleteWhenAllDone() {
        let plan = ActivePlan(taskCount: 5, doneCount: 5, startedAt: Date())
        XCTAssertTrue(plan.isComplete)
        XCTAssertEqual(plan.progress, 1.0)
    }

    func testActivePlanProgressClampsOnOverflow() {
        // Defensive: a runaway TaskCompleted shouldn't push progress past 100%.
        let plan = ActivePlan(taskCount: 5, doneCount: 6, startedAt: Date())
        XCTAssertTrue(plan.isComplete)
        XCTAssertEqual(plan.progress, 1.0)
    }

    func testSessionActivePlanDefaultsToNil() {
        let session = Session(pid: 123, workingDirectory: "/tmp")
        XCTAssertNil(session.activePlan)
    }

    /// New cleat-runtime fields default to empty strings so the badge
    /// renders only for sessions that actually opted in via the hook.
    /// Empty (not nil) keeps the API simple — SessionRow gates on
    /// `runtime == "cleat"` rather than `runtime?.isEmpty == false`.
    func testSessionRuntimeAndContainerDefaultsAreEmpty() {
        let session = Session(pid: 123, workingDirectory: "/tmp")
        XCTAssertEqual(session.runtime, "")
        XCTAssertEqual(session.container, "")
    }
}
