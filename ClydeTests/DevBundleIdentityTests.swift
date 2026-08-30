import XCTest
@testable import Clyde

/// macOS keys Accessibility, Automation and notification grants to a
/// bundle identifier. Dev builds used to carry the shipped one, so every
/// locally built copy competed with the installed app for the same TCC
/// record: the checkbox in System Settings stayed ticked while
/// `AXIsProcessTrusted()` returned false, and the global shortcut was
/// dead until the permission was reset by hand.
///
/// Development builds therefore carry their own identifier. These tests
/// guard the two halves of that: the build script stamps it, and it is
/// not the shipped one.
final class DevBundleIdentityTests: XCTestCase {

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func read(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    func testTheShippedIdentifierIsTheOneInInfoPlist() throws {
        let plist = try read("Clyde/Info.plist")

        XCTAssertTrue(plist.contains("io.github.kl0sin.clyde"),
                      "the release identifier is the one Sparkle, the cask and TCC know")
    }

    func testTheDevBuildScriptStampsItsOwnIdentifier() throws {
        let script = try read("scripts/build-app.sh")

        XCTAssertTrue(script.contains("io.github.kl0sin.clyde.dev"),
                      "scripts/build-app.sh must give dev bundles their own identity")
        XCTAssertTrue(script.contains("CFBundleIdentifier"),
                      "and stamp it into the copied Info.plist")
    }

    /// The dev identifier has to differ from the shipped one, or the
    /// stamp is decoration.
    func testTheTwoIdentifiersDiffer() throws {
        let plist = try read("Clyde/Info.plist")

        XCTAssertFalse(plist.contains("io.github.kl0sin.clyde.dev"),
                       "the shipped bundle must never carry the dev identifier")
    }

    /// A dev build that looks identical in System Settings is only half
    /// a fix — the user has to be able to tell which row is which.
    func testTheDevBuildIsNamedDistinctly() throws {
        let script = try read("scripts/build-app.sh")

        XCTAssertTrue(script.contains("CFBundleName") || script.contains("CFBundleDisplayName"),
                      "dev bundles need a name that reads differently in permission lists")
    }

    // MARK: - The release build script, run locally

    private func runBundleIdScript(env: [String: String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [repoRoot.appendingPathComponent("scripts/lib/release-bundle-id.sh").path]
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// CI builds the artifact that ships, so it keeps the shipped
    /// identifier.
    func testTheReleaseScriptKeepsTheShippedIdentifierOnCI() throws {
        XCTAssertEqual(try runBundleIdScript(env: ["CI": "true"]), "io.github.kl0sin.clyde")
    }

    /// The same script run on a development machine produces a bundle
    /// that sits next to the installed app. Today that bundle carried
    /// the shipped identifier and took its permissions with it.
    func testTheReleaseScriptStampsTheDevIdentifierLocally() throws {
        XCTAssertEqual(try runBundleIdScript(env: [:]), "io.github.kl0sin.clyde.dev")
    }

    /// An explicit opt-in for building a real release by hand.
    func testTheShippedIdentifierCanBeRequestedExplicitly() throws {
        XCTAssertEqual(try runBundleIdScript(env: ["CLYDE_RELEASE_BUNDLE": "1"]),
                       "io.github.kl0sin.clyde")
    }

    /// Logging follows the bundle: a dev build's messages must not be
    /// indistinguishable from the installed app's in the unified log.
    func testTheLogSubsystemFollowsTheBundle() throws {
        let logger = try read("Clyde/Services/Logger.swift")

        XCTAssertTrue(logger.contains("Bundle.main.bundleIdentifier"),
                      "the subsystem should come from the running bundle, not a constant")
    }
}
