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

    func testHeightFollowsTheRowCount() {
        let two = CompactRootView.height(rows: 2)
        let four = CompactRootView.height(rows: 4)

        XCTAssertEqual(four - two, 2 * CompactSessionRow.height)
    }

    func testAnEmptyPanelStillHasItsChrome() {
        XCTAssertGreaterThan(CompactRootView.height(rows: 0), 0)
    }

    /// Four sessions were the number this was designed around: a third
    /// of the full panel rather than all of it.
    func testFourSessionsAreWellUnderTheFullPanel() {
        XCTAssertLessThan(CompactRootView.height(rows: 4), 420 * 0.5)
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

    func testIdleSessionsAreOrderedByMostRecent() {
        let order = CompactRootView.visible(
            sessions: [session("old", quietFor: 3600), session("recent", quietFor: 30)],
            cap: 5)

        XCTAssertEqual(order.map(\.displayName), ["recent", "old"])
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
}
