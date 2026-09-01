import XCTest
@testable import Clyde

/// Compact mode: the rows, a grip to drag by, and a footer. Its height
/// is a function of what it is showing, which is the only thing in the
/// app allowed to resize the panel — and it does so through the same
/// door as a deliberate resize, never by letting content push the
/// window around.
@MainActor
final class CompactModeTests: XCTestCase {

    private func session(_ name: String,
                         status: SessionStatus = .idle,
                         attention: Bool = false,
                         quietFor seconds: TimeInterval = 60) -> Session {
        var s = Session(pid: pid_t(abs(name.hashValue % 30000) + 1),
                        workingDirectory: "/Users/me/\(name)",
                        status: status)
        s.needsAttention = attention
        s.statusChangedAt = Date().addingTimeInterval(-seconds)
        return s
    }

    // MARK: - Height

    func testHeightFollowsWhatIsShown() {
        let two = CompactRootView.height(for: [session("a"), session("b")])
        let four = CompactRootView.height(for: (0..<4).map { session("s\($0)") })

        XCTAssertGreaterThan(four, two)
    }

    /// State does not change the height, only the count does.
    ///
    /// An earlier version made quiet cards shorter, and this test
    /// enforced that. Looking at it settled the question the other way:
    /// a quiet card carries the same devices switched off, and giving
    /// it fewer lines took its structure away. Uniform cards also mean
    /// the window does not resize every time a session starts talking.
    func testStateDoesNotChangeTheHeight() {
        let quiet = CompactRootView.height(for: [session("a"), session("b")])
        let busy = CompactRootView.height(for: [session("a", status: .busy), session("b")])

        XCTAssertEqual(busy, quiet)
    }

    func testAnEmptyPanelStillHasItsChrome() {
        XCTAssertGreaterThan(CompactRootView.height(for: []), 0)
    }

    /// Four quiet sessions were the number this was designed around: a
    /// fraction of the full panel rather than all of it.
    func testFourSessionsAreWellUnderTheFullPanel() {
        let four = (0..<4).map { session("s\($0)") }
        XCTAssertLessThan(CompactRootView.height(for: four), 420 * 0.6)
    }

    // MARK: - Which sessions, and in what order

    /// A session waiting on you is the only one that requires
    /// something. Working sessions are there to be glanced at.
    func testNeedsYouComesFirst() {
        let order = CompactRootView.visible(
            sessions: [session("idle"), session("busy", status: .busy), session("ask", attention: true)],
            cap: 5)

        XCTAssertEqual(order.map(\.displayName), ["ask", "busy", "idle"])
    }

    /// Inside a state the incoming order is kept untouched — which is
    /// the user's own drag order, and the same order the full panel
    /// shows. Compact used to re-sort idle rows by how recently they
    /// went quiet, so the two windows listed the same sessions
    /// differently.
    func testSessionsOfTheSameStateKeepTheOrderTheyCameIn() {
        let order = CompactRootView.visible(
            sessions: [session("old", quietFor: 3600), session("recent", quietFor: 30)],
            cap: 5)

        XCTAssertEqual(order.map(\.displayName), ["old", "recent"])
    }

    func testTheCapBoundsTheList() {
        let sessions = (0..<9).map { session("s\($0)") }

        XCTAssertEqual(CompactRootView.visible(sessions: sessions, cap: 4).count, 4)
    }

    /// Over the cap it is the quiet ones that go.
    func testWorkAndQuestionsSurviveTheCap() {
        let sessions = [
            session("idleA"), session("workingB", status: .busy),
            session("idleC"), session("askD", attention: true), session("idleE")
        ]

        let shown = CompactRootView.visible(sessions: sessions, cap: 3).map(\.displayName)

        XCTAssertEqual(shown.prefix(2).sorted(), ["askD", "workingB"])
        XCTAssertEqual(shown.count, 3)
    }

    /// Ghosts are ended sessions the full panel keeps around briefly.
    /// Compact has no room for history.
    func testGhostsAreNotShown() {
        var ghost = session("gone")
        ghost.endedAt = Date()

        XCTAssertTrue(CompactRootView.visible(sessions: [ghost], cap: 4).isEmpty)
    }

    // MARK: - The mode itself

    func testTheModePersistsAcrossLaunches() {
        UserDefaults.standard.removeObject(forKey: AppViewModel.panelModeKey)
        XCTAssertEqual(AppViewModel.storedPanelMode(), .full, "the panel opens as it always has")

        AppViewModel.storePanelMode(.compact)

        XCTAssertEqual(AppViewModel.storedPanelMode(), .compact)
        UserDefaults.standard.removeObject(forKey: AppViewModel.panelModeKey)
    }

    func testTheCapHasADefault() {
        XCTAssertEqual(CompactRootView.defaultRowCap, 4)
    }

    // MARK: - A request, inside compact

    private func request(id: String = "r1",
                         pid: pid_t = 1,
                         command: String = "npm test",
                         expiresIn: TimeInterval = 30) throws -> PermissionRequest {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clyde-compact-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let body: [String: Any] = [
            "request_id": id, "session_id": "s", "pid": Int(pid), "cwd": "/repo",
            "tool_name": "Bash", "tool_input": ["command": command],
            "created_at": Int(Date().timeIntervalSince1970),
            "expires_at": Int(Date().addingTimeInterval(expiresIn).timeIntervalSince1970)
        ]
        let url = dir.appendingPathComponent("\(id).request")
        try JSONSerialization.data(withJSONObject: body).write(to: url)
        return try XCTUnwrap(PermissionRequest(fileURL: url))
    }

    func testARequestMakesTheWindowTaller() throws {
        let rows = (0..<3).map { session("s\($0)") }
        let plain = CompactRootView.height(for: rows)
        let withRequest = CompactRootView.height(for: rows, expanded: try request())

        XCTAssertGreaterThan(withRequest, plain)
    }

    /// A longer command needs more room, and compact has to know how
    /// much before it draws anything.
    func testALongerCommandAsksForMoreRoom() throws {
        let rows = [session("a"), session("b")]
        let short = CompactRootView.height(for: rows, expanded: try request(command: "ls"))
        let long = CompactRootView.height(
            for: rows, expanded: try request(command: String(repeating: "x", count: 300)))

        XCTAssertGreaterThan(long, short)
    }

    /// Folded at five lines, like the full panel — otherwise a forty
    /// line script takes the screen.
    func testAnEnormousCommandIsBounded() throws {
        let rows = [session("a"), session("b")]
        let five = CompactRootView.height(
            for: rows, expanded: try request(command: (1...5).map(String.init).joined(separator: "\n")))
        let forty = CompactRootView.height(
            for: rows, expanded: try request(command: (1...40).map(String.init).joined(separator: "\n")))

        XCTAssertEqual(forty, five)
    }

    /// One at a time, newest first: two questions open at once is most
    /// of the panel.
    func testOnlyTheNewestRequestIsExpanded() throws {
        let older = try request(id: "older", expiresIn: 10)
        let newer = try request(id: "newer", expiresIn: 30)

        XCTAssertEqual(CompactRootView.expandedRequest(from: [older, newer])?.id, "newer")
    }

    func testNothingIsExpandedWithoutARequest() {
        XCTAssertNil(CompactRootView.expandedRequest(from: []))
    }

    /// The question belongs to a session; if that session is not on
    /// screen the row cannot carry it.
    func testARequestForAHiddenSessionIsNotExpanded() throws {
        let hidden = try request(pid: 999)

        XCTAssertNil(CompactRootView.expandedRequest(from: [hidden], visiblePIDs: [1, 2]))
    }

}
