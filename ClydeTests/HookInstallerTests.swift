import XCTest
@testable import Clyde

/// Tests for HookInstaller.
///
/// Each test runs against a throwaway temp home directory injected via
/// `AppPaths.homeOverride`, so nothing under the developer's real
/// `~/.claude/` is ever touched. The previous design backed up only
/// `settings.json` and called `HookInstaller.uninstall()` on the user's
/// actual install, which silently deleted the production hook script
/// every time the suite ran.
final class HookInstallerTests: XCTestCase {
    private var tempHome: URL!

    override func setUp() async throws {
        tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("clyde-hookinstaller-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
        AppPaths.homeOverride = tempHome
        // Default to "Claude Code installed" so existing tests aren't
        // forced to deal with the new claudeNotInstalled health check
        // ahead of every assertion. Tests that exercise the missing-
        // Claude path explicitly flip this back to false.
        HookInstaller.claudeInstalledOverride = true
        // Neutralise the cleat probe so healthCheck() doesn't pick up
        // the developer-machine's actual cleat config and bleed into
        // assertions that expect "fully healthy" or specific issues.
        // Tests covering the cleat advisory path set their own overrides.
        CleatProbe.cleatOnPathOverride = false
        // Default to "trusted" so existing healthy-install assertions
        // don't flip depending on whether the machine running the suite
        // has granted the test runner accessibility access.
        HookInstaller.accessibilityTrustedOverride = true
        HookInstaller.inputMonitoringTrustedOverride = true
    }

    override func tearDown() async throws {
        AppPaths.homeOverride = nil
        HookInstaller.claudeInstalledOverride = nil
        CleatProbe.cleatOnPathOverride = nil
        CleatProbe.configPathOverride = nil
        HookInstaller.accessibilityTrustedOverride = nil
        HookInstaller.inputMonitoringTrustedOverride = nil
        if let tempHome {
            try? FileManager.default.removeItem(at: tempHome)
        }
        tempHome = nil
    }

    func testInstallCreatesHookScript() throws {
        try HookInstaller.install()

        XCTAssertTrue(HookInstaller.isInstalled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: AppPaths.clydeHookScript.path))

        // Verify executable permissions
        let attrs = try FileManager.default.attributesOfItem(atPath: AppPaths.clydeHookScript.path)
        let perms = attrs[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms?.int16Value, 0o755)
    }

