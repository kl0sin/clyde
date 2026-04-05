import XCTest
@testable import Clyde

@MainActor
final class IntegrationTests: XCTestCase {
    func testFullPollingCycleUpdatesViewModels() async {
        let shell = MockShellExecutor()
        shell.responses["pgrep -x claude"] = "1111\n2222"
        shell.responses["ps -p"] = "30.0"
        shell.responses["lsof"] = "n/Users/me/project-a"

        let monitor = ProcessMonitor(shell: shell, pollingInterval: 1)
        let appVM = AppViewModel(processMonitor: monitor)
        let sessionVM = SessionListViewModel(processMonitor: monitor)

        // Poll: 2 busy sessions
        await monitor.poll()

        XCTAssertEqual(appVM.clydeState, .busy)
        XCTAssertEqual(appVM.statusText, "2 active")
        XCTAssertEqual(sessionVM.sessionCount, 2)
        XCTAssertEqual(sessionVM.busyCount, 2)

        // Sessions end
        shell.responses["pgrep -x claude"] = ""
        await monitor.poll()

        XCTAssertEqual(appVM.clydeState, .sleeping)
        XCTAssertEqual(appVM.statusText, "sleeping")
        XCTAssertEqual(sessionVM.sessionCount, 0)
    }

    func testNotificationFiringOnIdleTransition() async {
        let shell = MockShellExecutor()
        shell.responses["pgrep -x claude"] = "1234"
        shell.responses["ps -p"] = "30.0"
        shell.responses["lsof"] = "n/Users/me/shipyard"

        let monitor = ProcessMonitor(shell: shell, pollingInterval: 1)

        var notifiedSession: Session?
        monitor.onSessionBecameIdle = { session in
            notifiedSession = session
        }

        // First poll: busy
        await monitor.poll()
        XCTAssertNil(notifiedSession)

        // Two consecutive idle reads to trigger
        shell.responses["ps -p"] = "0.0"
        await monitor.poll() // 1st idle read
        XCTAssertNil(notifiedSession) // Not yet — need 2 consecutive

        await monitor.poll() // 2nd idle read
        XCTAssertNotNil(notifiedSession)
        XCTAssertEqual(notifiedSession?.displayName, "shipyard")
    }
}
