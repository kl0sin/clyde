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

    func testThePanelSizeScenarioMeasuresWithoutAskingForPermission() throws {
        let scenarios = try read("scripts/dev/scenarios.sh")
        let panelSize = scenarios.components(separatedBy: "panel-size)")[1]
            .components(separatedBy: "\n    ;;")[0]

        XCTAssertTrue(panelSize.contains("window-geometry.swift"),
                      "measure through CGWindowList")
        XCTAssertFalse(panelSize.contains("osascript"),
                       "System Events needs a permission the check itself can lose")
        XCTAssertFalse(panelSize.contains("open_panel"),
                       "the panel is measurable while hidden; opening it needs permission")
    }

    /// A geometry check that only ever runs by hand is the arrangement
    /// that shipped the bug.
    func testTheVerifyWorkflowMeasuresTheBundleItBuilds() throws {
        let workflow = try read(".github/workflows/verify-build.yml")

        XCTAssertTrue(workflow.contains("window-geometry.swift"))
        XCTAssertTrue(workflow.contains("400x420"), "the expected panel size is asserted, not printed")
    }
}
