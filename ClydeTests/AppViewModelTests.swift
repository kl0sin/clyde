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

    // MARK: - Banner dismiss behaviour

    /// User clicks × on the cleat advisory → the banner immediately
    /// disappears. The dismiss state lives in memory on AppViewModel
    /// so an app restart will surface it again (covered by
    /// `testDismissDoesNotPersistAcrossAppViewModelInstances`).
    func testDismissCurrentBannerClearsCleatAdvisory() {
        let vm = AppViewModel()
        vm.hookHealthIssue = .cleatHooksCapDisabled
        vm.dismissCurrentBanner()
        XCTAssertNil(vm.hookHealthIssue, "× on a dismissable banner must hide it")
    }

    /// Critical issues (anything that breaks tracking) must NOT be
    /// dismissable — the × isn't even rendered for them, but
    /// defence-in-depth: calling dismissCurrentBanner with one set
    /// must be a no-op so we never accidentally hide a real problem.
    func testDismissCurrentBannerIsNoOpForCriticalIssue() {
        let vm = AppViewModel()
        vm.hookHealthIssue = .outdated(installed: 1, current: 2)
        vm.dismissCurrentBanner()
        XCTAssertEqual(
            vm.hookHealthIssue,
            .outdated(installed: 1, current: 2),
            "non-dismissable issues must survive dismissCurrentBanner"
        )
    }

    /// dismissCurrentBanner without any issue set is also a no-op —
    /// shouldn't crash or change state. Trivial but cheap.
    func testDismissCurrentBannerIsNoOpWhenNoIssue() {
        let vm = AppViewModel()
        vm.hookHealthIssue = nil
        vm.dismissCurrentBanner()
        XCTAssertNil(vm.hookHealthIssue)
    }

    /// The dismiss set lives on the AppViewModel instance, not in
    /// UserDefaults. So creating a fresh AppViewModel (the equivalent
    /// of relaunching the app) and assigning the same issue must
    /// surface it again — no spillover from a previous instance's
    /// dismissals.
    func testDismissDoesNotPersistAcrossAppViewModelInstances() {
        let vm1 = AppViewModel()
        vm1.hookHealthIssue = .cleatHooksCapDisabled
        vm1.dismissCurrentBanner()
        XCTAssertNil(vm1.hookHealthIssue)

        // Fresh instance — represents an app relaunch.
        let vm2 = AppViewModel()
        vm2.hookHealthIssue = .cleatHooksCapDisabled
        // No call to dismiss; the banner stays visible.
        XCTAssertEqual(vm2.hookHealthIssue, .cleatHooksCapDisabled)
    }
}
