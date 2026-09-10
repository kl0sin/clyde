import XCTest
@testable import Clyde

final class UsageLimitsInstallerTests: XCTestCase {
    private var tempHome: URL!

    override func setUp() async throws {
        tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("clyde-limits-installer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
        AppPaths.homeOverride = tempHome
    }

    override func tearDown() async throws {
        AppPaths.homeOverride = nil
        UsageLimitsInstaller.offerOverride = nil
        if let tempHome { try? FileManager.default.removeItem(at: tempHome) }
        tempHome = nil
    }

    private func writeSettings(_ object: [String: Any]) throws {
        try FileManager.default.createDirectory(at: AppPaths.claudeDir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: object)
        try data.write(to: AppPaths.claudeSettingsFile)
    }

    private func readSettings() throws -> [String: Any] {
        let data = try Data(contentsOf: AppPaths.claudeSettingsFile)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testInstallWritesScriptAndRegistersIt() throws {
        try UsageLimitsInstaller.install()

        XCTAssertTrue(FileManager.default.fileExists(atPath: AppPaths.clydeStatusLineScript.path))
        let attrs = try FileManager.default.attributesOfItem(atPath: AppPaths.clydeStatusLineScript.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.int16Value, 0o755)

        let statusLine = try XCTUnwrap(try readSettings()["statusLine"] as? [String: Any])
        XCTAssertEqual(statusLine["type"] as? String, "command")
        XCTAssertEqual(statusLine["command"] as? String, AppPaths.clydeStatusLineScript.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: AppPaths.usagePassthroughFile.path))
        XCTAssertNil(UsageLimitsInstaller.healthCheck())
    }

    func testInstallKeepsTheUsersStatusLineAsPassthrough() throws {
        try writeSettings(["statusLine": ["type": "command", "command": "~/bin/my-status.sh", "padding": 2],
                           "model": "opus"])

        try UsageLimitsInstaller.install()

        let settings = try readSettings()
        let statusLine = try XCTUnwrap(settings["statusLine"] as? [String: Any])
        XCTAssertEqual(statusLine["command"] as? String, AppPaths.clydeStatusLineScript.path)
        XCTAssertEqual(statusLine["padding"] as? Int, 2)
        XCTAssertEqual(settings["model"] as? String, "opus")
        XCTAssertEqual(try String(contentsOf: AppPaths.usagePassthroughFile, encoding: .utf8), "~/bin/my-status.sh")
    }

    func testReinstallDoesNotAdoptItselfAsPassthrough() throws {
        try writeSettings(["statusLine": ["type": "command", "command": "~/bin/my-status.sh"]])
        try UsageLimitsInstaller.install()
        try UsageLimitsInstaller.install()
        XCTAssertEqual(try String(contentsOf: AppPaths.usagePassthroughFile, encoding: .utf8), "~/bin/my-status.sh")
    }

    func testUninstallRestoresTheUsersStatusLine() throws {
        try writeSettings(["statusLine": ["type": "command", "command": "~/bin/my-status.sh", "padding": 2]])
        try UsageLimitsInstaller.install()

        try UsageLimitsInstaller.uninstall()

        let statusLine = try XCTUnwrap(try readSettings()["statusLine"] as? [String: Any])
        XCTAssertEqual(statusLine["command"] as? String, "~/bin/my-status.sh")
        XCTAssertEqual(statusLine["padding"] as? Int, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: AppPaths.clydeStatusLineScript.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: AppPaths.usagePassthroughFile.path))
    }

    func testUninstallRemovesTheSlotWhenThereWasNothingBefore() throws {
        try UsageLimitsInstaller.install()
        try UsageLimitsInstaller.uninstall()
        XCTAssertNil(try readSettings()["statusLine"])
    }

    func testUninstallLeavesAStatusLineThatIsNotOurs() throws {
        try UsageLimitsInstaller.install()
        try writeSettings(["statusLine": ["type": "command", "command": "~/bin/newer.sh"]])
        try UsageLimitsInstaller.uninstall()
        let statusLine = try XCTUnwrap(try readSettings()["statusLine"] as? [String: Any])
        XCTAssertEqual(statusLine["command"] as? String, "~/bin/newer.sh")
    }

    func testInstallRefusesUnparseableSettings() throws {
        try FileManager.default.createDirectory(at: AppPaths.claudeDir, withIntermediateDirectories: true)
        try "{ not json".write(to: AppPaths.claudeSettingsFile, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try UsageLimitsInstaller.install()) { error in
            XCTAssertEqual(error as? UsageLimitsInstaller.InstallError, .parseFailed)
        }
        XCTAssertEqual(try String(contentsOf: AppPaths.claudeSettingsFile, encoding: .utf8), "{ not json")
    }

