import XCTest
@testable import Clyde

@MainActor
final class SessionListViewModelTests: XCTestCase {
    func testStatusSummaryFromProcessMonitor() async {
        let shell = MockShellExecutor()
        shell.responses["pgrep -x claude"] = "1234\n5678"
        shell.responses["ps -p"] = "20.0"
        shell.responses["lsof"] = "n/Users/me/test"

        let monitor = ProcessMonitor(shell: shell, pollingInterval: 1)
        let vm = SessionListViewModel(processMonitor: monitor)
        await monitor.poll()

        XCTAssertEqual(vm.sessionCount, 2)
        XCTAssertEqual(vm.busyCount, 2)
    }

    func testTerminalSessionsStartEmpty() {
        let monitor = ProcessMonitor(pollingInterval: 1)
        let vm = SessionListViewModel(processMonitor: monitor)
        XCTAssertTrue(vm.terminalSessions.isEmpty)
        XCTAssertNil(vm.selectedSession)
    }
}
