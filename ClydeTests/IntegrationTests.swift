import XCTest
@testable import Clyde

@MainActor
final class IntegrationTests: XCTestCase {

    private func tempStateDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clyde-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeInfo(in dir: URL, sessionId: String, cwd: String) {
        let pid = getpid()
        let body = #"{"session_id":"\#(sessionId)","pid":\#(pid),"cwd":"\#(cwd)","started_at":0}"#
        try? body.write(to: dir.appendingPathComponent("\(sessionId)-info"), atomically: true, encoding: .utf8)
    }

    private func writeBusy(in dir: URL, sessionId: String, cwd: String) {
        let pid = getpid()
        let body = #"{"session_id":"\#(sessionId)","pid":\#(pid),"cwd":"\#(cwd)","timestamp":\#(Int(Date().timeIntervalSince1970))}"#
        try? body.write(to: dir.appendingPathComponent("\(sessionId)-busy"), atomically: true, encoding: .utf8)
    }

    func testFullPollingCycleUpdatesViewModels() async {
        let dir = tempStateDir()
        // NOTE: only one session because all hook fixtures must use the
        // current process's PID to survive the kill(pid, 0) liveness check;
        // we can't fake multiple distinct live PIDs in a unit test.
        let sid = UUID().uuidString
        writeInfo(in: dir, sessionId: sid, cwd: "/Users/me/project-a")
        writeBusy(in: dir, sessionId: sid, cwd: "/Users/me/project-a")

        // Mock pgrep to return nothing so the test doesn't pick up real
        // claude processes running on the host.
        let shell = MockShellExecutor()
        shell.responses["pgrep"] = ""
        let monitor = ProcessMonitor(shell: shell, pollingInterval: 1, stateDir: dir, isLiveClaudeProcessCheck: { _ in true })
        let appVM = AppViewModel(processMonitor: monitor)
        let sessionVM = SessionListViewModel(processMonitor: monitor)

        await monitor.poll()

        XCTAssertEqual(appVM.clydeState, .busy)
        XCTAssertEqual(appVM.statusText, "1 working")
        XCTAssertEqual(sessionVM.sessionCount, 1)
        XCTAssertEqual(sessionVM.busyCount, 1)

        // Session ends — SessionEnd hook would remove both files.
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(sid)-info"))
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(sid)-busy"))
        await monitor.poll()

        // The row is now a ghost — visible to the UI for ~5 min, but
        // counters and clydeState exclude it because the live process is gone.
        XCTAssertEqual(appVM.clydeState, .sleeping)
        XCTAssertEqual(appVM.statusText, "no sessions")
        XCTAssertEqual(sessionVM.sessionCount, 0)
        XCTAssertEqual(monitor.sessions.count, 1, "ghost row should remain in the raw list")
        XCTAssertTrue(monitor.sessions.first?.isGhost ?? false)
    }

    func testNotificationFiringOnIdleTransition() async {
        let dir = tempStateDir()
        let sid = UUID().uuidString
        writeInfo(in: dir, sessionId: sid, cwd: "/Users/me/shipyard")
        writeBusy(in: dir, sessionId: sid, cwd: "/Users/me/shipyard")

        let shell = MockShellExecutor()
        shell.responses["pgrep"] = ""
        let monitor = ProcessMonitor(shell: shell, pollingInterval: 1, stateDir: dir, isLiveClaudeProcessCheck: { _ in true })

        var notifiedSession: Session?
        monitor.onSessionBecameIdle = { session in
            notifiedSession = session
        }

        // First poll: busy (busy marker present)
        await monitor.poll()
        XCTAssertNil(notifiedSession)
        XCTAssertEqual(monitor.sessions.first?.status, .busy)

        // Stop hook removes the busy marker → session becomes idle, notification fires.
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(sid)-busy"))
        await monitor.poll()

        XCTAssertNotNil(notifiedSession)
        XCTAssertEqual(notifiedSession?.displayName, "shipyard")
    }
}
