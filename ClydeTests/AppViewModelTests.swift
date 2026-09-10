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

    @MainActor
    func testRateLimitedSessionIsExhausted() {
        let monitor = ProcessMonitor()
        let vm = AppViewModel(processMonitor: monitor)
        var s = Session(pid: 4242, workingDirectory: "/tmp/x", status: .busy)
        s.errorReason = "rate_limit"
        monitor.sessions = [s]
        XCTAssertTrue(vm.hasRateLimitedSession)
        s.errorReason = nil
        monitor.sessions = [s]
        XCTAssertFalse(vm.hasRateLimitedSession)
    }

    /// Dismissing the offer must actually persist — the chip's × only
    /// closes the card, so `dismissCurrentBanner()` is the only path
    /// that writes `offerDismissedKey`.
    func testDismissingTheOfferPersistsTheDecline() {
        defer { UserDefaults.standard.removeObject(forKey: UsageLimitsInstaller.offerDismissedKey) }
        let vm = AppViewModel()
        vm.hookHealthIssue = .usageLimitsAvailable
        vm.dismissCurrentBanner()
        XCTAssertNil(vm.hookHealthIssue)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: UsageLimitsInstaller.offerDismissedKey))
    }

    /// The rate_limit marker and the usage snapshot come from two
    /// watchers with no ordering between them. A window that is only
    /// exhausted because of the marker (JSON still shows headroom)
    /// must still be tracked, so its later reset gets announced.
    func testRateLimitOnlyExhaustionIsObserved() throws {
        let tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("clyde-ratelimitonly-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
        AppPaths.homeOverride = tempHome
        HookInstaller.claudeInstalledOverride = true
        UserDefaults.standard.set(true, forKey: UsageLimitsInstaller.settingKey)
        defer {
            // The defaults key goes first: `refreshUsageHealth()` now
            // reads `UsageLimitsInstaller.isEnabled` off it, not the
            // VM's in-memory `showUsageLimits`, so a `hookHealTimer`
            // tick that survives this test (nothing here stops it)
            // finds the feature off before it ever finds the sandbox
            // gone — no late repair landing in a real ~/.claude.
            UserDefaults.standard.removeObject(forKey: UsageLimitsInstaller.settingKey)
            AppPaths.homeOverride = nil
            HookInstaller.claudeInstalledOverride = nil
            try? FileManager.default.removeItem(at: tempHome)
        }

        let vm = AppViewModel()
        let resetsAt = Date().addingTimeInterval(3600)
        let limits = UsageLimits(fiveHour: UsageWindow(usedPercentage: 42, resetsAt: resetsAt),
                                  sevenDay: nil, updatedAt: Date(), sessionID: nil, modelName: nil)

        vm.evaluateUsageAlerts(limits: limits, rateLimited: false)
        XCTAssertNil(vm.usageAlerts.exhaustedResetsAt)

        vm.evaluateUsageAlerts(limits: limits, rateLimited: true)
        XCTAssertNotNil(vm.usageAlerts.exhaustedResetsAt)

        let nextWindow = UsageLimits(fiveHour: UsageWindow(usedPercentage: 3, resetsAt: resetsAt.addingTimeInterval(5 * 3600)),
                                      sevenDay: nil, updatedAt: Date(), sessionID: nil, modelName: nil)
        vm.evaluateUsageAlerts(limits: nextWindow, rateLimited: false)
        XCTAssertNil(vm.usageAlerts.exhaustedResetsAt)
    }

    /// Pins that the combined pipeline is actually wired: flipping a
    /// session to rate_limit with no usage snapshot at all must not
    /// crash or mark the window exhausted (there is no window to be
    /// exhausted). Not asserting on notification delivery — the centre
    /// is unauthorized in tests — only that the pipeline runs.
    func testCombinedPipelineReactsToRateLimitAlone() throws {
        let tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("clyde-combinedpipeline-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
        AppPaths.homeOverride = tempHome
        HookInstaller.claudeInstalledOverride = true
        UserDefaults.standard.set(true, forKey: UsageLimitsInstaller.settingKey)
        defer {
            // The defaults key goes first: `refreshUsageHealth()` now
            // reads `UsageLimitsInstaller.isEnabled` off it, not the
            // VM's in-memory `showUsageLimits`, so a `hookHealTimer`
            // tick that survives this test (nothing here stops it)
            // finds the feature off before it ever finds the sandbox
            // gone — no late repair landing in a real ~/.claude.
            UserDefaults.standard.removeObject(forKey: UsageLimitsInstaller.settingKey)
            AppPaths.homeOverride = nil
            HookInstaller.claudeInstalledOverride = nil
            try? FileManager.default.removeItem(at: tempHome)
        }

        let monitor = ProcessMonitor()
        let vm = AppViewModel(processMonitor: monitor)
        var s = Session(pid: 4343, workingDirectory: "/tmp/y", status: .busy)
        s.errorReason = "rate_limit"
        monitor.sessions = [s]
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertNil(vm.usageAlerts.exhaustedResetsAt)
    }

    /// `usageHealthIssue` must come from a cache `refreshHookHealth()`
    /// populates, not a disk read Settings triggers on every render —
    /// see HookInstallerTests.setUp for the AppPaths.homeOverride
    /// pattern this mirrors.
    func testUsageHealthIsCachedOnRefresh() throws {
        let tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("clyde-usagehealth-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
        AppPaths.homeOverride = tempHome
        HookInstaller.claudeInstalledOverride = true
        // Set the defaults key before constructing the view model so
        // `showUsageLimits` starts true from its property initializer —
        // that path doesn't run `didSet`, so no install is triggered
        // and the "nothing installed yet" assertion below is honest.
        UserDefaults.standard.set(true, forKey: UsageLimitsInstaller.settingKey)
        defer {
            // The defaults key goes first: `refreshUsageHealth()` now
            // reads `UsageLimitsInstaller.isEnabled` off it, not the
            // VM's in-memory `showUsageLimits`, so a `hookHealTimer`
            // tick that survives this test (nothing here stops it)
            // finds the feature off before it ever finds the sandbox
            // gone — no late repair landing in a real ~/.claude.
            UserDefaults.standard.removeObject(forKey: UsageLimitsInstaller.settingKey)
            AppPaths.homeOverride = nil
            HookInstaller.claudeInstalledOverride = nil
            try? FileManager.default.removeItem(at: tempHome)
        }

        let vm = AppViewModel()
        XCTAssertTrue(vm.showUsageLimits)

        vm.refreshHookHealth()
        XCTAssertEqual(vm.usageHealthIssue, .notInstalled)

        try UsageLimitsInstaller.install()
        vm.refreshHookHealth()
        XCTAssertNil(vm.usageHealthIssue)

        // Now prove the guard itself: with the defaults key gone (what
        // every teardown above does first) `refreshUsageHealth()` must
        // do nothing, even with the VM's own `showUsageLimits` still
        // true and a live sandbox to write into — it never gets that
        // far under a fresh, empty home.
        UserDefaults.standard.removeObject(forKey: UsageLimitsInstaller.settingKey)
        let freshHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("clyde-usagehealth-fresh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: freshHome, withIntermediateDirectories: true)
        let previousHome = AppPaths.homeOverride
        AppPaths.homeOverride = freshHome
        defer {
            AppPaths.homeOverride = previousHome
            try? FileManager.default.removeItem(at: freshHome)
        }

        vm.refreshHookHealth()
        XCTAssertNil(vm.usageHealthIssue)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: freshHome.appendingPathComponent(".clyde/usage").path),
            "the guard must hold even though vm.showUsageLimits is still true"
        )
        XCTAssertTrue(vm.showUsageLimits, "sanity: the VM's own property was never touched by the guard")
    }

    /// Turning the feature off must not leave a remembered exhaustion
    /// behind for a later `nil`/false pair to "resolve" into a false
    /// "you can continue" notification.
    func testTurningTheFeatureOffIsNotAReset() throws {
        let tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("clyde-usageoff-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
        AppPaths.homeOverride = tempHome
        HookInstaller.claudeInstalledOverride = true
        UserDefaults.standard.set(true, forKey: UsageLimitsInstaller.settingKey)
        defer {
            // The defaults key goes first: `refreshUsageHealth()` now
            // reads `UsageLimitsInstaller.isEnabled` off it, not the
            // VM's in-memory `showUsageLimits`, so a `hookHealTimer`
            // tick that survives this test (nothing here stops it)
            // finds the feature off before it ever finds the sandbox
            // gone — no late repair landing in a real ~/.claude.
            UserDefaults.standard.removeObject(forKey: UsageLimitsInstaller.settingKey)
            AppPaths.homeOverride = nil
            HookInstaller.claudeInstalledOverride = nil
            try? FileManager.default.removeItem(at: tempHome)
        }

        let vm = AppViewModel()
        XCTAssertTrue(vm.showUsageLimits)

        let exhausted = UsageLimits(fiveHour: UsageWindow(usedPercentage: 100, resetsAt: Date().addingTimeInterval(3600)),
                                     sevenDay: nil, updatedAt: Date(), sessionID: nil, modelName: nil)
        vm.evaluateUsageAlerts(limits: exhausted, rateLimited: false)
        XCTAssertNotNil(vm.usageAlerts.exhaustedResetsAt)

        vm.showUsageLimits = false
        vm.evaluateUsageAlerts(limits: nil, rateLimited: false)
        XCTAssertNil(vm.usageAlerts.exhaustedResetsAt)
    }

    /// Mirrors `HookInstaller`'s self-repair: an outdated wrapper is put
    /// back on the same `refreshHookHealth()` call that discovers it,
    /// not just reported into a Settings pane nobody is looking at.
    func testAnOutdatedWrapperIsRepairedOnRefresh() throws {
        let tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("clyde-usagerepair-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
        AppPaths.homeOverride = tempHome
        HookInstaller.claudeInstalledOverride = true
        UserDefaults.standard.set(true, forKey: UsageLimitsInstaller.settingKey)
        defer {
            // The defaults key goes first: `refreshUsageHealth()` now
            // reads `UsageLimitsInstaller.isEnabled` off it, not the
            // VM's in-memory `showUsageLimits`, so a `hookHealTimer`
            // tick that survives this test (nothing here stops it)
            // finds the feature off before it ever finds the sandbox
            // gone — no late repair landing in a real ~/.claude.
            UserDefaults.standard.removeObject(forKey: UsageLimitsInstaller.settingKey)
            AppPaths.homeOverride = nil
            HookInstaller.claudeInstalledOverride = nil
            try? FileManager.default.removeItem(at: tempHome)
        }

        try UsageLimitsInstaller.install()
        let script = try String(contentsOf: AppPaths.clydeStatusLineScript, encoding: .utf8)
        let downgraded = script.replacingOccurrences(
            of: "# clyde-statusline-version: \(UsageLimitsInstaller.currentScriptVersion)",
            with: "# clyde-statusline-version: 0")
        try downgraded.write(to: AppPaths.clydeStatusLineScript, atomically: true, encoding: .utf8)

        let vm = AppViewModel()
        vm.refreshHookHealth()

        XCTAssertNil(vm.usageHealthIssue)
        XCTAssertEqual(UsageLimitsInstaller.installedScriptVersion(), UsageLimitsInstaller.currentScriptVersion)
    }

    /// A slot something else took after Clyde is reported, not adopted —
    /// silently overwriting another tool's status line would be wrong.
    func testADisplacedWrapperIsNotAdopted() throws {
        let tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("clyde-usagedisplaced-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
        AppPaths.homeOverride = tempHome
        HookInstaller.claudeInstalledOverride = true
        UserDefaults.standard.set(true, forKey: UsageLimitsInstaller.settingKey)
        defer {
            // The defaults key goes first: `refreshUsageHealth()` now
            // reads `UsageLimitsInstaller.isEnabled` off it, not the
            // VM's in-memory `showUsageLimits`, so a `hookHealTimer`
            // tick that survives this test (nothing here stops it)
            // finds the feature off before it ever finds the sandbox
            // gone — no late repair landing in a real ~/.claude.
            UserDefaults.standard.removeObject(forKey: UsageLimitsInstaller.settingKey)
            AppPaths.homeOverride = nil
            HookInstaller.claudeInstalledOverride = nil
            try? FileManager.default.removeItem(at: tempHome)
        }

        try UsageLimitsInstaller.install()
        let settings: [String: Any] = ["statusLine": ["type": "command", "command": "~/bin/other.sh"]]
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: AppPaths.claudeSettingsFile, options: .atomic)

        let vm = AppViewModel()
        vm.refreshHookHealth()

        XCTAssertEqual(vm.usageHealthIssue, .displaced(by: "~/bin/other.sh"))
        let after = try JSONSerialization.jsonObject(with: Data(contentsOf: AppPaths.claudeSettingsFile)) as? [String: Any]
        let command = (after?["statusLine"] as? [String: Any])?["command"] as? String
        XCTAssertEqual(command, "~/bin/other.sh")
    }
}
