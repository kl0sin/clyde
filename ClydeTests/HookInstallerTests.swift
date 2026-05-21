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
    }

    override func tearDown() async throws {
        AppPaths.homeOverride = nil
        HookInstaller.claudeInstalledOverride = nil
        CleatProbe.cleatOnPathOverride = nil
        CleatProbe.configPathOverride = nil
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

    // MARK: - Regression tests for the matcher / rename / coexistence bugs
    //
    // Each of these covers a real-world failure mode we hit by hand and
    // lost hours to. They exist so the same bugs cannot regress silently.

    /// Regression: Claude Code requires a `matcher` field on
    /// PreToolUse / PostToolUse* entries. Without it the entry is
    /// malformed, every tool call emits "<event>:<tool> hook error",
    /// and the script is never invoked. Other events MUST NOT have a
    /// matcher (it's specific to tool events).
    func testInstallEmitsMatcherForToolEvents() throws {
        try HookInstaller.install()

        let data = try Data(contentsOf: AppPaths.claudeSettingsFile)
        let settings = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let hooks = settings["hooks"] as! [String: Any]

        let toolEvents = ["PreToolUse", "PostToolUseFailure"]
        for event in toolEvents {
            let entries = hooks[event] as? [[String: Any]] ?? []
            XCTAssertFalse(entries.isEmpty, "\(event) must have at least one entry")
            // Find the entry with our hook command.
            let ours = entries.first { entry in
                let inner = (entry["hooks"] as? [[String: Any]]) ?? []
                return inner.contains { ($0["command"] as? String) == AppPaths.clydeHookScript.path }
            }
            XCTAssertNotNil(ours, "\(event) must contain Clyde's hook entry")
            XCTAssertNotNil(ours?["matcher"], "\(event) entry must have a `matcher` field — Claude treats it as malformed otherwise")
        }

        let nonToolEvents = ["UserPromptSubmit", "SessionStart", "Stop"]
        for event in nonToolEvents {
            let entries = hooks[event] as? [[String: Any]] ?? []
            let ours = entries.first { entry in
                let inner = (entry["hooks"] as? [[String: Any]]) ?? []
                return inner.contains { ($0["command"] as? String) == AppPaths.clydeHookScript.path }
            }
            XCTAssertNotNil(ours, "\(event) must contain Clyde's hook entry")
            XCTAssertNil(ours?["matcher"], "\(event) entry MUST NOT have a `matcher` field")
        }
    }

    /// Regression: an existing matcher-less PreToolUse entry should
    /// be detected by `healthCheck` as missing, so auto-repair fires
    /// even though the registration "exists".
    func testHealthCheckDetectsMissingMatcher() throws {
        try HookInstaller.install()

        // Mutate settings.json: strip the matcher field from PreToolUse.
        let data = try Data(contentsOf: AppPaths.claudeSettingsFile)
        var settings = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var hooks = settings["hooks"] as! [String: Any]
        var preToolUse = hooks["PreToolUse"] as! [[String: Any]]
        preToolUse = preToolUse.map { entry in
            var copy = entry
            copy.removeValue(forKey: "matcher")
            return copy
        }
        hooks["PreToolUse"] = preToolUse
        settings["hooks"] = hooks
        let newData = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted])
        try newData.write(to: AppPaths.claudeSettingsFile)

        if case .missingEvents(let names) = HookInstaller.healthCheck() {
            XCTAssertTrue(names.contains("PreToolUse"),
                          "Health check must flag matcher-less PreToolUse as missing")
        } else {
            XCTFail("Expected .missingEvents for matcher-less PreToolUse, got \(String(describing: HookInstaller.healthCheck()))")
        }
    }

    /// Regression: when a legacy `clyde-notify.sh` is on disk from an
    /// older Clyde install, `migrateLegacyHookIfNeeded()` must rewrite
    /// the canonical `clyde-hook.sh`, register it in settings.json, and
    /// delete the legacy file. Skipping this leaves the user with a
    /// half-broken install whose hook is named one thing on disk but
    /// referenced under another in settings.
    func testMigrateLegacyHookReinstallsCanonicalName() throws {
        // Plant a legacy script the way an older Clyde would have.
        try FileManager.default.createDirectory(at: AppPaths.claudeHooksDir, withIntermediateDirectories: true)
        try "#!/bin/bash\n# clyde-hook-version: 1\nexit 0\n"
            .write(to: AppPaths.legacyClydeHookScript, atomically: true, encoding: .utf8)
        XCTAssertTrue(FileManager.default.fileExists(atPath: AppPaths.legacyClydeHookScript.path))

        HookInstaller.migrateLegacyHookIfNeeded()

        XCTAssertFalse(FileManager.default.fileExists(atPath: AppPaths.legacyClydeHookScript.path),
                       "Legacy clyde-notify.sh must be deleted after migration")
        XCTAssertTrue(FileManager.default.fileExists(atPath: AppPaths.clydeHookScript.path),
                      "Canonical clyde-hook.sh must be installed")
        XCTAssertNil(HookInstaller.healthCheck(),
                     "Post-migration install must be fully healthy")
    }

    /// Regression: when Claude Code itself isn't installed, healthCheck
    /// must return `.claudeNotInstalled` and short-circuit before any
    /// hook-script-level checks. This is important because if a user
    /// installs Clyde without Claude Code, the natural error chain
    /// would be "hook script not installed" → "click to repair" →
    /// repair fails (no Claude to register against) → confusing.
    /// Surfacing claudeNotInstalled at the top of the funnel sends
    /// the user to the actual root cause first.
    func testHealthCheckReportsClaudeNotInstalledFirst() throws {
        HookInstaller.claudeInstalledOverride = false

        // Even if everything else is healthy, claudeNotInstalled wins.
        try HookInstaller.install()
        XCTAssertEqual(HookInstaller.healthCheck(), .claudeNotInstalled)

        // Restore and confirm we go back to nil (or some other lower-priority issue).
        HookInstaller.claudeInstalledOverride = true
        XCTAssertNotEqual(HookInstaller.healthCheck(), .claudeNotInstalled)
    }

    /// Regression: claude-visual (and other tools) own their own hooks
    /// in `settings.json`. Clyde's install MUST coexist with them — it
    /// can append to the same event's array, but must not delete or
    /// overwrite their entries. Earlier installer logic detected our
    /// hook by literal-string match, which would have started false-
    /// positively merging on any rename and could clobber other tools.
    func testInstallCoexistsWithThirdPartyHooks() throws {
        // Seed settings.json with hooks owned by another tool, on every
        // event we register for plus a couple we don't.
        let foreignCommand = "curl -s http://localhost:9999/event"
        let foreignBlock: [String: Any] = ["hooks": [["type": "command", "command": foreignCommand]]]
        let foreignBlockWithMatcher: [String: Any] = [
            "matcher": "Bash",
            "hooks": [["type": "command", "command": foreignCommand]],
        ]
        let preExistingHooks: [String: Any] = [
            "PreToolUse": [foreignBlockWithMatcher],
            "Stop": [foreignBlock],
            "UserPromptSubmit": [foreignBlock],
            "Notification": [foreignBlock], // event we don't register for
        ]
        try FileManager.default.createDirectory(at: AppPaths.claudeDir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["hooks": preExistingHooks])
            .write(to: AppPaths.claudeSettingsFile)

        try HookInstaller.install()

        // After install, every foreign entry must still be there.
        let data = try Data(contentsOf: AppPaths.claudeSettingsFile)
        let settings = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let hooks = settings["hooks"] as! [String: Any]

        for event in ["PreToolUse", "Stop", "UserPromptSubmit", "Notification"] {
            let entries = hooks[event] as? [[String: Any]] ?? []
            let foreignSurvived = entries.contains { entry in
                let inner = (entry["hooks"] as? [[String: Any]]) ?? []
                return inner.contains { ($0["command"] as? String) == foreignCommand }
            }
            XCTAssertTrue(foreignSurvived, "Foreign hook on \(event) was clobbered by Clyde install")
        }

        // And our entries must be present where expected.
        for event in ["PreToolUse", "Stop", "UserPromptSubmit", "SessionStart"] {
            let entries = hooks[event] as? [[String: Any]] ?? []
            let weAreThere = entries.contains { entry in
                let inner = (entry["hooks"] as? [[String: Any]]) ?? []
                return inner.contains { ($0["command"] as? String) == AppPaths.clydeHookScript.path }
            }
            XCTAssertTrue(weAreThere, "Clyde's hook missing from \(event) after coexistence install")
        }

        // Subsequent install() calls must remain idempotent — no dupes.
        try HookInstaller.install()
        let data2 = try Data(contentsOf: AppPaths.claudeSettingsFile)
        let settings2 = try JSONSerialization.jsonObject(with: data2) as! [String: Any]
        let hooks2 = settings2["hooks"] as! [String: Any]
        for event in HookInstaller.registeredHookEvents {
            let entries = (hooks2[event] as? [[String: Any]]) ?? []
            let ourCount = entries.filter { entry in
                let inner = (entry["hooks"] as? [[String: Any]]) ?? []
                return inner.contains { ($0["command"] as? String) == AppPaths.clydeHookScript.path }
            }.count
            XCTAssertEqual(ourCount, 1, "Duplicate Clyde entry for \(event) after second install()")
        }
    }

    // MARK: - Cleat advisory (HealthIssue properties + healthCheck order)

    /// Healthy hook install + cleat installed with hooks cap disabled
    /// → healthCheck returns the cleat advisory. This is the
    /// integration test for the new advisory branch.
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
}
