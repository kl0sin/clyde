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
        let monitor = ProcessMonitor(shell: shell, pollingInterval: 1, stateDir: tempDir)
        let vm = AppViewModel(processMonitor: monitor)
        await monitor.poll()

        XCTAssertEqual(vm.clydeState, .busy)
    }
}
