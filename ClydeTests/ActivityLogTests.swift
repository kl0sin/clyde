import XCTest
import Combine
@testable import Clyde

/// First coverage for `ActivityLog`, which had none. It shipped on the
/// strength of "you can see the timeline in the panel", which is exactly
/// the kind of confidence that hid three live bugs in the v0.7.0 work.
///
/// Style follows `ProcessMonitorTests`: real `ProcessMonitor` and
/// `AttentionMonitor` over temporary directories, driven by writing the
/// same marker files the hook writes. Nothing is mocked — the point is to
/// exercise the publisher plumbing, since ActivityLog's whole job is
/// diffing what those publishers emit.
@MainActor
final class ActivityLogTests: XCTestCase {

    private var stateDir: URL!
    private var eventsDir: URL!

    override func setUp() async throws {
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clyde-activitylog-state-\(UUID().uuidString)")
        eventsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clyde-activitylog-events-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: eventsDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: stateDir)
        try? FileManager.default.removeItem(at: eventsDir)
    }

    // MARK: - Harness

    private func emptyShell() -> MockShellExecutor {
        let shell = MockShellExecutor()
        shell.responses["pgrep"] = ""
        return shell
    }

    private func makeMonitor() -> ProcessMonitor {
        ProcessMonitor(
            shell: emptyShell(), pollingInterval: 1, stateDir: stateDir,
            isLiveClaudeProcessCheck: { _ in true })
    }

    /// Writes the `-info` file SessionStart produces. `source` is what
    /// separates a fresh session from a resume or an auto-compact restart.
    @discardableResult
    private func writeInfo(sessionId: String, cwd: String = "/repo", source: String = "startup") -> pid_t {
        let pid = getpid()
        let body = #"{"session_id":"\#(sessionId)","pid":\#(pid),"cwd":"\#(cwd)","started_at":0,"source":"\#(source)"}"#
        try? body.write(to: stateDir.appendingPathComponent("\(sessionId)-info"),
                        atomically: true, encoding: .utf8)
        return pid
    }

    private func writeBusy(sessionId: String, pid: pid_t) {
        let body = #"{"session_id":"\#(sessionId)","pid":\#(pid),"cwd":"/repo","timestamp":0}"#
        try? body.write(to: stateDir.appendingPathComponent("\(sessionId)-busy"),
                        atomically: true, encoding: .utf8)
    }

    private func removeBusy(sessionId: String) {
        try? FileManager.default.removeItem(at: stateDir.appendingPathComponent("\(sessionId)-busy"))
    }

    /// ActivityLog receives on `RunLoop.main`, so a poll's events land a
    /// turn of the loop later. Spin until the feed reaches `count` rather
    /// than sleeping a fixed interval and hoping.
    private func waitForEvents(_ log: ActivityLog, count: Int, timeout: TimeInterval = 3) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while log.events.count < count && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertGreaterThanOrEqual(log.events.count, count,
                                    "timed out waiting for \(count) event(s); got \(log.events.map(\.kind))")
    }

    // MARK: - Session lifecycle

    func testNewSessionEmitsSessionStarted() async throws {
        let monitor = makeMonitor()
        let log = ActivityLog(processMonitor: monitor, attentionMonitor: AttentionMonitor(eventsDir: eventsDir))

        writeInfo(sessionId: "s1")
        await monitor.poll()
        try await waitForEvents(log, count: 1)

        XCTAssertEqual(log.events.first?.kind, .sessionStarted)
    }

    /// A session that already exists when Clyde launches must be seeded
    /// silently — otherwise every restart floods the timeline with
    /// "started" rows for sessions that started hours ago.
    func testPreexistingSessionsAreSeededWithoutEvents() async throws {
        writeInfo(sessionId: "s1")
        let monitor = makeMonitor()
        await monitor.poll()

        let log = ActivityLog(processMonitor: monitor, attentionMonitor: AttentionMonitor(eventsDir: eventsDir))
        await monitor.poll()
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(log.events, [])
    }

    /// `source: "resume"` is a continued conversation, not a new one.
    func testResumedSessionIsDistinguishedFromAFreshOne() async throws {
        let monitor = makeMonitor()
        let log = ActivityLog(processMonitor: monitor, attentionMonitor: AttentionMonitor(eventsDir: eventsDir))

        writeInfo(sessionId: "s1", source: "resume")
        await monitor.poll()
        try await waitForEvents(log, count: 1)

        XCTAssertEqual(log.events.first?.kind, .sessionResumed)
    }

    /// Auto-compact reuses the PID and changes nothing but `source`, so it
    /// is the one transition the fingerprint short-circuit could swallow.
    func testAutoCompactInTheSamePIDEmitsSessionCompacted() async throws {
        let monitor = makeMonitor()
        let log = ActivityLog(processMonitor: monitor, attentionMonitor: AttentionMonitor(eventsDir: eventsDir))

        writeInfo(sessionId: "s1", source: "startup")
        await monitor.poll()
        try await waitForEvents(log, count: 1)

        writeInfo(sessionId: "s1", source: "compact")
        await monitor.poll()
        try await waitForEvents(log, count: 2)

        // Newest first: `append` inserts at index 0 so the timeline
        // renders without reversing.
        XCTAssertEqual(log.events.map(\.kind), [.sessionCompacted, .sessionStarted])
    }

    func testDisappearingSessionEmitsSessionEnded() async throws {
        let monitor = makeMonitor()
        let log = ActivityLog(processMonitor: monitor, attentionMonitor: AttentionMonitor(eventsDir: eventsDir))

        writeInfo(sessionId: "s1")
        await monitor.poll()
        try await waitForEvents(log, count: 1)

        try FileManager.default.removeItem(at: stateDir.appendingPathComponent("s1-info"))
        await monitor.poll()
        try await waitForEvents(log, count: 2)

        XCTAssertEqual(log.events.first?.kind, .sessionEnded, "newest event comes first")
    }

    // MARK: - Status transitions

    func testWorkThenReplyEmitsPromptSubmittedThenSessionReady() async throws {
        let monitor = makeMonitor()
        let log = ActivityLog(processMonitor: monitor, attentionMonitor: AttentionMonitor(eventsDir: eventsDir))

        let pid = writeInfo(sessionId: "s1")
        await monitor.poll()
        try await waitForEvents(log, count: 1)

        writeBusy(sessionId: "s1", pid: pid)
        await monitor.poll()
        try await waitForEvents(log, count: 2)

        removeBusy(sessionId: "s1")
        await monitor.poll()
        try await waitForEvents(log, count: 3)

        XCTAssertEqual(log.events.map(\.kind), [.sessionReady, .promptSubmitted, .sessionStarted])
    }

    /// The feed must not re-announce a state it already reported; the
    /// monitors publish on every poll whether or not anything changed.
    func testRepeatedPollsWithNoChangeEmitNothingNew() async throws {
        let monitor = makeMonitor()
        let log = ActivityLog(processMonitor: monitor, attentionMonitor: AttentionMonitor(eventsDir: eventsDir))

        writeInfo(sessionId: "s1")
        await monitor.poll()
        try await waitForEvents(log, count: 1)

        for _ in 0..<5 { await monitor.poll() }
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(log.events.count, 1)
    }

    // MARK: - Housekeeping

    func testClearEmptiesTheFeed() async throws {
        let monitor = makeMonitor()
        let log = ActivityLog(processMonitor: monitor, attentionMonitor: AttentionMonitor(eventsDir: eventsDir))

        writeInfo(sessionId: "s1")
        await monitor.poll()
        try await waitForEvents(log, count: 1)

        log.clear()

        XCTAssertEqual(log.events, [])
    }
}
