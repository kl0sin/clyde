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
        // Stub the claude-identity check: in a unit test the PID we
        // wrote into the busy marker is the test process itself, which
        // is obviously not "claude". The real check would (correctly)
        // reject it and ProcessMonitor would delete the marker before
        // we got to assert anything.
        let monitor = ProcessMonitor(
            shell: shell,
            pollingInterval: 1,
            stateDir: tempDir,
            isLiveClaudeProcessCheck: { _ in true }
        )
        let vm = AppViewModel(processMonitor: monitor)
        await monitor.poll()

        XCTAssertEqual(vm.clydeState, .busy)
    }

    @MainActor
    func testResetSessionRemovesAllHookStateFilesForSessionId() throws {
        // Redirect AppPaths to a throwaway tempdir so we don't touch
        // the user's real ~/.clyde/. AppPaths.homeOverride is the
        // codebase's documented test seam for exactly this purpose.
        let tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("clyde-resetsession-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
        let previousOverride = AppPaths.homeOverride
        AppPaths.homeOverride = tempHome
        defer {
            AppPaths.homeOverride = previousOverride
            try? FileManager.default.removeItem(at: tempHome)
        }

        try FileManager.default.createDirectory(at: AppPaths.stateDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: AppPaths.eventsDir, withIntermediateDirectories: true)

        let sid = UUID().uuidString
        let suffixes = ["info", "busy", "error", "subagent", "tool", "plan"]
        for suffix in suffixes {
            try "{}".write(
                to: AppPaths.stateDir.appendingPathComponent("\(sid)-\(suffix)"),
                atomically: true,
                encoding: .utf8
            )
        }
        try "{}".write(
            to: AppPaths.eventsDir.appendingPathComponent("\(sid).json"),
            atomically: true,
            encoding: .utf8
        )

        let viewModel = AppViewModel()
        let session = Session(pid: 99999, workingDirectory: "/tmp", sessionId: sid)
        viewModel.resetSession(session)

        for suffix in suffixes {
            let url = AppPaths.stateDir.appendingPathComponent("\(sid)-\(suffix)")
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: url.path),
                "Expected \(url.lastPathComponent) to be removed by resetSession"
            )
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: AppPaths.eventsDir.appendingPathComponent("\(sid).json").path
            )
        )
    }
}
