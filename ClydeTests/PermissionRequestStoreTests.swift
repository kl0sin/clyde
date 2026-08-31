import XCTest
@testable import Clyde

/// The panel's half of answering a permission request: read what the
/// hook wrote, show it while it is still answerable, and write the
/// answer back where the waiting hook will find it.
///
/// Everything here is about not answering the wrong question. A request
/// whose window has closed is already being answered in the terminal; a
/// file we cannot parse is not a question at all.
@MainActor
final class PermissionRequestStoreTests: XCTestCase {

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clyde-permissions-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @discardableResult
    private func writeRequest(in dir: URL,
                              id: String,
                              tool: String = "Bash",
                              input: [String: Any] = ["command": "rm -rf build"],
                              expiresIn: TimeInterval = 30) throws -> URL {
        let now = Int(Date().timeIntervalSince1970)
        let body: [String: Any] = [
            "request_id": id,
            "session_id": "sess-\(id)",
            "pid": 4242,
            "cwd": "/repo",
            "tool_name": tool,
            "tool_input": input,
            "created_at": now,
            "expires_at": Int(Date().addingTimeInterval(expiresIn).timeIntervalSince1970)
        ]
        let url = dir.appendingPathComponent("\(id).request")
        try JSONSerialization.data(withJSONObject: body).write(to: url)
        return url
    }

    func testAWrittenRequestBecomesPending() throws {
        let dir = tempDir()
        let store = PermissionRequestStore(directory: dir, isEnabled: { true })
        try writeRequest(in: dir, id: "r1")

        store.scan()

        XCTAssertEqual(store.pending.count, 1)
        XCTAssertEqual(store.pending.first?.toolName, "Bash")
        XCTAssertEqual(store.pending.first?.summary, "rm -rf build")
        XCTAssertEqual(store.pending.first?.pid, 4242)
    }

    /// The hook stops waiting when the window closes, and the terminal
    /// takes the question. Showing it after that invites answering
    /// something nobody is listening for.
    func testAnExpiredRequestIsNotPending() throws {
        let dir = tempDir()
        let store = PermissionRequestStore(directory: dir, isEnabled: { true })
        try writeRequest(in: dir, id: "old", expiresIn: -1)

        store.scan()

        XCTAssertTrue(store.pending.isEmpty)
    }

    func testAnsweringWritesTheDecisionBesideTheRequest() throws {
        let dir = tempDir()
        let store = PermissionRequestStore(directory: dir, isEnabled: { true })
        try writeRequest(in: dir, id: "r1")
        store.scan()

        store.answer(try XCTUnwrap(store.pending.first), with: .allow)

        let written = try JSONSerialization.jsonObject(
            with: Data(contentsOf: dir.appendingPathComponent("r1.decision"))) as? [String: Any]
        XCTAssertEqual(written?["behavior"] as? String, "allow")
    }

    func testDenialIsWrittenTheSameWay() throws {
        let dir = tempDir()
        let store = PermissionRequestStore(directory: dir, isEnabled: { true })
        try writeRequest(in: dir, id: "r1")
        store.scan()

        store.answer(try XCTUnwrap(store.pending.first), with: .deny)

        let written = try JSONSerialization.jsonObject(
            with: Data(contentsOf: dir.appendingPathComponent("r1.decision"))) as? [String: Any]
        XCTAssertEqual(written?["behavior"] as? String, "deny")
    }

    /// The row has to leave at once. A question that stays on screen
    /// after it is answered invites a second click on a request the
    /// hook has already stopped waiting for.
    func testAnAnsweredRequestLeavesThePanelImmediately() throws {
        let dir = tempDir()
        let store = PermissionRequestStore(directory: dir, isEnabled: { true })
        try writeRequest(in: dir, id: "r1")
        store.scan()

        store.answer(try XCTUnwrap(store.pending.first), with: .allow)

        XCTAssertTrue(store.pending.isEmpty)
    }

    func testAMalformedRequestIsIgnoredRatherThanCrashing() throws {
        let dir = tempDir()
        try "{ not json".write(to: dir.appendingPathComponent("bad.request"),
                               atomically: true, encoding: .utf8)
        let store = PermissionRequestStore(directory: dir, isEnabled: { true })

        store.scan()

        XCTAssertTrue(store.pending.isEmpty)
    }

    /// The decision file the hook already wrote its answer into, and
    /// the readiness marker, are not requests.
    func testOnlyRequestFilesAreRead() throws {
        let dir = tempDir()
        try "".write(to: dir.appendingPathComponent("ready"), atomically: true, encoding: .utf8)
        try #"{"behavior":"allow"}"#.write(to: dir.appendingPathComponent("r0.decision"),
                                          atomically: true, encoding: .utf8)
        try writeRequest(in: dir, id: "r1")
        let store = PermissionRequestStore(directory: dir, isEnabled: { true })

        store.scan()

