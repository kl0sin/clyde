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

    /// Writes a cleat-flavoured `-info` file the way clyde-hook.sh v24+
    /// does when it detects a Cleat-sandboxed session. The `pid` is the
    /// host-side cleat process (in production), so we use the current
    /// test process PID to satisfy `kill(pid, 0)`. The `runtime` and
    /// `container` fields are what tell ProcessMonitor to skip the
    /// `argv[0] == claude` identity check.
    private func writeCleatInfoFile(
        in dir: URL,
        sessionId: String = UUID().uuidString,
        cwd: String = "/Users/me/Projects/draft-zone",
        container: String = "cleat-draft-zone-deadbeef"
    ) -> pid_t {
        let pid = getpid()
        let body = #"{"session_id":"\#(sessionId)","pid":\#(pid),"cwd":"\#(cwd)","started_at":0,"runtime":"cleat","container":"\#(container)"}"#
        let url = dir.appendingPathComponent("\(sessionId)-info")
        try? body.write(to: url, atomically: true, encoding: .utf8)
        return pid
    }

    /// Writes a `-tool` marker the way PreToolUse hook would. Same PID
    /// semantics as `writeInfoFile` (uses the current process PID so
    /// kill(pid, 0) succeeds).
    private func writeToolFile(
        in dir: URL,
        sessionId: String,
        toolName: String,
        summary: String = "",
        startedAt: TimeInterval = Date().timeIntervalSince1970,
        pid: pid_t = getpid()
    ) {
        let body = #"{"session_id":"\#(sessionId)","pid":\#(pid),"tool_name":"\#(toolName)","summary":"\#(summary)","started_at":\#(Int(startedAt))}"#
        let url = dir.appendingPathComponent("\(sessionId)-tool")
        try? body.write(to: url, atomically: true, encoding: .utf8)
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

        // The identity check rejects the dead PID — the production
        // implementation does the same via kill(pid,0) + ps comm check.
        let monitor = ProcessMonitor(shell: emptyShell(), pollingInterval: 1, stateDir: dir, isLiveClaudeProcessCheck: { $0 != deadPID })
        _ = await monitor.discoverPIDs()
        // Dead -info file should have been removed.
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("dead-info").path))
    }

    /// Regression: an -info file whose PID is alive but no longer
    /// belongs to Claude (macOS recycled it onto a different binary)
    /// must be pruned, not surfaced as a phantom session. Before this
    /// fix, discoverPIDs only checked liveness via kill(pid,0) and the
    /// recycled PID kept showing up in the UI until the file was
    /// hand-deleted.
    func testDiscoverPIDsDropsRecycledPIDsThatAreNoLongerClaude() async {
        let dir = tempStateDir()
        let sid = UUID().uuidString
        let livePID = getpid()
        let body = #"{"session_id":"\#(sid)","pid":\#(livePID),"cwd":"/tmp","started_at":0}"#
        let infoURL = dir.appendingPathComponent("\(sid)-info")
        try? body.write(to: infoURL, atomically: true, encoding: .utf8)

        // Identity check returns false → simulates a recycled PID that
        // is alive but is not the Claude binary anymore.
        let monitor = ProcessMonitor(shell: emptyShell(), pollingInterval: 1, stateDir: dir, isLiveClaudeProcessCheck: { _ in false })
        let pids = await monitor.discoverPIDs()

        XCTAssertEqual(pids, [], "recycled PID must not be surfaced as a Claude session")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: infoURL.path),
            "stale -info file for recycled PID must be pruned"
        )
    }

    /// Cleat regression: a session running inside a Cleat Docker sandbox
    /// records the cleat *host-process* PID (not the in-container one),
    /// and that process isn't named `claude` — it's a bash script. The
    /// `argv[0] == claude` identity check therefore returns false, but
    /// the session must NOT be pruned: `runtime: "cleat"` in the -info
    /// file tells ProcessMonitor to fall back to a plain `kill(pid, 0)`
    /// liveness probe. Without this branch every cleat session would
    /// flash into the panel and immediately vanish.
    func testCleatInfoFileSurvivesEvenWhenIdentityCheckFails() async {
        let dir = tempStateDir()
        let sid = UUID().uuidString
        let pid = writeCleatInfoFile(in: dir, sessionId: sid)

        // Stub returns false → "not the Claude binary". On a host session
        // that would prune the file (see testDiscoverPIDsDropsRecycledPIDs…).
        // On a cleat session it MUST be ignored — the runtime field
        // routes liveness through kill(pid,0), which succeeds for getpid().
        let monitor = ProcessMonitor(
            shell: emptyShell(),
            pollingInterval: 1,
            stateDir: dir,
            isLiveClaudeProcessCheck: { _ in false }
        )
        let pids = await monitor.discoverPIDs()

        XCTAssertEqual(pids, [pid], "cleat-tagged session must not be pruned by failing identity check")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(sid)-info").path),
            "cleat -info file must remain on disk after discoverPIDs"
        )
    }

    /// After `poll()` the Session row built from a cleat -info must
    /// carry through both `runtime` and `container` so the UI can show
    /// the "cleat" badge and tooltip. Failing this test means the badge
    /// would never appear even if the row itself rendered.
    func testCleatSessionExposesRuntimeAndContainerOnSession() async {
        let dir = tempStateDir()
        let sid = UUID().uuidString
        _ = writeCleatInfoFile(
            in: dir,
            sessionId: sid,
            cwd: "/Users/me/Projects/draft-zone",
            container: "cleat-draft-zone-1a3bc53a"
        )

        let monitor = ProcessMonitor(
            shell: emptyShell(),
            pollingInterval: 1,
            stateDir: dir,
            isLiveClaudeProcessCheck: { _ in false }
        )
        await monitor.poll()

        XCTAssertEqual(monitor.sessions.count, 1)
        let session = monitor.sessions.first
        XCTAssertEqual(session?.runtime, "cleat")
        XCTAssertEqual(session?.container, "cleat-draft-zone-1a3bc53a")
        XCTAssertEqual(session?.workingDirectory, "/Users/me/Projects/draft-zone")
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

    /// Regression: a `claude --resume` shows the new claude binary to
    /// `pgrep -x claude` ~hundreds of ms before its `SessionStart` hook
    /// fires and writes the `-info` file. The pgrep-only PID has no
    /// `sessionId` yet, so the revival path can't fire — without the
    /// deferral mitigation a brand-new pgrep-only row would appear
    /// alongside the existing ghost and the user would briefly see two
    /// rows for what is logically one session.
    ///
    /// Contract: the FIRST appearance of a pgrep-only PID while a
    /// recent ghost exists is suppressed. Once `-info` arrives (or one
    /// extra tick passes), the row is rendered normally.
    func testPgrepOnlyPIDDeferredWhenRecentGhostExists() async {
        let dir = tempStateDir()
        let sid = UUID().uuidString
        _ = writeInfoFile(in: dir, sessionId: sid)

        // Tick 1: discover existing session via -info file.
        let shell = MockShellExecutor()
        shell.responses["pgrep"] = ""
        let monitor = ProcessMonitor(
            shell: shell,
            pollingInterval: 1,
            stateDir: dir,
            isLiveClaudeProcessCheck: { _ in true }
        )
        await monitor.poll()
        XCTAssertEqual(monitor.sessions.count, 1)

        // Tick 2: SessionEnd — remove the -info file. Session becomes ghost.
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(sid)-info"))
        await monitor.poll()
        XCTAssertEqual(monitor.sessions.count, 1)
        XCTAssertTrue(monitor.sessions.first?.isGhost ?? false)

        // Tick 3: Claude binary launches via `--resume`, but its
        // SessionStart hook hasn't fired yet. pgrep finds the new PID,
        // there's no -info, so hookInfoByPID stays empty for it. The
        // mitigation must DEFER this PID for one tick.
        //
        // Use init (pid 1) as the resume pid because it's guaranteed
        // alive on macOS and `kill(1, 0)` succeeds for any user, so
        // discoverPIDs won't ESRCH-prune the -info file we'll write
        // in tick 4. The injected isLiveClaudeProcessCheck stub means
        // we don't actually need pid 1 to be a Claude binary.
        let resumePID: pid_t = 1
        shell.responses["pgrep"] = "\(resumePID)"
        await monitor.poll()
        // Only the ghost should still be visible — the pgrep-only PID
        // is deferred, not added.
        XCTAssertEqual(monitor.sessions.count, 1,
                       "deferred pgrep-only PID must NOT appear alongside the ghost")
        XCTAssertTrue(monitor.sessions.first?.isGhost ?? false)

        // Tick 4: SessionStart hook fired now → -info file written with
        // the SAME sessionId and the new PID. The revival path should
        // run cleanly: ghost is replaced by a single live row.
        let body = #"{"session_id":"\#(sid)","pid":\#(resumePID),"cwd":"/tmp","started_at":0}"#
        try? body.write(
            to: dir.appendingPathComponent("\(sid)-info"),
            atomically: true,
            encoding: .utf8
        )
        await monitor.poll()
        XCTAssertEqual(monitor.sessions.count, 1, "expected exactly 1 row after revival")
        XCTAssertEqual(monitor.sessions.filter { $0.isGhost }.count, 0,
                       "ghost must not coexist with the revived live row")
        XCTAssertEqual(monitor.sessions.first?.pid, resumePID)
        XCTAssertEqual(monitor.sessions.first?.sessionId, sid)
    }

    /// Companion to the deferral test: the deferral is strictly ONE
    /// tick per PID. If `SessionStart` never fires (e.g. genuinely
    /// new session that just happens to coincide with a recent ghost),
    /// the second appearance must render normally — we don't want to
    /// hide a real session indefinitely.
    func testPgrepOnlyPIDRendersOnSecondAppearance() async {
        let dir = tempStateDir()
        let sid = UUID().uuidString
        _ = writeInfoFile(in: dir, sessionId: sid)

        let shell = MockShellExecutor()
        shell.responses["pgrep"] = ""
        let monitor = ProcessMonitor(
            shell: shell,
            pollingInterval: 1,
            stateDir: dir,
            isLiveClaudeProcessCheck: { _ in true }
        )
        await monitor.poll()
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(sid)-info"))
        await monitor.poll()
        // Confirm we have a ghost.
        XCTAssertTrue(monitor.sessions.first?.isGhost ?? false)

        // Brand-new (non-resume) pgrep-only PID arrives. Pid 1 again
        // for the same kill(pid, 0) reason as the previous test.
        let newPID: pid_t = 1
        shell.responses["pgrep"] = "\(newPID)"

        // First appearance — deferred.
        await monitor.poll()
        XCTAssertEqual(monitor.sessions.count, 1)
        XCTAssertTrue(monitor.sessions.first?.isGhost ?? false)

        // Second appearance — must render even though hookInfo never arrived.
        await monitor.poll()
        let live = monitor.sessions.filter { !$0.isGhost }
        XCTAssertEqual(live.count, 1, "deferred PID must surface on second tick")
        XCTAssertEqual(live.first?.pid, newPID)
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

    func testActiveToolIsPopulatedFromToolFile() async throws {
        let dir = tempStateDir()
        let sid = UUID().uuidString
        _ = writeInfoFile(in: dir, sessionId: sid)
        let started = Date().timeIntervalSince1970 - 3
        writeToolFile(in: dir, sessionId: sid, toolName: "Edit", summary: "SessionRow.swift", startedAt: started)

        let monitor = ProcessMonitor(
            shell: emptyShell(),
            pollingInterval: 1,
            stateDir: dir,
            isLiveClaudeProcessCheck: { _ in true }
        )
        await monitor.poll()

        XCTAssertEqual(monitor.sessions.count, 1)
        let tool = try XCTUnwrap(monitor.sessions[0].activeTool)
        XCTAssertEqual(tool.toolName, "Edit")
        XCTAssertEqual(tool.summary, "SessionRow.swift")
        XCTAssertEqual(tool.startedAt.timeIntervalSince1970, started, accuracy: 1)
    }

    func testActiveToolClearsWhenFileRemoved() async {
        let dir = tempStateDir()
        let sid = UUID().uuidString
        _ = writeInfoFile(in: dir, sessionId: sid)
        writeToolFile(in: dir, sessionId: sid, toolName: "Bash", summary: "swift test")

        let monitor = ProcessMonitor(
            shell: emptyShell(),
            pollingInterval: 1,
            stateDir: dir,
            isLiveClaudeProcessCheck: { _ in true }
        )
        await monitor.poll()
        XCTAssertNotNil(monitor.sessions.first?.activeTool)

        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(sid)-tool"))
        await monitor.poll()
        XCTAssertNil(monitor.sessions.first?.activeTool)
    }

    func testActiveToolHandlesEmptySummary() async {
        let dir = tempStateDir()
        let sid = UUID().uuidString
        _ = writeInfoFile(in: dir, sessionId: sid)
        writeToolFile(in: dir, sessionId: sid, toolName: "TodoWrite", summary: "")

        let monitor = ProcessMonitor(
            shell: emptyShell(),
            pollingInterval: 1,
            stateDir: dir,
            isLiveClaudeProcessCheck: { _ in true }
        )
        await monitor.poll()

        XCTAssertEqual(monitor.sessions.first?.activeTool?.toolName, "TodoWrite")
        XCTAssertEqual(monitor.sessions.first?.activeTool?.summary, "")
    }

    func testToolFileIsRemovedWhenPIDIsDead() async {
        let dir = tempStateDir()
        let sid = UUID().uuidString
        _ = writeInfoFile(in: dir, sessionId: sid)
        // Write -tool with a PID that almost certainly doesn't exist.
        let body = #"{"session_id":"\#(sid)","pid":999999,"tool_name":"Edit","summary":"x.swift","started_at":0}"#
        let url = dir.appendingPathComponent("\(sid)-tool")
        try? body.write(to: url, atomically: true, encoding: .utf8)

        let monitor = ProcessMonitor(
            shell: emptyShell(),
            pollingInterval: 1,
            stateDir: dir,
            isLiveClaudeProcessCheck: { _ in true }
        )
        await monitor.poll()

        XCTAssertNil(monitor.sessions.first?.activeTool)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testMalformedToolFileIsRemoved() async {
        let dir = tempStateDir()
        let sid = UUID().uuidString
        _ = writeInfoFile(in: dir, sessionId: sid)
        let url = dir.appendingPathComponent("\(sid)-tool")
        try? "not json".write(to: url, atomically: true, encoding: .utf8)

        let monitor = ProcessMonitor(
            shell: emptyShell(),
            pollingInterval: 1,
            stateDir: dir,
            isLiveClaudeProcessCheck: { _ in true }
        )
        await monitor.poll()

        XCTAssertNil(monitor.sessions.first?.activeTool)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    /// Writes a `-plan` marker the way TaskCreated/TaskCompleted hook
    /// would (after read-modify-write). Same PID semantics as
    /// `writeInfoFile` (uses the current process PID so kill(pid, 0)
    /// succeeds in tests).
    private func writePlanFile(
        in dir: URL,
        sessionId: String,
        taskCount: Int,
        doneCount: Int,
        startedAt: TimeInterval = Date().timeIntervalSince1970,
        pid: pid_t = getpid()
    ) {
        let body = #"{"session_id":"\#(sessionId)","pid":\#(pid),"task_count":\#(taskCount),"done_count":\#(doneCount),"started_at":\#(Int(startedAt))}"#
        let url = dir.appendingPathComponent("\(sessionId)-plan")
        try? body.write(to: url, atomically: true, encoding: .utf8)
    }

    func testActivePlanIsPopulatedFromPlanFile() async throws {
        let dir = tempStateDir()
        let sid = UUID().uuidString
        _ = writeInfoFile(in: dir, sessionId: sid)
        let started = Date().timeIntervalSince1970 - 30
        writePlanFile(in: dir, sessionId: sid, taskCount: 5, doneCount: 2, startedAt: started)

        let monitor = ProcessMonitor(
            shell: emptyShell(),
            pollingInterval: 1,
            stateDir: dir,
            isLiveClaudeProcessCheck: { _ in true }
        )
        await monitor.poll()

        XCTAssertEqual(monitor.sessions.count, 1)
        let plan = try XCTUnwrap(monitor.sessions[0].activePlan)
        XCTAssertEqual(plan.taskCount, 5)
        XCTAssertEqual(plan.doneCount, 2)
        XCTAssertEqual(plan.startedAt.timeIntervalSince1970, started, accuracy: 1)
    }

    func testActivePlanClearsWhenFileRemoved() async {
        let dir = tempStateDir()
        let sid = UUID().uuidString
        _ = writeInfoFile(in: dir, sessionId: sid)
        writePlanFile(in: dir, sessionId: sid, taskCount: 3, doneCount: 1)

        let monitor = ProcessMonitor(
            shell: emptyShell(),
            pollingInterval: 1,
            stateDir: dir,
            isLiveClaudeProcessCheck: { _ in true }
        )
        await monitor.poll()
        XCTAssertNotNil(monitor.sessions.first?.activePlan)

        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(sid)-plan"))
        await monitor.poll()
        XCTAssertNil(monitor.sessions.first?.activePlan)
    }

    func testActivePlanUpdatesAfterRewrite() async {
        let dir = tempStateDir()
        let sid = UUID().uuidString
        _ = writeInfoFile(in: dir, sessionId: sid)
        writePlanFile(in: dir, sessionId: sid, taskCount: 5, doneCount: 1)

        let monitor = ProcessMonitor(
            shell: emptyShell(),
            pollingInterval: 1,
            stateDir: dir,
            isLiveClaudeProcessCheck: { _ in true }
        )
        await monitor.poll()
        XCTAssertEqual(monitor.sessions.first?.activePlan?.doneCount, 1)

        // Simulate the hook re-writing the file with an incremented done_count.
        writePlanFile(in: dir, sessionId: sid, taskCount: 5, doneCount: 3)
        await monitor.poll()
        XCTAssertEqual(monitor.sessions.first?.activePlan?.doneCount, 3)
        XCTAssertEqual(monitor.sessions.first?.activePlan?.taskCount, 5)
    }

    func testPlanFileIsRemovedWhenPIDIsDead() async {
        let dir = tempStateDir()
        let sid = UUID().uuidString
        _ = writeInfoFile(in: dir, sessionId: sid)
        // Write -plan with a PID that almost certainly doesn't exist.
        let body = #"{"session_id":"\#(sid)","pid":999999,"task_count":3,"done_count":1,"started_at":0}"#
        let url = dir.appendingPathComponent("\(sid)-plan")
        try? body.write(to: url, atomically: true, encoding: .utf8)

        let monitor = ProcessMonitor(
            shell: emptyShell(),
            pollingInterval: 1,
            stateDir: dir,
            isLiveClaudeProcessCheck: { _ in true }
        )
        await monitor.poll()

        XCTAssertNil(monitor.sessions.first?.activePlan)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testMalformedPlanFileIsRemoved() async {
        let dir = tempStateDir()
        let sid = UUID().uuidString
        _ = writeInfoFile(in: dir, sessionId: sid)
        let url = dir.appendingPathComponent("\(sid)-plan")
        try? "not json".write(to: url, atomically: true, encoding: .utf8)

        let monitor = ProcessMonitor(
            shell: emptyShell(),
            pollingInterval: 1,
            stateDir: dir,
            isLiveClaudeProcessCheck: { _ in true }
        )
        await monitor.poll()

        XCTAssertNil(monitor.sessions.first?.activePlan)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testActiveSubagentsListedFromAgentsDir() async throws {
        let dir = tempStateDir()
        let sid = "s1"
        _ = writeInfoFile(in: dir, sessionId: sid)

        // Create the <sid>-agents/ directory.
        let agentsDir = dir.appendingPathComponent("\(sid)-agents")
        try FileManager.default.createDirectory(at: agentsDir, withIntermediateDirectories: true)

        let now = Date().timeIntervalSince1970
        // toolu_a — older subagent
        let bodyA = #"{"tool_use_id":"toolu_a","subagent_type":"Explore","summary":"find code","started_at":\#(Int(now - 20))}"#
        try bodyA.write(to: agentsDir.appendingPathComponent("toolu_a.json"), atomically: true, encoding: .utf8)
        // toolu_b — newer subagent
        let bodyB = #"{"tool_use_id":"toolu_b","subagent_type":"general-purpose","summary":"research","started_at":\#(Int(now - 5))}"#
        try bodyB.write(to: agentsDir.appendingPathComponent("toolu_b.json"), atomically: true, encoding: .utf8)

        let monitor = ProcessMonitor(
            shell: emptyShell(),
            pollingInterval: 1,
            stateDir: dir,
            isLiveClaudeProcessCheck: { _ in true }
        )
        await monitor.poll()

        XCTAssertEqual(monitor.sessions.count, 1)
        let session = try XCTUnwrap(monitor.sessions.first)
        // Oldest first — toolu_a (started_at = now-20) before toolu_b (started_at = now-5).
        XCTAssertEqual(session.activeSubagents.map(\.id), ["toolu_a", "toolu_b"])
        XCTAssertEqual(session.activeSubagents[0].type, "Explore")
        XCTAssertEqual(session.activeSubagents[0].summary, "find code")
        XCTAssertEqual(session.activeSubagents[1].type, "general-purpose")
        XCTAssertEqual(session.activeSubagents[1].summary, "research")
    }

    /// Once SubagentStart claims a pending entry the record is keyed on
    /// `agent_id` and carries no `tool_use_id` at all — the two events
    /// share no identifier. Requiring `tool_use_id` would make every
    /// claimed entry read as malformed and drop the row.
    func testActiveSubagentsAcceptClaimedEntriesKeyedOnAgentID() async throws {
        let dir = tempStateDir()
        let sid = "s1"
        _ = writeInfoFile(in: dir, sessionId: sid)

        let agentsDir = dir.appendingPathComponent("\(sid)-agents")
        try FileManager.default.createDirectory(at: agentsDir, withIntermediateDirectories: true)

        let now = Date().timeIntervalSince1970
        // Claimed — SubagentStart re-keyed it and dropped tool_use_id.
        let claimed = #"{"agent_id":"agent_x","subagent_type":"Explore","summary":"find code","started_at":\#(Int(now - 20))}"#
        try claimed.write(to: agentsDir.appendingPathComponent("agent_x.json"), atomically: true, encoding: .utf8)
        // Still pending — dispatched, SubagentStart not in yet.
        let pending = #"{"tool_use_id":"toolu_y","subagent_type":"general-purpose","summary":"research","started_at":\#(Int(now - 5))}"#
        try pending.write(to: agentsDir.appendingPathComponent("pending-toolu_y.json"), atomically: true, encoding: .utf8)

        let monitor = ProcessMonitor(
            shell: emptyShell(),
            pollingInterval: 1,
            stateDir: dir,
            isLiveClaudeProcessCheck: { _ in true }
        )
        await monitor.poll()

        let session = try XCTUnwrap(monitor.sessions.first)
        XCTAssertEqual(
            session.activeSubagents.map(\.id), ["agent_x", "toolu_y"],
            "both a claimed (agent_id) and a still-pending (tool_use_id) entry must render"
        )
        XCTAssertEqual(session.activeSubagents[0].summary, "find code")
    }

    /// A teammate flagged idle by TeammateIdle stays on the row but
    /// stops reading as live work.
    func testActiveSubagentsCarryIdleFlag() async throws {
        let dir = tempStateDir()
        let sid = "s1"
        _ = writeInfoFile(in: dir, sessionId: sid)

        let agentsDir = dir.appendingPathComponent("\(sid)-agents")
        try FileManager.default.createDirectory(at: agentsDir, withIntermediateDirectories: true)

        let now = Date().timeIntervalSince1970
        let idle = #"{"agent_id":"agent_idle","subagent_type":"Explore","summary":"waiting","started_at":\#(Int(now - 30)),"idle":true}"#
        try idle.write(to: agentsDir.appendingPathComponent("agent_idle.json"), atomically: true, encoding: .utf8)
        let busy = #"{"agent_id":"agent_busy","subagent_type":"Explore","summary":"working","started_at":\#(Int(now - 10))}"#
        try busy.write(to: agentsDir.appendingPathComponent("agent_busy.json"), atomically: true, encoding: .utf8)

        let monitor = ProcessMonitor(
            shell: emptyShell(),
            pollingInterval: 1,
            stateDir: dir,
            isLiveClaudeProcessCheck: { _ in true }
        )
        await monitor.poll()

        let session = try XCTUnwrap(monitor.sessions.first)
        XCTAssertEqual(session.activeSubagents.map(\.id), ["agent_idle", "agent_busy"])
        XCTAssertTrue(session.activeSubagents[0].isIdle, "the flagged teammate must read as idle")
        XCTAssertFalse(session.activeSubagents[1].isIdle, "an unflagged agent must stay live")
    }

    func testActiveSubagentsGCsEntriesOlderThan30Minutes() async throws {
        let dir = tempStateDir()
        let sid = "s1"
        _ = writeInfoFile(in: dir, sessionId: sid)
        let agentsDir = dir.appendingPathComponent("\(sid)-agents")
        try FileManager.default.createDirectory(at: agentsDir, withIntermediateDirectories: true)

        let now = Date().timeIntervalSince1970
        let oldBody = #"{"tool_use_id":"toolu_old","subagent_type":"Explore","summary":"old","started_at":\#(Int(now - 31 * 60))}"#
        try oldBody.write(to: agentsDir.appendingPathComponent("toolu_old.json"), atomically: true, encoding: .utf8)
        let freshBody = #"{"tool_use_id":"toolu_fresh","subagent_type":"Plan","summary":"fresh","started_at":\#(Int(now - 60))}"#
        try freshBody.write(to: agentsDir.appendingPathComponent("toolu_fresh.json"), atomically: true, encoding: .utf8)

        let monitor = ProcessMonitor(
            shell: emptyShell(),
            pollingInterval: 1,
            stateDir: dir,
            isLiveClaudeProcessCheck: { _ in true }
        )
        await monitor.poll()

        let session = try XCTUnwrap(monitor.sessions.first)
        XCTAssertEqual(session.activeSubagents.map(\.id), ["toolu_fresh"])
        // The stale file is NOT deleted on disk — UI drop only.
        XCTAssertTrue(FileManager.default.fileExists(atPath: agentsDir.appendingPathComponent("toolu_old.json").path))
    }

    func testLegacySubagentMarkerCoexistsWithEmptyAgentsDir() async throws {
        let dir = tempStateDir()
        let sid = "s1"
        let pid = writeInfoFile(in: dir, sessionId: sid)
        let body = #"{"session_id":"\#(sid)","pid":\#(pid),"agent_type":"general-purpose","timestamp":\#(Int(Date().timeIntervalSince1970))}"#
        try body.write(to: dir.appendingPathComponent("\(sid)-subagent"), atomically: true, encoding: .utf8)

        let monitor = ProcessMonitor(
            shell: emptyShell(),
            pollingInterval: 1,
            stateDir: dir,
            isLiveClaudeProcessCheck: { _ in true }
        )
        await monitor.poll()

        let session = try XCTUnwrap(monitor.sessions.first)
        XCTAssertEqual(session.subagentType, "general-purpose")
        XCTAssertTrue(session.activeSubagents.isEmpty)
    }

    func testResetSessionStateClearsAgentsDir() throws {
        let tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("clyde-resetagents-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
        let previousOverride = AppPaths.homeOverride
        AppPaths.homeOverride = tempHome
        defer {
            AppPaths.homeOverride = previousOverride
            try? FileManager.default.removeItem(at: tempHome)
        }

        let sid = "s1"
        try FileManager.default.createDirectory(at: AppPaths.stateDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: AppPaths.eventsDir, withIntermediateDirectories: true)

        let agentsDir = AppPaths.stateDir.appendingPathComponent("\(sid)-agents")
        try FileManager.default.createDirectory(at: agentsDir, withIntermediateDirectories: true)
        let body = #"{"tool_use_id":"toolu_a","subagent_type":"Explore","summary":"x","started_at":\#(Int(Date().timeIntervalSince1970))}"#
        try body.write(to: agentsDir.appendingPathComponent("toolu_a.json"), atomically: true, encoding: .utf8)

        let viewModel = AppViewModel()
        let session = Session(pid: 99999, workingDirectory: "/tmp", sessionId: sid)
        viewModel.resetSession(session)

        XCTAssertFalse(FileManager.default.fileExists(atPath: agentsDir.path))
    }
}