    func testUninstallRefusesUnparseableSettings() throws {
        try FileManager.default.createDirectory(at: AppPaths.claudeDir, withIntermediateDirectories: true)
        try "{ not json".write(to: AppPaths.claudeSettingsFile, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try UsageLimitsInstaller.uninstall()) { error in
            XCTAssertEqual(error as? UsageLimitsInstaller.InstallError, .parseFailed)
        }
        XCTAssertEqual(try String(contentsOf: AppPaths.claudeSettingsFile, encoding: .utf8), "{ not json")
    }

    func testInstallStoresPassthroughBeforeWritingTheScript() throws {
        try writeSettings(["statusLine": ["type": "command", "command": "~/bin/my-status.sh"]])
        // Make usageDir a plain file so the passthrough write (and the
        // directory creation ahead of it) cannot succeed.
        try FileManager.default.createDirectory(at: AppPaths.clydeDir, withIntermediateDirectories: true)
        try "x".write(to: AppPaths.usageDir, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try UsageLimitsInstaller.install()) { error in
            guard case .writeFailed = error as? UsageLimitsInstaller.InstallError else {
                XCTFail("expected .writeFailed, got \(error)")
                return
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: AppPaths.clydeStatusLineScript.path))
        XCTAssertEqual(UsageLimitsInstaller.healthCheck(), .notInstalled)
    }

    func testUninstallKeepsThePassthroughWhenDisplaced() throws {
        try writeSettings(["statusLine": ["type": "command", "command": "~/bin/my-status.sh"]])
        try UsageLimitsInstaller.install()
        try writeSettings(["statusLine": ["type": "command", "command": "~/bin/newer.sh"]])

        try UsageLimitsInstaller.uninstall()

        let statusLine = try XCTUnwrap(try readSettings()["statusLine"] as? [String: Any])
        XCTAssertEqual(statusLine["command"] as? String, "~/bin/newer.sh")
        XCTAssertFalse(FileManager.default.fileExists(atPath: AppPaths.clydeStatusLineScript.path))
        XCTAssertEqual(try String(contentsOf: AppPaths.usagePassthroughFile, encoding: .utf8), "~/bin/my-status.sh")
    }

    func testHealthCheckStates() throws {
        XCTAssertEqual(UsageLimitsInstaller.healthCheck(), .notInstalled)

        try UsageLimitsInstaller.install()
        XCTAssertNil(UsageLimitsInstaller.healthCheck())

        try FileManager.default.removeItem(at: AppPaths.clydeStatusLineScript)
        XCTAssertEqual(UsageLimitsInstaller.healthCheck(), .scriptMissing)

        try UsageLimitsInstaller.install()
        try writeSettings(["statusLine": ["type": "command", "command": "~/bin/newer.sh"]])
        XCTAssertEqual(UsageLimitsInstaller.healthCheck(), .displaced(by: "~/bin/newer.sh"))
    }

    func testHealthCheckDetectsAnOlderScript() throws {
        try UsageLimitsInstaller.install()
        let old = try String(contentsOf: AppPaths.clydeStatusLineScript, encoding: .utf8)
            .replacingOccurrences(of: "# clyde-statusline-version: \(UsageLimitsInstaller.currentScriptVersion)",
                                  with: "# clyde-statusline-version: 0")
        try old.write(to: AppPaths.clydeStatusLineScript, atomically: true, encoding: .utf8)
        XCTAssertEqual(UsageLimitsInstaller.healthCheck(),
                       .outdated(installed: 0, current: UsageLimitsInstaller.currentScriptVersion))
    }

    func testOfferFollowsTheSettingAndTheDismissal() {
        UsageLimitsInstaller.offerOverride = nil
        let defaults = UserDefaults(suiteName: "UsageLimitsInstallerTests")!
        defaults.removePersistentDomain(forName: "UsageLimitsInstallerTests")
        XCTAssertTrue(UsageLimitsInstaller.shouldOffer(defaults: defaults))
        defaults.set(true, forKey: UsageLimitsInstaller.settingKey)
        XCTAssertFalse(UsageLimitsInstaller.shouldOffer(defaults: defaults))
        defaults.set(false, forKey: UsageLimitsInstaller.settingKey)
        defaults.set(true, forKey: UsageLimitsInstaller.offerDismissedKey)
        XCTAssertFalse(UsageLimitsInstaller.shouldOffer(defaults: defaults))
    }
}
