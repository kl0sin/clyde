import XCTest
@testable import Clyde

final class MockShellExecutor: ShellExecutor {
    var responses: [String: String] = [:]

    func run(_ command: String) async throws -> String {
        for (key, value) in responses {
            if command.contains(key) {
                return value
            }
        }
        return ""
    }
}

@MainActor
final class ProcessMonitorTests: XCTestCase {

    /// Mock shell that always returns empty so pgrep doesn't pick up
    /// real claude processes running on the host machine.
    private func emptyShell() -> MockShellExecutor {
        let shell = MockShellExecutor()
        shell.responses["pgrep"] = ""
        return shell
    }

    /// Fresh empty state dir per test so we don't pick up the host
    /// machine's real `~/.clyde/state/` content or other tests' files.
    private func tempStateDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clyde-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Writes an -info file the way SessionStart hook would. Uses the
    /// current process PID so kill(pid, 0) succeeds and the entry isn't
    /// pruned as dead.
    private func writeInfoFile(in dir: URL, sessionId: String = UUID().uuidString, cwd: String = "/tmp") -> pid_t {
        let pid = getpid()
        let body = #"{"session_id":"\#(sessionId)","pid":\#(pid),"cwd":"\#(cwd)","started_at":0}"#
        let url = dir.appendingPathComponent("\(sessionId)-info")
        try? body.write(to: url, atomically: true, encoding: .utf8)
        return pid
    }

    /// Writes a -busy marker. Same PID semantics as `writeInfoFile`.
    private func writeBusyFile(in dir: URL, sessionId: String, pid: pid_t = getpid(), cwd: String = "/tmp") {
        let body = #"{"session_id":"\#(sessionId)","pid":\#(pid),"cwd":"\#(cwd)","timestamp":\#(Int(Date().timeIntervalSince1970))}"#
        let url = dir.appendingPathComponent("\(sessionId)-busy")
        try? body.write(to: url, atomically: true, encoding: .utf8)
    }

    func testDiscoverPIDsReadsInfoFiles() async {
        let dir = tempStateDir()
        let sid = UUID().uuidString
        let pid = writeInfoFile(in: dir, sessionId: sid)

        let monitor = ProcessMonitor(shell: emptyShell(), pollingInterval: 1, stateDir: dir, isLiveClaudeProcessCheck: { _ in true })
        let pids = await monitor.discoverPIDs()
        XCTAssertEqual(pids, [pid])
    }

    func testDiscoverPIDsReturnsEmptyWhenNoInfoFiles() async {
        let monitor = ProcessMonitor(shell: emptyShell(), pollingInterval: 1, stateDir: tempStateDir(), isLiveClaudeProcessCheck: { _ in true })
        let pids = await monitor.discoverPIDs()
        XCTAssertEqual(pids, [])
    }