    func testInstallMergesIntoExistingSettings() throws {
        // Pre-seed settings.json with unrelated existing hook
        let existing: [String: Any] = [
            "hooks": [
                "SessionStart": [
                    ["hooks": [["type": "command", "command": "/some/other/script.sh"]]]
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: existing)
        try FileManager.default.createDirectory(
            at: AppPaths.claudeDir, withIntermediateDirectories: true
        )
        try data.write(to: AppPaths.claudeSettingsFile)

        try HookInstaller.install()

        // Verify existing hook was preserved AND our hook was added
        let newData = try Data(contentsOf: AppPaths.claudeSettingsFile)
        let parsed = try JSONSerialization.jsonObject(with: newData) as! [String: Any]
        let hooks = parsed["hooks"] as! [String: Any]

        XCTAssertNotNil(hooks["SessionStart"], "Existing hook should be preserved")
        XCTAssertNotNil(hooks["PermissionRequest"], "Clyde hook should be added")

        let sessionStart = hooks["SessionStart"] as! [[String: Any]]
        let otherCommand = ((sessionStart.first!["hooks"] as! [[String: Any]]).first!)["command"] as! String
        XCTAssertEqual(otherCommand, "/some/other/script.sh")
    }

    func testInstallIsIdempotent() throws {
        // Start from clean state
        try? FileManager.default.removeItem(at: AppPaths.claudeSettingsFile)

        try HookInstaller.install()
        try HookInstaller.install()

        // Should not duplicate the hook
        let data = try Data(contentsOf: AppPaths.claudeSettingsFile)
        let parsed = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let hooks = parsed["hooks"] as! [String: Any]
        let permissionRequest = hooks["PermissionRequest"] as! [[String: Any]]

        XCTAssertEqual(permissionRequest.count, 1, "Should not duplicate on re-install")
    }

    func testUninstallRemovesHookScript() throws {
        try HookInstaller.install()
        try HookInstaller.uninstall()

        XCTAssertFalse(HookInstaller.isInstalled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: AppPaths.clydeHookScript.path))
    }

    func testUninstallPreservesOtherHooks() throws {
        // Seed with our hook + an unrelated hook
        let existing: [String: Any] = [
            "hooks": [
                "SessionStart": [
                    ["hooks": [["type": "command", "command": "/other/script.sh"]]]
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: existing)
        try FileManager.default.createDirectory(at: AppPaths.claudeDir, withIntermediateDirectories: true)
        try data.write(to: AppPaths.claudeSettingsFile)

        try HookInstaller.install()
        try HookInstaller.uninstall()

        // Our hook should be gone, other should remain
        let newData = try Data(contentsOf: AppPaths.claudeSettingsFile)
        let parsed = try JSONSerialization.jsonObject(with: newData) as! [String: Any]
        let hooks = parsed["hooks"] as! [String: Any]

        XCTAssertNotNil(hooks["SessionStart"], "Unrelated hook should remain")
        XCTAssertNil(hooks["PermissionRequest"], "Clyde hook should be removed")
    }

    func testUninstallHandlesMissingSettings() throws {
        // Ensure no settings.json exists
        try? FileManager.default.removeItem(at: AppPaths.claudeSettingsFile)

        // Should not throw
        XCTAssertNoThrow(try HookInstaller.uninstall())
    }

    // MARK: - healthCheck

    func testHealthCheckPassesAfterInstall() throws {
        try HookInstaller.install()
        XCTAssertNil(HookInstaller.healthCheck())
    }

    func testHealthCheckDetectsNotInstalled() throws {
        try? HookInstaller.uninstall()
        try? FileManager.default.removeItem(at: AppPaths.claudeSettingsFile)

        XCTAssertEqual(HookInstaller.healthCheck(), .notInstalled)
    }

    func testHealthCheckDetectsScriptMissing() throws {
        try HookInstaller.install()
        // Yank the script file but leave settings.json registration in place.
        try FileManager.default.removeItem(at: AppPaths.clydeHookScript)

        XCTAssertEqual(HookInstaller.healthCheck(), .scriptMissing)
    }

    func testHealthCheckDetectsScriptNotExecutable() throws {
        try HookInstaller.install()
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: AppPaths.clydeHookScript.path
        )

        XCTAssertEqual(HookInstaller.healthCheck(), .scriptNotExecutable)
    }

    func testHealthCheckDetectsOutdatedScript() throws {
        try HookInstaller.install()
        // Rewrite the script with an older version stamp.
        let installed = try String(contentsOf: AppPaths.clydeHookScript, encoding: .utf8)
        let downgraded = installed.replacingOccurrences(
            of: "clyde-hook-version: \(HookInstaller.currentScriptVersion)",
            with: "clyde-hook-version: 1"
        )
        try downgraded.write(to: AppPaths.clydeHookScript, atomically: true, encoding: .utf8)

        if case .outdated(let installedVersion, let currentVersion) = HookInstaller.healthCheck() {
            XCTAssertEqual(installedVersion, 1)
            XCTAssertEqual(currentVersion, HookInstaller.currentScriptVersion)
        } else {
            XCTFail("Expected .outdated health issue")
        }
    }

    func testHealthCheckDetectsMissingEvent() throws {
        try HookInstaller.install()
        // Strip the SessionStart registration from settings.json so the
        // health check should report it as missing.
        let data = try Data(contentsOf: AppPaths.claudeSettingsFile)
        var settings = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var hooks = settings["hooks"] as! [String: Any]
        hooks.removeValue(forKey: "SessionStart")
        settings["hooks"] = hooks
        let newData = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted])
        try newData.write(to: AppPaths.claudeSettingsFile)

        if case .missingEvents(let names) = HookInstaller.healthCheck() {
            XCTAssertTrue(names.contains("SessionStart"))
        } else {
            XCTFail("Expected .missingEvents health issue")
        }
    }

    /// Accessibility is the only grant ⌃⌘C needs. Input monitoring was
    /// required here for a while, on the evidence of two machines where
    /// accessibility was trusted and the shortcut was dead — a symptom
    /// the monitor never being rebuilt after the grant explains just as
    /// well. Settled from the log: the shortcut fires with input
    /// monitoring explicitly denied.
    func testInputMonitoringIsNotRequired() throws {
        try HookInstaller.install()
        HookInstaller.accessibilityTrustedOverride = true
        HookInstaller.inputMonitoringTrustedOverride = false

        XCTAssertNil(HookInstaller.healthCheck())
    }

