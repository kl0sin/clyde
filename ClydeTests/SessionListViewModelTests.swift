import XCTest
@testable import Clyde

@MainActor
final class SessionListViewModelTests: XCTestCase {
    func testStatusSummary() async {
        // Hook fixtures must use the current process PID to survive
        // kill(pid, 0) liveness check, so this test only validates a single
        // session counted as busy via its busy marker.
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clyde-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let sid = UUID().uuidString
        let pid = getpid()
        let infoBody = #"{"session_id":"\#(sid)","pid":\#(pid),"cwd":"/tmp","started_at":0}"#
        let busyBody = #"{"session_id":"\#(sid)","pid":\#(pid),"cwd":"/tmp","timestamp":0}"#
        try? infoBody.write(to: tempDir.appendingPathComponent("\(sid)-info"), atomically: true, encoding: .utf8)
        try? busyBody.write(to: tempDir.appendingPathComponent("\(sid)-busy"), atomically: true, encoding: .utf8)

        let shell = MockShellExecutor()
        shell.responses["pgrep"] = ""
        let monitor = ProcessMonitor(shell: shell, pollingInterval: 1, stateDir: tempDir, isLiveClaudeProcessCheck: { _ in true })
        let vm = SessionListViewModel(processMonitor: monitor)
        await monitor.poll()

        XCTAssertEqual(vm.sessionCount, 1)
        XCTAssertEqual(vm.busyCount, 1)
    }

    /// Regression: a session that is BOTH busy AND flagged for
    /// attention used to be counted twice — once in `busyCount`, once
    /// in `attentionCount` — producing header strings like
    /// "1 attention · 1 working · 4 ready" for a list of only 5 actual
    /// sessions, plus a "1 processing" pill in the bottom SummaryBar
    /// for the same already-attention session. Pin the contract:
    /// the three counters are mutually exclusive, attention takes
    /// priority, and they always sum to `sessionCount`.
    func testCountersAreMutuallyExclusiveAcrossAttention() async {
        let stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clyde-tests-state-\(UUID().uuidString)")
        let eventsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clyde-tests-events-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: eventsDir, withIntermediateDirectories: true)

        // Two live sessions, both busy. We'll then flag one of them
        // for attention via an event file in the AttentionMonitor's
        // events dir, and assert it shows up only once.
        let sidA = UUID().uuidString
        let sidB = UUID().uuidString
        let pid = getpid()
        let infoA = #"{"session_id":"\#(sidA)","pid":\#(pid),"cwd":"/tmp/a","started_at":0}"#
        let infoB = #"{"session_id":"\#(sidB)","pid":\#(pid),"cwd":"/tmp/b","started_at":0}"#
        let busyA = #"{"session_id":"\#(sidA)","pid":\#(pid),"cwd":"/tmp/a","timestamp":0}"#
        let busyB = #"{"session_id":"\#(sidB)","pid":\#(pid),"cwd":"/tmp/b","timestamp":0}"#
        // We can't actually have two distinct alive PIDs in a unit
        // test (only getpid() is reliable), so this test exercises
        // the COUNTING logic against one session whose pid happens
        // to be in both the busy set AND the attention set. The
        // counters are still expected to be: 1 attention, 0 busy,
        // 0 idle, 1 total. The bug we're regression-testing
        // produced: 1 attention, 1 busy, 0 idle, 2 total.
        try? infoA.write(to: stateDir.appendingPathComponent("\(sidA)-info"), atomically: true, encoding: .utf8)
        try? busyA.write(to: stateDir.appendingPathComponent("\(sidA)-busy"), atomically: true, encoding: .utf8)
        _ = infoB; _ = busyB

        // Plant an attention event for the same PID.
        let attentionEvent = #"{"pid":\#(pid),"session_id":"\#(sidA)","event":"PermissionRequest","timestamp":\#(Int(Date().timeIntervalSince1970))}"#
        try? attentionEvent.write(
            to: eventsDir.appendingPathComponent("\(sidA).json"),
            atomically: true,
            encoding: .utf8
        )

        let shell = MockShellExecutor()
        shell.responses["pgrep"] = ""
        let monitor = ProcessMonitor(
            shell: shell,
            pollingInterval: 1,
            stateDir: stateDir,
            isLiveClaudeProcessCheck: { _ in true }
        )
        let attention = AttentionMonitor(eventsDir: eventsDir)
        attention.start()
        defer { attention.stop() }

        let vm = SessionListViewModel(processMonitor: monitor, attentionMonitor: attention)
        await monitor.poll()

        XCTAssertEqual(vm.sessionCount, 1, "expected 1 live session")
        XCTAssertEqual(vm.attentionCount, 1, "session must be counted as attention")
        XCTAssertEqual(vm.busyCount, 0, "attention session must NOT also count as busy")
        XCTAssertEqual(vm.idleCount, 0, "attention session must NOT also count as idle")
        XCTAssertEqual(
            vm.attentionCount + vm.busyCount + vm.idleCount,
            vm.sessionCount,
            "the three counters must always sum to sessionCount"
        )
    }

    func testSessionsEmpty() {
        let monitor = ProcessMonitor(pollingInterval: 1)
        let vm = SessionListViewModel(processMonitor: monitor)
        XCTAssertTrue(vm.sessions.isEmpty)
        XCTAssertEqual(vm.sessionCount, 0)
    }

    // MARK: - looksLikeSessionId

    func testLooksLikeSessionIdAcceptsUUID() {
        XCTAssertTrue(SessionListViewModel.looksLikeSessionId("550e8400-e29b-41d4-a716-446655440000"))
    }

    func testLooksLikeSessionIdRejectsCWDPath() {
        XCTAssertFalse(SessionListViewModel.looksLikeSessionId("/Users/me/Projects/shipyard"))
    }

    func testLooksLikeSessionIdRejectsEmpty() {
        XCTAssertFalse(SessionListViewModel.looksLikeSessionId(""))
    }

    func testLooksLikeSessionIdRejectsRandomString() {
        XCTAssertFalse(SessionListViewModel.looksLikeSessionId("not-a-uuid"))
    }

    func testLooksLikeSessionIdRejectsPathWithoutSlashesButTooShort() {
        // Anything that isn't a valid UUID string is rejected, even short non-path text.
        XCTAssertFalse(SessionListViewModel.looksLikeSessionId("12345"))
    }
}
