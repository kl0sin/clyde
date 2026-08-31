import XCTest

/// The v0.8.0 panel regression took hours to prove because the only tool
/// that measured a running Clyde drove System Events, which needs
/// Automation permission — and that permission was denied on the machine
/// doing the measuring. `CGWindowListCopyWindowInfo` needs none, and
/// reads the panel while it is still hidden at alpha 0, so nothing has
/// to be clicked open.
///
/// These guard the tooling from drifting back.
final class PanelGeometryToolingTests: XCTestCase {

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func read(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    // MARK: - The check itself

    /// Runs `check-window-geometry.sh` against a fake measurement, so
    /// the assertion logic is exercised without launching anything.
    private func runCheck(reporting geometry: String?, strict: Bool = false) throws -> Int32 {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clyde-geometry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let fake = dir.appendingPathComponent("fake-geometry.sh")
        let body = geometry.map { "#!/bin/sh\nprintf '\($0)'\n" } ?? "#!/bin/sh\nexit 1\n"
        try body.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [repoRoot.appendingPathComponent("scripts/dev/check-window-geometry.sh").path,
                             "--running"] + (strict ? ["--strict"] : [])
        process.environment = ["CLYDE_GEOMETRY_CMD": fake.path, "PATH": "/usr/bin:/bin"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    func testTheRightSizesPass() throws {
        XCTAssertEqual(try runCheck(reporting: "400x420 layer=3\n130x46 layer=3\n"), 0)
    }

    /// The exact window v0.8.0 shipped.
    func testTheShippedRegressionFails() throws {
        XCTAssertEqual(try runCheck(reporting: "400x1476 layer=3\n130x46 layer=3\n"), 1)
    }

    func testAWidgetOfTheWrongSizeFails() throws {
        XCTAssertEqual(try runCheck(reporting: "400x420 layer=3\n130x300 layer=3\n"), 1)
    }

    /// A machine with no window server measured nothing. That is a skip
    /// when the check is advisory and a failure when a release depends
    /// on it — a runner that silently loses the ability to measure must
    /// not silently stop protecting anything.
    func testNothingMeasuredIsASkipButFailsUnderStrict() throws {
        XCTAssertEqual(try runCheck(reporting: nil), 0)
        XCTAssertEqual(try runCheck(reporting: nil, strict: true), 1)
    }

    // MARK: - Its callers

    func testThePanelSizeScenarioMeasuresWithoutAskingForPermission() throws {
        let scenarios = try read("scripts/dev/scenarios.sh")
        let panelSize = scenarios.components(separatedBy: "panel-size)")[1]
            .components(separatedBy: "\n    ;;")[0]

        XCTAssertTrue(panelSize.contains("check-window-geometry.sh"),
                      "one definition of the expected sizes, shared with CI")
        XCTAssertFalse(panelSize.contains("osascript"),
                       "System Events needs a permission the check itself can lose")
        XCTAssertFalse(panelSize.contains("open_panel"),
                       "the panel is measurable while hidden; opening it needs permission")
    }

    /// A geometry check that only ever runs by hand is the arrangement
    /// that shipped the bug.
    func testTheVerifyWorkflowMeasuresTheBundleItBuilds() throws {
        let workflow = try read(".github/workflows/verify-build.yml")

        XCTAssertTrue(workflow.contains("check-window-geometry.sh --app build/release/Clyde.app"))
    }

    /// A check that never runs when it matters is decoration: releases
    /// are where a wrong-sized window reaches users.
    func testTheReleaseWorkflowMeasuresBeforeItSigns() throws {
        let workflow = try read(".github/workflows/release.yml")

        XCTAssertTrue(workflow.contains("check-window-geometry.sh --app build/release/Clyde.app --strict"),
                      "releases fail rather than skip when nothing could be measured")
        let measure = try XCTUnwrap(workflow.range(of: "Measure the window geometry"))
        let sign = try XCTUnwrap(workflow.range(of: "- name: Sign"))
        XCTAssertTrue(measure.lowerBound < sign.lowerBound,
                      "measure before signing and notarizing, so a failure costs only the tag")
    }
}
