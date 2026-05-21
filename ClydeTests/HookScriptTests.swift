import XCTest
@testable import Clyde

/// Drives the bundled `clyde-hook.sh` as a real subprocess with a
/// sandboxed `$HOME`. The bash script itself is the contract for the
/// rest of the app — every other piece of state (`-info`, `-busy`,
/// `-tool`, `events/*.json`, …) is produced here and consumed by
/// ProcessMonitor / AttentionMonitor. The Swift-side unit tests
/// already cover the consumer half exhaustively; this file pins down
/// the producer half for the hook events whose behaviour is subtle or
/// recently changed, so a regression in the bash logic shows up in
/// CI instead of in users' panels.
///
/// We're not aiming for full hook coverage here — the established
/// pattern is "manual smoke-test the hook" per CLAUDE.md. This is a
/// belt-and-suspenders pass on the high-leverage paths.
final class HookScriptTests: XCTestCase {

    /// Path to the bundled hook script. Derived from `#file` so the
    /// test works regardless of the process working directory (Xcode
    /// runs tests from DerivedData; `swift test` runs from the repo
    /// root — both need to resolve to the same script).
    private static let hookScriptURL: URL = {
        URL(fileURLWithPath: #file)
            .deletingLastPathComponent()                     // ClydeTests/
            .deletingLastPathComponent()                     // <repo>/
            .appendingPathComponent("Clyde/Resources/clyde-hook.sh")
    }()

    /// Fresh `$HOME`-equivalent per test so `~/.clyde/state/` and
    /// `~/.clyde/events/` start empty and don't leak between cases or
    /// pollute the developer's real Clyde install.
    private func tempHome() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clyde-hook-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Runs the hook script with the given JSON payload on stdin and
    /// `$HOME` pointed at `home`. Returns the script's stdout (rarely
    /// useful — the contract is the files it writes, not its
    /// stdout). Throws if the script fails to launch; a non-zero exit
    /// is asserted by the caller since the hook MUST always exit 0 to
    /// avoid raising "Stop hook error" in Claude's session.
    @discardableResult
    private func runHook(payload: String, home: URL) throws -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = [Self.hookScriptURL.path]
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = home.path
        task.environment = env

        let stdin = Pipe()
        task.standardInput = stdin
        task.standardOutput = Pipe()
        task.standardError = Pipe()

        try task.run()
        if let data = payload.data(using: .utf8) {
            stdin.fileHandleForWriting.write(data)
        }
        try? stdin.fileHandleForWriting.close()
        task.waitUntilExit()
        return task.terminationStatus
    }

    private func eventsDir(in home: URL) -> URL {
        home.appendingPathComponent(".clyde/events")
    }

    private func eventFile(in home: URL, sessionId: String) -> URL {
        eventsDir(in: home).appendingPathComponent("\(sessionId).json")
    }

    // MARK: - Notification → attention event

    /// Hook v27 regression: `"Claude is waiting for your input"` is
    /// the IDLE-state marker Claude fires after every Stop in
    /// bypass-permissions mode — not an attention signal. v26 had
    /// (mistakenly) treated it as attention, which lit up the "Needs
    /// Input" badge after every routine turn. The match must NOT
    /// produce an event file for this message.
    func testNotificationWaitingForInputDoesNotWriteAttentionFile() throws {
        let home = tempHome()
        let sid = "aaaaaaaa-1111-2222-3333-444444444444"
        let payload = #"{"hook_event_name":"Notification","session_id":"\#(sid)","cwd":"/tmp","message":"Claude is waiting for your input"}"#

        let exit = try runHook(payload: payload, home: home)
        XCTAssertEqual(exit, 0, "hook must always exit 0")

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: eventFile(in: home, sessionId: sid).path),
            #"idle-state Notification ("waiting for your input") must NOT write an attention event — that would false-positive the Needs Input badge after every turn"#
        )
    }

    /// The match is intentionally conservative: only known
    /// attention-bearing messages produce an event file. Anything else
    /// stays log-only so benign info notifications can't pin the
    /// "Needs Input" badge.
    func testBenignNotificationDoesNotWriteAttentionFile() throws {
        let home = tempHome()
        let sid = "bbbbbbbb-1111-2222-3333-444444444444"
        let payload = #"{"hook_event_name":"Notification","session_id":"\#(sid)","cwd":"/tmp","message":"Build output truncated for display"}"#

        let exit = try runHook(payload: payload, home: home)
        XCTAssertEqual(exit, 0)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: eventFile(in: home, sessionId: sid).path),
            "informational Notifications must stay log-only"
        )
    }

    /// Permission-flavoured notifications carry the same user-attention
    /// semantics as "waiting for your input" — surface the badge.
    func testNotificationPermissionMessageWritesAttentionFile() throws {
        let home = tempHome()
        let sid = "cccccccc-1111-2222-3333-444444444444"
        let payload = #"{"hook_event_name":"Notification","session_id":"\#(sid)","cwd":"/tmp","message":"Claude needs your permission to use Bash"}"#

        let exit = try runHook(payload: payload, home: home)
        XCTAssertEqual(exit, 0)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: eventFile(in: home, sessionId: sid).path),
            "Notification('needs your permission') must write attention event"
        )
    }

    // MARK: - UserPromptSubmit clears attention

    /// When the user types a reply, any lingering attention event from
    /// a prior Notification must drop immediately. Previously the
    /// badge could linger for several seconds between the user typing
    /// and the next PreToolUse firing (which was the only sweeper).
    func testUserPromptSubmitClearsStaleAttentionFile() throws {
        let home = tempHome()
        let sid = "dddddddd-1111-2222-3333-444444444444"

        // Plant a stale attention event the way Notification would.
        try FileManager.default.createDirectory(at: eventsDir(in: home), withIntermediateDirectories: true)
        let stale = eventFile(in: home, sessionId: sid)
        try #"{"pid": 99999, "message": "stale"}"#.write(to: stale, atomically: true, encoding: .utf8)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stale.path), "precondition: stale file present")

        let payload = #"{"hook_event_name":"UserPromptSubmit","session_id":"\#(sid)","cwd":"/tmp"}"#
        let exit = try runHook(payload: payload, home: home)
        XCTAssertEqual(exit, 0)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: stale.path),
            "UserPromptSubmit must clear events/<sid>.json so the attention badge drops the moment the user replies"
        )
    }
}
