import XCTest
@testable import Clyde

@MainActor
final class SessionListViewModelTests: XCTestCase {
    func testStatusSummary() async {
        let shell = MockShellExecutor()
        shell.responses["pgrep -x claude"] = "1234\n5678"
        shell.responses["pgrep -P"] = "9999" // children = busy
        shell.responses["ps -o stat=,args= -p"] = "S+ /bin/bash some-tool"
        shell.responses["lsof"] = "n/Users/me/test/.claude/settings.local.json"

        let monitor = ProcessMonitor(shell: shell, pollingInterval: 1)
        let vm = SessionListViewModel(processMonitor: monitor)
        await monitor.poll()

        XCTAssertEqual(vm.sessionCount, 2)
        XCTAssertEqual(vm.busyCount, 2)
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
