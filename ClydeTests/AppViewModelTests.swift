import XCTest
@testable import Clyde

@MainActor
final class AppViewModelTests: XCTestCase {
    func testInitialStateIsCollapsed() {
        let vm = AppViewModel()
        XCTAssertTrue(vm.isCollapsed)
    }

    func testToggleExpandsAndCollapses() {
        let vm = AppViewModel()
        vm.toggleExpanded()
        XCTAssertFalse(vm.isCollapsed)
        vm.toggleExpanded()
        XCTAssertTrue(vm.isCollapsed)
    }

    func testClydeStateFromProcessMonitor() async {
        let shell = MockShellExecutor()
        shell.responses["pgrep -x claude"] = "1234"
        shell.responses["ps -p"] = "20.0"
        shell.responses["lsof"] = "n/Users/me/test"

        let monitor = ProcessMonitor(shell: shell, pollingInterval: 1)
        let vm = AppViewModel(processMonitor: monitor)
        await monitor.poll()

        XCTAssertEqual(vm.clydeState, .busy)
    }
}
