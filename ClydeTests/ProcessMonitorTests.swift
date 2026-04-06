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

@MainActor
final class ProcessMonitorTests: XCTestCase {
    func testDiscoversPIDs() async {
        let shell = MockShellExecutor()
        shell.responses["pgrep -x claude"] = "1234\n5678"
        let monitor = ProcessMonitor(shell: shell, pollingInterval: 1)

        let pids = await monitor.discoverPIDs()
        XCTAssertEqual(pids, [1234, 5678])
    }

    func testDiscoversPIDsReturnsEmptyForNoProcesses() async {
        let shell = MockShellExecutor()
        shell.responses["pgrep -x claude"] = ""
        let monitor = ProcessMonitor(shell: shell, pollingInterval: 1)

        let pids = await monitor.discoverPIDs()
        XCTAssertEqual(pids, [])
    }

    func testClassifiesBusyWhenChildrenExist() async {
        let shell = MockShellExecutor()
        shell.responses["pgrep -P"] = "9999\n9998"
        shell.responses["ps -o stat=,args= -p"] = "S+ /bin/bash some-tool\nS+ /bin/bash other-tool"
        let monitor = ProcessMonitor(shell: shell, pollingInterval: 1)

        let status = await monitor.classifyStatus(pid: 1234)
        XCTAssertEqual(status, .busy)
    }

    func testClassifiesIdleWhenNoChildren() async {
        let shell = MockShellExecutor()
        let monitor = ProcessMonitor(shell: shell, pollingInterval: 1)

        let status = await monitor.classifyStatus(pid: 1234)
        XCTAssertEqual(status, .idle)
    }

    func testDetectsWorkingDirectory() async {
        let shell = MockShellExecutor()
        shell.responses["lsof"] = "n/Users/me/Projects/shipyard/.claude/settings.local.json"
        let monitor = ProcessMonitor(shell: shell, pollingInterval: 1)

        let cwd = await monitor.detectCWD(pid: 1234)
        XCTAssertEqual(cwd, "/Users/me/Projects/shipyard")
    }

    func testPollBuildsSessionList() async {
        let shell = MockShellExecutor()
        shell.responses["pgrep -x claude"] = "1234"
        shell.responses["pgrep -P"] = "9999"
        shell.responses["ps -o stat=,args= -p"] = "S+ /bin/bash some-tool"
        shell.responses["lsof"] = "n/Users/me/Projects/shipyard/.claude/settings.local.json"
        let monitor = ProcessMonitor(shell: shell, pollingInterval: 1)

        await monitor.poll()
        XCTAssertEqual(monitor.sessions.count, 1)
        XCTAssertEqual(monitor.sessions.first?.pid, 1234)
        XCTAssertEqual(monitor.sessions.first?.status, .busy)
    }

    func testPollRemovesEndedSessions() async {
        let shell = MockShellExecutor()
        shell.responses["pgrep -x claude"] = "1234"
        shell.responses["pgrep -P"] = "9999"
        shell.responses["ps -o stat=,args= -p"] = "S+ /bin/bash some-tool"
        shell.responses["lsof"] = "n/Users/me/test/.claude/settings.local.json"
        let monitor = ProcessMonitor(shell: shell, pollingInterval: 1)

        await monitor.poll()
        XCTAssertEqual(monitor.sessions.count, 1)

        shell.responses["pgrep -x claude"] = ""
        await monitor.poll()
        XCTAssertEqual(monitor.sessions.count, 0)
    }

    func testClydeStateIsBusyWhenAnySessionBusy() async {
        let shell = MockShellExecutor()
        shell.responses["pgrep -x claude"] = "1234"
        shell.responses["pgrep -P"] = "9999"
        shell.responses["ps -o stat=,args= -p"] = "S+ /bin/bash some-tool"
        shell.responses["lsof"] = "n/Users/me/test/.claude/settings.local.json"
        let monitor = ProcessMonitor(shell: shell, pollingInterval: 1)

        await monitor.poll()
        XCTAssertEqual(monitor.clydeState, .busy)
    }

    func testClydeStateIsSleepingWhenNoSessions() async {
        let shell = MockShellExecutor()
        shell.responses["pgrep -x claude"] = ""
        let monitor = ProcessMonitor(shell: shell, pollingInterval: 1)

        await monitor.poll()
        XCTAssertEqual(monitor.clydeState, .sleeping)
    }
}
