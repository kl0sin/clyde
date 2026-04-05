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

final class ProcessMonitorTests: XCTestCase {
    @MainActor
    func testDiscoversPIDs() async {
        let shell = MockShellExecutor()
        shell.responses["pgrep -x claude"] = "1234\n5678"
        let monitor = ProcessMonitor(shell: shell, pollingInterval: 1)

        let pids = await monitor.discoverPIDs()
        XCTAssertEqual(pids, [1234, 5678])
    }

    @MainActor
    func testDiscoversPIDsReturnsEmptyForNoProcesses() async {
        let shell = MockShellExecutor()
        shell.responses["pgrep -x claude"] = ""
        let monitor = ProcessMonitor(shell: shell, pollingInterval: 1)

        let pids = await monitor.discoverPIDs()
        XCTAssertEqual(pids, [])
    }

    @MainActor
    func testClassifiesHighCPUAsBusy() async {
        let shell = MockShellExecutor()
        shell.responses["ps -p"] = "25.3"
        let monitor = ProcessMonitor(shell: shell, pollingInterval: 1)

        let status = await monitor.classifyStatus(pid: 1234)
        XCTAssertEqual(status, .busy)
    }

    @MainActor
    func testClassifiesLowCPUAsIdle() async {
        let shell = MockShellExecutor()
        shell.responses["ps -p"] = "0.0"
        let monitor = ProcessMonitor(shell: shell, pollingInterval: 1)

        let status = await monitor.classifyStatus(pid: 1234)
        XCTAssertEqual(status, .idle)
    }

    @MainActor
    func testDetectsWorkingDirectory() async {
        let shell = MockShellExecutor()
        shell.responses["lsof"] = "n/Users/me/Projects/shipyard"
        let monitor = ProcessMonitor(shell: shell, pollingInterval: 1)

        let cwd = await monitor.detectCWD(pid: 1234)
        XCTAssertEqual(cwd, "/Users/me/Projects/shipyard")
    }

    @MainActor
    func testPollBuildsSessionList() async {
        let shell = MockShellExecutor()
        shell.responses["pgrep -x claude"] = "1234"
        shell.responses["ps -p"] = "15.0"
        shell.responses["lsof"] = "n/Users/me/Projects/shipyard"
        let monitor = ProcessMonitor(shell: shell, pollingInterval: 1)

        await monitor.poll()
        XCTAssertEqual(monitor.sessions.count, 1)
        XCTAssertEqual(monitor.sessions.first?.pid, 1234)
        XCTAssertEqual(monitor.sessions.first?.status, .busy)
        XCTAssertEqual(monitor.sessions.first?.workingDirectory, "/Users/me/Projects/shipyard")
    }

    @MainActor
    func testPollRemovesEndedSessions() async {
        let shell = MockShellExecutor()
        shell.responses["pgrep -x claude"] = "1234"
        shell.responses["ps -p"] = "15.0"
        shell.responses["lsof"] = "n/Users/me/test"
        let monitor = ProcessMonitor(shell: shell, pollingInterval: 1)

        await monitor.poll()
        XCTAssertEqual(monitor.sessions.count, 1)

        shell.responses["pgrep -x claude"] = ""
        await monitor.poll()
        XCTAssertEqual(monitor.sessions.count, 0)
    }

    @MainActor
    func testClydeStateIsBusyWhenAnySessionBusy() async {
        let shell = MockShellExecutor()
        shell.responses["pgrep -x claude"] = "1234"
        shell.responses["ps -p"] = "20.0"
        shell.responses["lsof"] = "n/Users/me/test"
        let monitor = ProcessMonitor(shell: shell, pollingInterval: 1)

        await monitor.poll()
        XCTAssertEqual(monitor.clydeState, .busy)
    }

    @MainActor
    func testClydeStateIsSleepingWhenNoSessions() async {
        let shell = MockShellExecutor()
        shell.responses["pgrep -x claude"] = ""
        let monitor = ProcessMonitor(shell: shell, pollingInterval: 1)

        await monitor.poll()
        XCTAssertEqual(monitor.clydeState, .sleeping)
    }
}
