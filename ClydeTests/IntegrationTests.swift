import XCTest
@testable import Clyde

@MainActor
final class IntegrationTests: XCTestCase {
    func testFullPollingCycleUpdatesViewModels() async {
        let shell = MockShellExecutor()
        shell.responses["pgrep -x claude"] = "1111\n2222"
        shell.responses["pgrep -P"] = "9999" // children = busy
        shell.responses["ps -o stat=,args= -p"] = "S+ /bin/bash some-tool"
        shell.responses["lsof"] = "n/Users/me/project-a/.claude/settings.local.json"

        let monitor = ProcessMonitor(shell: shell, pollingInterval: 1)
        let appVM = AppViewModel(processMonitor: monitor)
        let sessionVM = SessionListViewModel(processMonitor: monitor)

        await monitor.poll()

        XCTAssertEqual(appVM.clydeState, .busy)
        XCTAssertEqual(appVM.statusText, "2 working")
        XCTAssertEqual(sessionVM.sessionCount, 2)
        XCTAssertEqual(sessionVM.busyCount, 2)

        // Sessions end
        shell.responses["pgrep -x claude"] = ""
        await monitor.poll()

        XCTAssertEqual(appVM.clydeState, .sleeping)
        XCTAssertEqual(appVM.statusText, "no sessions")
        XCTAssertEqual(sessionVM.sessionCount, 0)
    }

    func testNotificationFiringOnIdleTransition() async {
        let shell = MockShellExecutor()
        shell.responses["pgrep -x claude"] = "1234"
        shell.responses["pgrep -P"] = "9999" // busy
        shell.responses["ps -o stat=,args= -p"] = "S+ /bin/bash some-tool"
        shell.responses["lsof"] = "n/Users/me/shipyard/.claude/settings.local.json"

        let monitor = ProcessMonitor(shell: shell, pollingInterval: 1)

        var notifiedSession: Session?
        monitor.onSessionBecameIdle = { session in
            notifiedSession = session
        }

        // First poll: busy (has children)
        await monitor.poll()
        XCTAssertNil(notifiedSession)
        XCTAssertEqual(monitor.sessions.first?.status, .busy)

        // Children gone = idle, notification fires immediately
        shell.responses.removeValue(forKey: "pgrep -P")
        shell.responses.removeValue(forKey: "ps -o stat=,args= -p")
        await monitor.poll()

        XCTAssertNotNil(notifiedSession)
        XCTAssertEqual(notifiedSession?.displayName, "shipyard")
    }
}