        XCTAssertEqual(store.pending.map(\.id), ["r1"])
    }

    /// Two sessions can be asking at once, and the newest question is
    /// the one the user is looking at.
    func testRequestsAreOrderedNewestFirst() throws {
        let dir = tempDir()
        let store = PermissionRequestStore(directory: dir, isEnabled: { true })
        try writeRequest(in: dir, id: "older", expiresIn: 20)
        try writeRequest(in: dir, id: "newer", expiresIn: 40)

        store.scan()

        XCTAssertEqual(store.pending.map(\.id), ["newer", "older"])
    }

    // MARK: - What the row says

    func testTheSummaryIsTheCommandForBash() {
        XCTAssertEqual(PermissionRequest.summary(tool: "Bash",
                                                 input: ["command": "git push --force"]),
                       "git push --force")
    }

    func testTheSummaryIsThePathForFileTools() {
        XCTAssertEqual(PermissionRequest.summary(tool: "Write",
                                                 input: ["file_path": "/etc/hosts"]),
                       "/etc/hosts")
    }

    /// Nothing is abbreviated: a shortened command invites approving
    /// something the user did not read.
    func testALongCommandIsNotTruncated() {
        let long = "echo " + String(repeating: "x", count: 500)
        XCTAssertEqual(PermissionRequest.summary(tool: "Bash", input: ["command": long]), long)
    }

    /// An unfamiliar tool still has to show something truthful.
    func testAnUnknownToolFallsBackToItsWholeInput() {
        let summary = PermissionRequest.summary(tool: "Mcp__weird", input: ["a": 1, "b": "two"])
        XCTAssertTrue(summary.contains("\"a\""), summary)
        XCTAssertTrue(summary.contains("two"), summary)
    }

    func testAToolWithNoInputSaysSoRatherThanShowingNothing() {
        XCTAssertEqual(PermissionRequest.summary(tool: "Read", input: [:]), "no arguments")
    }

    // MARK: - The setting, and the readiness the hook waits on

    /// Off by default. The hook waits only while Clyde says it is
    /// willing to answer, so with the feature off nobody pays the
    /// decision window on any permission request.
    func testDisabledMeansNoReadinessMarkerAndNoRequests() throws {
        let dir = tempDir()
        let store = PermissionRequestStore(directory: dir, isEnabled: { false })
        try writeRequest(in: dir, id: "r1")

        store.scan()

        XCTAssertTrue(store.pending.isEmpty, "nothing to click means the terminal asks")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("ready").path))
    }

    func testEnabledPublishesReadiness() throws {
        let dir = tempDir()
        let store = PermissionRequestStore(directory: dir, isEnabled: { true })

        store.scan()

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("ready").path))
    }

    /// The hook treats a stale marker as "Clyde is gone", so it has to
    /// keep being touched while Clyde is alive.
    func testReadinessIsRefreshedOnEveryScan() throws {
        let dir = tempDir()
        let store = PermissionRequestStore(directory: dir, isEnabled: { true })
        store.scan()
        let ready = dir.appendingPathComponent("ready")
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -600)], ofItemAtPath: ready.path)

        store.scan()

        let touched = try XCTUnwrap((try FileManager.default
            .attributesOfItem(atPath: ready.path))[.modificationDate] as? Date)
        XCTAssertLessThan(Date().timeIntervalSince(touched), 5)
    }

    /// Turning the setting off mid-session has to stop the waiting too,
    /// not just hide the rows.
    func testSwitchingOffRemovesTheReadinessMarker() throws {
        let dir = tempDir()
        var enabled = true
        let store = PermissionRequestStore(directory: dir, isEnabled: { enabled })
        store.scan()

        enabled = false
        store.scan()

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("ready").path))
    }

    /// Quitting is the same promise: nobody should wait on a Clyde that
    /// is not there.
    func testStoppingRemovesTheReadinessMarker() throws {
        let dir = tempDir()
        let store = PermissionRequestStore(directory: dir, isEnabled: { true })
        store.scan()

        store.stop()

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("ready").path))
    }


    /// An answer nobody collected — the hook died, or the window had
    /// already closed — would otherwise sit in the directory forever.
    func testOrphanedAnswersAreCleanedUp() throws {
        let dir = tempDir()
        let store = PermissionRequestStore(directory: dir, isEnabled: { true })
        let orphan = dir.appendingPathComponent("gone.decision")
        try #"{"behavior":"allow"}"#.write(to: orphan, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -300)], ofItemAtPath: orphan.path)

        store.scan()

        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
    }

    /// An answer written a moment ago belongs to a hook that is still
    /// reading it.
    func testAFreshAnswerIsLeftAlone() throws {
        let dir = tempDir()
        let store = PermissionRequestStore(directory: dir, isEnabled: { true })
        let fresh = dir.appendingPathComponent("live.decision")
        try #"{"behavior":"allow"}"#.write(to: fresh, atomically: true, encoding: .utf8)

        store.scan()

        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
    }

}
