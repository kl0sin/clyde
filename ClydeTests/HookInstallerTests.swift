import XCTest
@testable import Clyde

/// Tests for HookInstaller. Since HookInstaller uses hardcoded paths via AppPaths,
/// these tests back up and restore the user's actual ~/.claude directory.
/// They are skipped if ~/.claude already has significant content to avoid destruction.
final class HookInstallerTests: XCTestCase {
    private var backupURL: URL?
    private var originalSettingsData: Data?

    override func setUp() async throws {
        // Backup existing settings.json if present
        if FileManager.default.fileExists(atPath: AppPaths.claudeSettingsFile.path) {
            originalSettingsData = try? Data(contentsOf: AppPaths.claudeSettingsFile)
        }
    }

    override func tearDown() async throws {
        // Always uninstall after each test
        try? HookInstaller.uninstall()

        // Restore original settings.json
        if let data = originalSettingsData {
            try? data.write(to: AppPaths.claudeSettingsFile)
        }
        originalSettingsData = nil
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
}
