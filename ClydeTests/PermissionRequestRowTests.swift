import XCTest
@testable import Clyde

/// The row that carries the question. Its tests are about the decisions
/// it makes — which request belongs to which session, and what the user
/// is shown before they click — not about how it looks.
@MainActor
final class PermissionRequestRowTests: XCTestCase {

    private func request(id: String = "r1",
                         pid: pid_t = 42,
                         tool: String = "Bash",
                         command: String = "rm -rf build",
                         expiresIn: TimeInterval = 30) throws -> PermissionRequest {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clyde-row-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let body: [String: Any] = [
            "request_id": id, "session_id": "s", "pid": Int(pid), "cwd": "/repo",
            "tool_name": tool, "tool_input": ["command": command],
            "created_at": Int(Date().timeIntervalSince1970),
            "expires_at": Int(Date().addingTimeInterval(expiresIn).timeIntervalSince1970)
        ]
        let url = dir.appendingPathComponent("\(id).request")
        try JSONSerialization.data(withJSONObject: body).write(to: url)
        return try XCTUnwrap(PermissionRequest(fileURL: url))
    }

    /// A question belongs under the session that asked it. Two sessions
    /// can be waiting at the same time, and answering the wrong one
    /// runs the wrong command.
    func testARequestIsShownOnlyUnderItsOwnSession() throws {
        let req = try request(pid: 42)

        XCTAssertTrue(PermissionRequestRow.shows(request: req, inRowFor: 42))
        XCTAssertFalse(PermissionRequestRow.shows(request: req, inRowFor: 99))
    }

    /// Once the hook has stopped waiting the terminal owns the
    /// question, so the row goes away even if the file is still there.
    func testAnExpiredRequestIsNotShown() throws {
        let req = try request(pid: 42, expiresIn: -1)

        XCTAssertFalse(PermissionRequestRow.shows(request: req, inRowFor: 42))
    }

    func testTheRowShowsTheWholeCommand() throws {
        let long = "echo " + String(repeating: "a", count: 400)
        let req = try request(command: long)

        XCTAssertEqual(PermissionRequestRow.displayedSummary(for: req), long,
                       "never abbreviate what the user is approving")
    }

    /// Both buttons carry their own label: the meaning cannot rest on
    /// colour or position alone.
    func testBothActionsAreLabelled() {
        XCTAssertEqual(PermissionRequestRow.label(for: .allow), "Allow")
        XCTAssertEqual(PermissionRequestRow.label(for: .deny), "Deny")
    }

    /// The label a screen reader reads has to say what is being
    /// approved, not just "Allow".
    func testTheAccessibilityLabelNamesTheToolAndTheCommand() throws {
        let req = try request(tool: "Bash", command: "git push --force")

        let label = PermissionRequestRow.accessibilityLabel(for: req)

        XCTAssertTrue(label.contains("Bash"), label)
        XCTAssertTrue(label.contains("git push --force"), label)
    }

    // MARK: - Long requests

    /// A short command shows whole and needs no controls.
    func testAShortRequestIsNotCapped() {
        XCTAssertFalse(PermissionRequestRow.needsCap(for: "npm test"))
    }

    /// A 40-line script would push the session list, the Activity bar
    /// and everything else out of a 420-point panel.
    func testALongRequestIsCapped() {
        let script = (1...40).map { "line \($0)" }.joined(separator: "\n")
        XCTAssertTrue(PermissionRequestRow.needsCap(for: script))
    }

    /// One very long line wraps into many, so length counts too — not
    /// just newlines.
    func testOneEnormousLineCountsAsLong() {
        XCTAssertTrue(PermissionRequestRow.needsCap(for: String(repeating: "x", count: 600)))
    }

    /// Capping hides nothing permanently: the row says how much more
    /// there is and opens on request. Silently cutting it would be the
    /// truncation this row exists to avoid.
    func testTheCapAnnouncesWhatItIsHiding() {
        let script = (1...40).map { "line \($0)" }.joined(separator: "\n")

        let note = PermissionRequestRow.expandLabel(for: script)

        XCTAssertTrue(note.contains("40"), note)
    }

}