    func testMissingAccessibilityIsStillReported() throws {
        try HookInstaller.install()
        HookInstaller.accessibilityTrustedOverride = false
        HookInstaller.inputMonitoringTrustedOverride = false

        XCTAssertEqual(HookInstaller.healthCheck(), .accessibilityNotTrusted)
    }


    func testHealthCheckStaysQuietWhenAccessibilityIsGranted() throws {
        try HookInstaller.install()
        HookInstaller.accessibilityTrustedOverride = true

        XCTAssertNil(HookInstaller.healthCheck())
    }

    /// It is an advisory, not a breakage: tracking works fine without the
    /// hotkey, and a user who never uses it should be able to dismiss the
    /// reminder. It carries a direct link to the right System Settings
    /// pane, because "open Settings" would land them in Clyde's, which
    /// cannot grant the permission.
    func testAccessibilityAdvisoryIsDismissableAndLinksToSystemSettings() {
        let issue = HookInstaller.HealthIssue.accessibilityNotTrusted

        XCTAssertTrue(issue.isDismissable)
        XCTAssertFalse(issue.isActionable, "Clyde's own Settings cannot grant this")
        XCTAssertNotNil(issue.bannerActionTitle)
        XCTAssertEqual(issue.bannerActionURL?.absoluteString,
                       "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    /// A broken hook install means Clyde tracks nothing at all; a missing
    /// hotkey permission is a convenience. The severe one has to win.
    func testBrokenHookInstallOutranksAccessibilityAdvisory() throws {
        try HookInstaller.install()
        try FileManager.default.removeItem(at: AppPaths.clydeHookScript)
        HookInstaller.accessibilityTrustedOverride = false

        XCTAssertEqual(HookInstaller.healthCheck(), .scriptMissing)
    }

    // MARK: - Error paths

    /// The worst thing HookInstaller can do is not "fail to install" —
    /// it's silently replacing the user's entire Claude Code config with
    /// nothing but Clyde's hooks. An unparseable settings.json (truncated
    /// write, a hand-edited trailing comma) parsed to nil, which the merge
    /// treated as "no existing settings", so model, permissions, env,
    /// plugins and MCP servers would all be written away.
    func testInstallRefusesToClobberUnparseableSettings() throws {
        try FileManager.default.createDirectory(at: AppPaths.claudeDir, withIntermediateDirectories: true)
        let corrupt = "{ \"model\": \"opus\", \"hooks\": {  "  // truncated mid-object
        try corrupt.write(to: AppPaths.claudeSettingsFile, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try HookInstaller.install()) { error in
            XCTAssertEqual(error as? HookInstaller.InstallError, .parseFailed)
        }

        let after = try String(contentsOf: AppPaths.claudeSettingsFile, encoding: .utf8)
        XCTAssertEqual(after, corrupt, "a settings.json we cannot read must be left exactly as it is")
    }

    /// JSON that parses but isn't an object (a bare array, say) is the
    /// same hazard by a different route.
    func testInstallRefusesSettingsThatAreNotAnObject() throws {
        try FileManager.default.createDirectory(at: AppPaths.claudeDir, withIntermediateDirectories: true)
        let notAnObject = "[1, 2, 3]"
        try notAnObject.write(to: AppPaths.claudeSettingsFile, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try HookInstaller.install())
        XCTAssertEqual(try String(contentsOf: AppPaths.claudeSettingsFile, encoding: .utf8), notAnObject)
    }

    /// An empty or absent settings.json is the normal first-run case and
    /// must still install cleanly — the guard above must not swallow it.
    func testInstallStillWorksWithNoSettingsFile() throws {
        try? FileManager.default.removeItem(at: AppPaths.claudeSettingsFile)

        XCTAssertNoThrow(try HookInstaller.install())
        XCTAssertNil(HookInstaller.healthCheck())
    }

    /// A script whose version stamp is gone (truncated write, hand-edit)
    /// read as `nil`, and the outdated check is `if let` — so the version
    /// comparison was skipped entirely and the corrupt script was never
    /// upgraded and never flagged. It just sat there.
    func testHealthCheckFlagsScriptWithMissingVersionStamp() throws {
        try HookInstaller.install()
        try "#!/usr/bin/env bash\nexit 0\n".write(
            to: AppPaths.clydeHookScript, atomically: true, encoding: .utf8)

        XCTAssertEqual(HookInstaller.healthCheck(), .scriptVersionUnreadable)
    }

    func testHealthCheckFlagsScriptWithUnparseableVersionStamp() throws {
        try HookInstaller.install()
        try "#!/usr/bin/env bash\n# clyde-hook-version: banana\nexit 0\n".write(
            to: AppPaths.clydeHookScript, atomically: true, encoding: .utf8)

        XCTAssertEqual(HookInstaller.healthCheck(), .scriptVersionUnreadable)
    }

    /// And reinstalling has to actually resolve it, or the banner becomes
    /// permanent furniture.
    func testReinstallRepairsAnUnstampedScript() throws {
        try HookInstaller.install()
        try "#!/usr/bin/env bash\nexit 0\n".write(
            to: AppPaths.clydeHookScript, atomically: true, encoding: .utf8)

        try HookInstaller.install()

        XCTAssertNil(HookInstaller.healthCheck())
    }

    // MARK: - Retired worktree subscription

    /// `WorktreeCreate` is a *delegating* hook: Claude Code hands
    /// worktree creation to whatever subscribes and requires the created
    /// path on stdout. Clyde is advisory and prints nothing, so
    /// subscribing to it made every `EnterWorktree` call fail with
    /// "hook succeeded but returned no worktree path".
    func testWorktreeEventsAreNotRegistered() {
        XCTAssertFalse(HookInstaller.registeredHookEvents.contains("WorktreeCreate"))
        XCTAssertFalse(HookInstaller.registeredHookEvents.contains("WorktreeRemove"))
    }

    /// Dropping the events from the registration list is not enough on
    /// its own: install only prunes events it still knows about, so a
    /// v0.7.0 install would keep its stale `WorktreeCreate` entry — and
    /// its broken `EnterWorktree` — forever after upgrading.
    func testInstallPrunesRetiredWorktreeRegistration() throws {
        let stale: [String: Any] = [
            "hooks": [
                "WorktreeCreate": [
                    ["hooks": [["type": "command", "command": AppPaths.clydeHookScript.path]]],
                    ["hooks": [["type": "command", "command": "/other/observer.sh"]]],
                ],
                "WorktreeRemove": [
                    ["hooks": [["type": "command", "command": AppPaths.clydeHookScript.path]]]
                ],
            ]
        ]
        try FileManager.default.createDirectory(at: AppPaths.claudeDir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: stale).write(to: AppPaths.claudeSettingsFile)

        try HookInstaller.install()

        let parsed = try JSONSerialization.jsonObject(
            with: try Data(contentsOf: AppPaths.claudeSettingsFile)) as! [String: Any]
        let hooks = parsed["hooks"] as! [String: Any]

        let create = hooks["WorktreeCreate"] as? [[String: Any]] ?? []
        let createCommands = create.flatMap { ($0["hooks"] as? [[String: Any]] ?? []) }
            .compactMap { $0["command"] as? String }
        XCTAssertEqual(createCommands, ["/other/observer.sh"],
                       "Clyde's entry must go; a third party's must stay")
        XCTAssertNil(hooks["WorktreeRemove"],
                     "Event with only Clyde's entry should be dropped entirely")
    }

    func testHealthCheckDetectsCleatHooksCapDisabled() throws {
        try HookInstaller.install()
        CleatProbe.cleatOnPathOverride = true
        CleatProbe.configPathOverride = URL(fileURLWithPath: "/tmp/clyde-test-noconfig-\(UUID().uuidString)")
        // No config file → hooks cap is treated as disabled (default).
        XCTAssertEqual(HookInstaller.healthCheck(), .cleatHooksCapDisabled)
    }

    /// Cleat advisory is intentionally LAST in the priority chain —
    /// a critical hook-health issue must be surfaced first because
    /// fixing it is a prerequisite for any tracking working at all,
    /// cleat-sandboxed or otherwise.
    func testHealthCheckSurfacesCriticalIssueBeforeCleatAdvisory() throws {
        try HookInstaller.install()
        // Make the install outdated AND mark cleat hooks cap as disabled.
        // The outdated issue should win.
        let scriptURL = AppPaths.clydeHookScript
        var script = try String(contentsOf: scriptURL, encoding: .utf8)
        script = script.replacingOccurrences(
            of: "# clyde-hook-version: \(HookInstaller.currentScriptVersion)",
            with: "# clyde-hook-version: 1"
        )
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)

        CleatProbe.cleatOnPathOverride = true
        CleatProbe.configPathOverride = URL(fileURLWithPath: "/tmp/clyde-test-noconfig-\(UUID().uuidString)")

        let issue = HookInstaller.healthCheck()
        if case .outdated = issue {
            // good — critical issue wins over advisory
        } else {
            XCTFail("expected .outdated to win over .cleatHooksCapDisabled, got \(String(describing: issue))")
        }
    }

    /// Cleat advisory must NOT fire when the probe says hooks is on
    /// — even if a fresh `cleat config --enable hooks` happens
    /// mid-session. Belt-and-suspenders on the inverse direction.
    func testHealthCheckClearsCleatAdvisoryWhenCapEnabled() throws {
        try HookInstaller.install()
        let configURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("clyde-cleat-enabled-\(UUID().uuidString)")
        try "[caps]\nhooks\n".write(to: configURL, atomically: true, encoding: .utf8)
        CleatProbe.cleatOnPathOverride = true
        CleatProbe.configPathOverride = configURL

        XCTAssertNil(HookInstaller.healthCheck())
    }

    // MARK: - HealthIssue properties

    func testCleatAdvisoryHasTitleMessageAndCommand() {
        let issue = HookInstaller.HealthIssue.cleatHooksCapDisabled
        XCTAssertEqual(issue.bannerTitle, "Cleat hook bridge is off")
        XCTAssertFalse(issue.bannerMessage.isEmpty)
        XCTAssertEqual(issue.bannerCommand, "cleat config --enable hooks")
    }

    func testCleatAdvisoryIsDismissableAndNotActionable() {
        let issue = HookInstaller.HealthIssue.cleatHooksCapDisabled
        // Settings has no button that flips cleat's capability — only
        // the user's terminal does. So it's NOT actionable (no
        // "Click to open Settings" affordance) but IS dismissable
        // (user can defer it from the panel).
        XCTAssertFalse(issue.isActionable)
        XCTAssertTrue(issue.isDismissable)
        XCTAssertNotNil(issue.dismissalIdentity)
    }

    func testCriticalIssuesAreActionableAndNotDismissable() {
        // Sample one of each shape — bare cases and an associated-value
        // case — so the property isn't accidentally tied to switch order.
        let cases: [HookInstaller.HealthIssue] = [
            .claudeNotInstalled,
            .notInstalled,
            .scriptMissing,
            .scriptNotExecutable,
            .outdated(installed: 1, current: 2),
            .missingEvents(["PreToolUse"]),
            .autoRepairFailed(reason: "boom"),
        ]
        for issue in cases {
            XCTAssertTrue(issue.isActionable, "\(issue) must be actionable — Settings can repair it")
            XCTAssertFalse(issue.isDismissable, "\(issue) must NOT be dismissable — critical state")
            XCTAssertNil(issue.dismissalIdentity, "\(issue) must not produce a dismissal identity")
            XCTAssertNil(issue.bannerCommand, "\(issue) must not surface a CLI command — its fix lives in Settings")
        }
    }

    // MARK: - How an issue asks for attention

    /// A quarter of the panel, on every launch, for something the user
    /// may have decided not to fix, is too much. Advisories became a
    /// chip in the summary bar; a broken hook still takes the banner,
    /// because tracking is actually not working then.
    func testAdvisoriesAreShownAsAChipNotABanner() {
        XCTAssertEqual(HookInstaller.HealthIssue.accessibilityNotTrusted.presentation, .chip)
        XCTAssertEqual(HookInstaller.HealthIssue.cleatHooksCapDisabled.presentation, .chip)
    }

    func testRealBreakageStillTakesTheBanner() {
        XCTAssertEqual(HookInstaller.HealthIssue.notInstalled.presentation, .banner)
        XCTAssertEqual(HookInstaller.HealthIssue.claudeNotInstalled.presentation, .banner)
        XCTAssertEqual(HookInstaller.HealthIssue.scriptMissing.presentation, .banner)
        XCTAssertEqual(HookInstaller.HealthIssue.outdated(installed: 1, current: 2).presentation, .banner)
    }

    /// The chip has room for a couple of words, and the detail belongs
    /// in the hover.
    func testTheChipLabelIsShort() {
        XCTAssertEqual(HookInstaller.HealthIssue.accessibilityNotTrusted.chipLabel, "Shortcut off")
        XCTAssertLessThanOrEqual(
            HookInstaller.HealthIssue.cleatHooksCapDisabled.chipLabel.count, 16)
    }

}
