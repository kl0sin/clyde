import XCTest
@testable import Clyde

@MainActor
final class SessionListViewModelTests: XCTestCase {
    func testStatusSummary() async {
        let shell = MockShellExecutor()
        shell.responses["pgrep -x claude"] = "1234\n5678"
        shell.responses["pgrep -P"] = "9999" // children = busy
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
}
