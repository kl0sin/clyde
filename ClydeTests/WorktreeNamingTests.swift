import XCTest
@testable import Clyde

/// Claude Code moves a session into `<repo>/.claude/worktrees/<name>`
/// when it creates a worktree, and the session name is the last path
/// component of its cwd. So a session that had been working in
/// `work-hub` renamed itself to the worktree — and since the worktree
/// badge shows the same string, the row said "external-wait
/// external-wait" and the project it belongs to was nowhere on screen.
final class WorktreeNamingTests: XCTestCase {

    private func session(cwd: String, worktree: String = "") -> Session {
        var s = Session(pid: 1, workingDirectory: cwd, status: .idle)
        s.worktreeName = worktree
        return s
    }

    func testASessionInAWorktreeKeepsItsProjectName() {
        let s = session(cwd: "/Users/me/work-hub/.claude/worktrees/external-wait",
                        worktree: "external-wait")

        XCTAssertEqual(s.displayName, "work-hub")
        XCTAssertEqual(s.projectName, "work-hub")
    }

    /// The badge is where the worktree belongs, and it already works.
    func testTheWorktreeItselfIsStillKnown() {
        let s = session(cwd: "/Users/me/work-hub/.claude/worktrees/external-wait",
                        worktree: "external-wait")

        XCTAssertEqual(s.worktreeName, "external-wait")
    }

    /// A nested path inside the worktree resolves to the same project.
    func testADeeperPathInsideAWorktreeStillResolves() {
        let s = session(cwd: "/Users/me/work-hub/.claude/worktrees/external-wait/src/app")

        XCTAssertEqual(s.displayName, "work-hub")
    }

    func testAnOrdinaryCheckoutIsUnchanged() {
        XCTAssertEqual(session(cwd: "/Users/me/work-hub").displayName, "work-hub")
        XCTAssertEqual(session(cwd: "/Users/me/work-hub/src").displayName, "src")
    }

    /// A custom name the user typed still wins over anything derived.
    func testACustomNameStillWins() {
        var s = session(cwd: "/Users/me/work-hub/.claude/worktrees/external-wait")
        s.customName = "Client work"

        XCTAssertEqual(s.displayName, "Client work")
    }
}