    func testDiscoverPIDsDropsDeadPIDs() async {
        let dir = tempStateDir()
        // Use a PID that almost certainly doesn't exist.
        let deadPID: pid_t = 999_999
        let body = #"{"session_id":"dead","pid":\#(deadPID),"cwd":"/tmp","started_at":0}"#
        try? body.write(to: dir.appendingPathComponent("dead-info"), atomically: true, encoding: .utf8)

        let monitor = ProcessMonitor(shell: emptyShell(), pollingInterval: 1, stateDir: dir, isLiveClaudeProcessCheck: { _ in true })
        _ = await monitor.discoverPIDs()
        // Dead -info file should have been removed.
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("dead-info").path))
    }

    func testClassifyStatusIsBusyWhenBusyMarkerPresent() async {
        let dir = tempStateDir()
        let sid = UUID().uuidString
        let pid = writeInfoFile(in: dir, sessionId: sid)
        writeBusyFile(in: dir, sessionId: sid, pid: pid)

        let monitor = ProcessMonitor(shell: emptyShell(), pollingInterval: 1, stateDir: dir, isLiveClaudeProcessCheck: { _ in true })
        await monitor.poll()
        XCTAssertEqual(monitor.sessions.first?.status, .busy)
    }

    func testClassifyStatusIsIdleWhenNoBusyMarker() async {
        let dir = tempStateDir()
        let sid = UUID().uuidString
        _ = writeInfoFile(in: dir, sessionId: sid)

        let monitor = ProcessMonitor(shell: emptyShell(), pollingInterval: 1, stateDir: dir, isLiveClaudeProcessCheck: { _ in true })
        await monitor.poll()
        XCTAssertEqual(monitor.sessions.first?.status, .idle)
    }

    func testPollBuildsSessionListFromInfoFiles() async {
        let dir = tempStateDir()
        let sid = UUID().uuidString
        let pid = writeInfoFile(in: dir, sessionId: sid, cwd: "/Users/me/Projects/shipyard")
        writeBusyFile(in: dir, sessionId: sid, pid: pid, cwd: "/Users/me/Projects/shipyard")

        let monitor = ProcessMonitor(shell: emptyShell(), pollingInterval: 1, stateDir: dir, isLiveClaudeProcessCheck: { _ in true })
        await monitor.poll()

        XCTAssertEqual(monitor.sessions.count, 1)
        XCTAssertEqual(monitor.sessions.first?.pid, pid)
        XCTAssertEqual(monitor.sessions.first?.status, .busy)
        XCTAssertEqual(monitor.sessions.first?.workingDirectory, "/Users/me/Projects/shipyard")
    }

    func testPollLeavesGhostRowAfterSessionEnds() async {
        let dir = tempStateDir()
        let sid = UUID().uuidString
        _ = writeInfoFile(in: dir, sessionId: sid)

        let monitor = ProcessMonitor(shell: emptyShell(), pollingInterval: 1, stateDir: dir, isLiveClaudeProcessCheck: { _ in true })
        await monitor.poll()
        XCTAssertEqual(monitor.sessions.count, 1)
        XCTAssertFalse(monitor.sessions.first?.isGhost ?? true)

        // SessionEnd hook removes both files.
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(sid)-info"))
        await monitor.poll()

        // Row stays in the raw list as a ghost so the user can still see it.
        XCTAssertEqual(monitor.sessions.count, 1)
        XCTAssertTrue(monitor.sessions.first?.isGhost ?? false)
        XCTAssertNotNil(monitor.sessions.first?.endedAt)
        // Live counters drop to zero, so clydeState goes to sleeping.
        XCTAssertEqual(monitor.clydeState, .sleeping)
    }

    func testClydeStateIsBusyWhenAnySessionBusy() async {
        let dir = tempStateDir()
        let sid = UUID().uuidString
        let pid = writeInfoFile(in: dir, sessionId: sid)
        writeBusyFile(in: dir, sessionId: sid, pid: pid)

        let monitor = ProcessMonitor(shell: emptyShell(), pollingInterval: 1, stateDir: dir, isLiveClaudeProcessCheck: { _ in true })
        await monitor.poll()
        XCTAssertEqual(monitor.clydeState, .busy)
    }

    func testClydeStateIsSleepingWhenNoSessions() async {
        let monitor = ProcessMonitor(shell: emptyShell(), pollingInterval: 1, stateDir: tempStateDir(), isLiveClaudeProcessCheck: { _ in true })
        await monitor.poll()
        XCTAssertEqual(monitor.clydeState, .sleeping)
    }

    /// Regression: when `isLiveClaudeProcess` falsely reports a live
    /// Claude PID as not-claude (the original `proc_name` bug — kernel
    /// returned the version directory name instead of "claude"),
    /// `refreshHookBusyPIDs` deleted every busy marker from disk and
    /// the UI never saw a session as busy. This test pins the contract:
    /// as long as the identity check returns true and a busy marker
    /// exists, the marker file must survive `poll()` and the session
    /// must classify as busy.
    func testBusyMarkerSurvivesPollWhenIdentityCheckPasses() async {
        let dir = tempStateDir()
        let sid = UUID().uuidString
        let pid = writeInfoFile(in: dir, sessionId: sid)
        writeBusyFile(in: dir, sessionId: sid, pid: pid)
        let busyURL = dir.appendingPathComponent("\(sid)-busy")

        let monitor = ProcessMonitor(
            shell: emptyShell(),
            pollingInterval: 1,
            stateDir: dir,
            isLiveClaudeProcessCheck: { _ in true }
        )
        await monitor.poll()

        XCTAssertTrue(FileManager.default.fileExists(atPath: busyURL.path),
                      "Busy marker must NOT be deleted when identity check passes (proc_name regression)")
        XCTAssertEqual(monitor.sessions.first?.status, .busy)
    }

    /// Regression: `claude --resume` reuses the same `session_id` but
    /// the underlying claude binary is a brand-new process with a new
    /// PID. The previous behaviour matched sessions purely by PID, so
    /// SessionEnd promoted the old PID to a ghost and SessionStart for
    /// the resumed session created a SECOND row for the new PID — the
    /// user saw two rows ("Ended" + freshly live) for what is logically
    /// one session. After the fix, the resumed session must REVIVE the
    /// existing ghost (matched by session_id) instead of duplicating it.
    func testResumeRevivesGhostInsteadOfDuplicating() async {
        let dir = tempStateDir()
        let sid = UUID().uuidString
        let firstPid = writeInfoFile(in: dir, sessionId: sid, cwd: "/tmp/proj")

        let monitor = ProcessMonitor(
            shell: emptyShell(),
            pollingInterval: 1,
            stateDir: dir,
            isLiveClaudeProcessCheck: { _ in true }
        )
        await monitor.poll()
        XCTAssertEqual(monitor.sessions.count, 1)
        XCTAssertFalse(monitor.sessions.first?.isGhost ?? true)

        // Simulate SessionEnd: hook removes both files.
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(sid)-info"))
        await monitor.poll()
        XCTAssertEqual(monitor.sessions.count, 1, "session should be a ghost after SessionEnd")
        XCTAssertTrue(monitor.sessions.first?.isGhost ?? false)

        // Simulate `claude --resume`: SessionStart fires for the SAME
        // sessionId but a different PID. We use init (pid 1) here
        // because it's guaranteed alive on macOS and is reliably
        // != getpid(), giving us a real "different PID, same sid"
        // setup. The injected isLiveClaudeProcessCheck stub means we
        // don't actually need pid 1 to be a Claude binary.
        let secondPid: pid_t = 1
        XCTAssertNotEqual(secondPid, firstPid)
        let body = #"{"session_id":"\#(sid)","pid":\#(secondPid),"cwd":"/tmp/proj","started_at":0}"#
        try? body.write(
            to: dir.appendingPathComponent("\(sid)-info"),
            atomically: true,
            encoding: .utf8
        )

        await monitor.poll()

        // EXACTLY one row, live, with the new PID. No leftover ghost.
        XCTAssertEqual(monitor.sessions.count, 1,
                       "expected 1 row after resume, got \(monitor.sessions.count)")
        XCTAssertEqual(monitor.sessions.filter { $0.isGhost }.count, 0,
                       "ghost must be replaced by the revived live row, not kept alongside")
        XCTAssertEqual(monitor.sessions.first?.pid, secondPid,
                       "revived row must carry the new PID")
        XCTAssertEqual(monitor.sessions.first?.sessionId, sid,
                       "session_id must be preserved across revival")
    }

    /// Regression for the inverse: when the identity check rejects a
    /// PID (e.g. PID got recycled to a non-claude binary), the marker
    /// MUST be cleaned up so we don't keep a stale "busy" forever.
    func testBusyMarkerRemovedWhenIdentityCheckFails() async {
        let dir = tempStateDir()
        let sid = UUID().uuidString
        let pid = writeInfoFile(in: dir, sessionId: sid)
        writeBusyFile(in: dir, sessionId: sid, pid: pid)
        let busyURL = dir.appendingPathComponent("\(sid)-busy")

        let monitor = ProcessMonitor(
            shell: emptyShell(),
            pollingInterval: 1,
            stateDir: dir,
            isLiveClaudeProcessCheck: { _ in false }
        )
        await monitor.poll()

        XCTAssertFalse(FileManager.default.fileExists(atPath: busyURL.path),
                       "Busy marker must be cleaned up when identity check fails")
    }
}
