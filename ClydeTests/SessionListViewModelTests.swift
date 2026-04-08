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
