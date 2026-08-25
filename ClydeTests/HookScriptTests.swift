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

    /// A symlink named `claude` pointing at `/bin/bash`, interposed as
    /// the hook's parent process. The hook's `find_claude_pid` walks
    /// the PPID chain looking for a process whose comm basename is
    /// `claude` and exits early ("WARN no claude ancestor") when none
    /// exists — so without this interposer, every positive assertion
    /// (file written / file removed) only passed when `swift test`
    /// itself happened to run under a Claude Code session, and failed
    /// in a plain terminal or CI. Negative assertions passed either
    /// way, masking the gap.
    ///
    /// Why a symlink: macOS `ps -o comm=` reports the process's
    /// argv[0] (via KERN_PROCARGS2), which Process sets to the
    /// executable path it was given — the symlink path, ending in
    /// `claude`. The kernel meanwhile executes the real `/bin/bash`
    /// from its blessed location, so Apple Silicon's code-signing
    /// enforcement has nothing to kill. The two rejected designs:
    /// a renamed *copy* of `/bin/bash` gets SIGKILLed on Apple Silicon
    /// (platform binary outside its original location), and a shebang
    /// wrapper script reports the *interpreter* as argv[0], so comm
    /// reads `bash`, not `claude`.
    private static let fakeClaudeURL: URL = {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clyde-hook-tests-bin-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let claude = dir.appendingPathComponent("claude")
        try? FileManager.default.createSymbolicLink(
            at: claude, withDestinationURL: URL(fileURLWithPath: "/bin/bash"))
        return claude
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
        let task = try startHook(payload: payload, home: home)
        task.waitUntilExit()
        return task.terminationStatus
    }

    /// Launches the hook without waiting for it. Claude Code fires each
    /// hook event as its OWN process with no ordering guarantee between
    /// them, so any test that runs events strictly one-after-another is
    /// modelling an execution order production does not provide. Tests
    /// that care about inter-event ordering use this to overlap them.
    private func startHook(payload: String, home: URL) throws -> Process {
        let task = Process()
        // Launch as `claude → bash → hook` so the hook process has a
        // `claude` ancestor at its immediate PPID. The `; exit $?`
        // matters: with a single simple command bash tail-exec()s it,
        // replacing the `claude` process and losing the ancestor; the
        // explicit exit also propagates the hook's status.
        task.executableURL = Self.fakeClaudeURL
        task.arguments = ["-c", #"/bin/bash "$0"; exit $?"#, Self.hookScriptURL.path]
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
        return task
    }

    private func eventsDir(in home: URL) -> URL {
        home.appendingPathComponent(".clyde/events")
    }

    private func agentsDir(in home: URL, sessionId: String) -> URL {
        home.appendingPathComponent(".clyde/state/\(sessionId)-agents")
    }

    /// Filenames inside `-agents/`, sorted for stable assertions.
    private func agentFiles(in home: URL, sessionId: String) -> [String] {
        let dir = agentsDir(in: home, sessionId: sessionId)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return files.filter { $0.hasSuffix(".json") }.sorted()
    }

    private func agentJSON(in home: URL, sessionId: String, file: String) -> [String: Any] {
        let url = agentsDir(in: home, sessionId: sessionId).appendingPathComponent(file)
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return json
    }

    // MARK: - Subagent payload builders (shapes captured from a real
    // Claude Code session — SubagentStart/Stop carry `agent_id` and
    // `agent_type` but NO `tool_use_id`, and no description.)

    private func preToolUseAgent(sid: String, toolUseID: String, type: String, description: String) -> String {
        #"{"hook_event_name":"PreToolUse","session_id":"\#(sid)","cwd":"/tmp","tool_name":"Agent","tool_use_id":"\#(toolUseID)","tool_input":{"subagent_type":"\#(type)","description":"\#(description)","prompt":"do the thing"}}"#
    }

    private func postToolUseAgent(sid: String, toolUseID: String, type: String, description: String) -> String {
        #"{"hook_event_name":"PostToolUse","session_id":"\#(sid)","cwd":"/tmp","tool_name":"Agent","tool_use_id":"\#(toolUseID)","duration_ms":5750,"tool_input":{"subagent_type":"\#(type)","description":"\#(description)","prompt":"do the thing"}}"#
    }

    private func subagentStart(sid: String, agentID: String, type: String) -> String {
        #"{"hook_event_name":"SubagentStart","session_id":"\#(sid)","cwd":"/tmp","agent_id":"\#(agentID)","agent_type":"\#(type)"}"#
    }

    private func teammateIdle(sid: String, agentID: String, type: String) -> String {
        #"{"hook_event_name":"TeammateIdle","session_id":"\#(sid)","cwd":"/tmp","agent_id":"\#(agentID)","agent_type":"\#(type)"}"#
    }

    private func subagentStop(sid: String, agentID: String, type: String) -> String {
        #"{"hook_event_name":"SubagentStop","session_id":"\#(sid)","cwd":"/tmp","agent_id":"\#(agentID)","agent_type":"\#(type)","last_assistant_message":"done"}"#
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

    // MARK: - Subagent lifecycle keyed on agent_id

    /// `SubagentStart` must adopt the pending entry written by
    /// `PreToolUse(Agent)` and re-key it under `agent_id`. The two
    /// events share no identifier — `SubagentStart` carries no
    /// `tool_use_id` — so the claim correlates on `agent_type`, and
    /// the description (which only ever arrives on `PreToolUse`) has
    /// to survive the transition or the panel loses its second line.
    func testSubagentStartClaimsPendingEntryUnderAgentID() throws {
        let home = tempHome()
        let sid = "11111111-aaaa-bbbb-cccc-000000000001"

        try runHook(payload: preToolUseAgent(sid: sid, toolUseID: "toolu_alpha", type: "Explore", description: "Locate hook log rotation"), home: home)
        try runHook(payload: subagentStart(sid: sid, agentID: "a83da9190f4523b09", type: "Explore"), home: home)

        XCTAssertEqual(
            agentFiles(in: home, sessionId: sid), ["a83da9190f4523b09.json"],
            "SubagentStart must re-key the pending entry under agent_id"
        )
        let json = agentJSON(in: home, sessionId: sid, file: "a83da9190f4523b09.json")
        XCTAssertEqual(json["agent_id"] as? String, "a83da9190f4523b09")
        XCTAssertEqual(json["subagent_type"] as? String, "Explore")
        XCTAssertEqual(
            json["summary"] as? String, "Locate hook log rotation",
            "the description only arrives on PreToolUse — it must survive the claim"
        )
    }

    /// The bug this rework exists for. `PostToolUse(Agent)` fires when
    /// the dispatch returns, which for a background agent is long
    /// before the agent finishes — measured at 5s ahead of
    /// `SubagentStop` on a real session. Deleting the entry there tore
    /// the row out of the panel mid-work, so once an entry is claimed
    /// `PostToolUse` must leave it alone.
    func testPostToolUseAgentLeavesClaimedSubagentRunning() throws {
        let home = tempHome()
        let sid = "11111111-aaaa-bbbb-cccc-000000000002"

        try runHook(payload: preToolUseAgent(sid: sid, toolUseID: "toolu_beta", type: "Explore", description: "Find the thing"), home: home)
        try runHook(payload: subagentStart(sid: sid, agentID: "agent_beta", type: "Explore"), home: home)
        try runHook(payload: postToolUseAgent(sid: sid, toolUseID: "toolu_beta", type: "Explore", description: "Find the thing"), home: home)

        XCTAssertEqual(
            agentFiles(in: home, sessionId: sid), ["agent_beta.json"],
            "PostToolUse(Agent) must not remove a claimed subagent — the agent outlives its dispatching tool call"
        )
    }

    /// `SubagentStop` is the only event that means the agent is
    /// actually done, so it owns the teardown.
    func testSubagentStopRemovesClaimedEntry() throws {
        let home = tempHome()
        let sid = "11111111-aaaa-bbbb-cccc-000000000003"

        try runHook(payload: preToolUseAgent(sid: sid, toolUseID: "toolu_gamma", type: "Explore", description: "Find the thing"), home: home)
        try runHook(payload: subagentStart(sid: sid, agentID: "agent_gamma", type: "Explore"), home: home)
        try runHook(payload: postToolUseAgent(sid: sid, toolUseID: "toolu_gamma", type: "Explore", description: "Find the thing"), home: home)
        try runHook(payload: subagentStop(sid: sid, agentID: "agent_gamma", type: "Explore"), home: home)

        XCTAssertEqual(
            agentFiles(in: home, sessionId: sid), [],
            "SubagentStop must remove the claimed entry"
        )
    }

    /// Safety net for the case where `SubagentStart` never arrives —
    /// an older `claude`, or a dispatch that fails before the agent
    /// runs. Without this the pending entry would linger until the
    /// 30-minute GC and show a phantom agent in the panel.
    func testPostToolUseAgentRemovesUnclaimedPendingEntry() throws {
        let home = tempHome()
        let sid = "11111111-aaaa-bbbb-cccc-000000000004"

        try runHook(payload: preToolUseAgent(sid: sid, toolUseID: "toolu_delta", type: "Explore", description: "Find the thing"), home: home)
        try runHook(payload: postToolUseAgent(sid: sid, toolUseID: "toolu_delta", type: "Explore", description: "Find the thing"), home: home)

        XCTAssertEqual(
            agentFiles(in: home, sessionId: sid), [],
            "an unclaimed pending entry must still be swept by PostToolUse"
        )
    }

    /// Two agents of the same type dispatched together: both rows must
    /// survive the claim, keyed on their own agent_ids. Summaries can
    /// legitimately swap between same-type siblings — the count cannot.
    func testParallelSameTypeAgentsEachGetTheirOwnEntry() throws {
        let home = tempHome()
        let sid = "11111111-aaaa-bbbb-cccc-000000000005"

        try runHook(payload: preToolUseAgent(sid: sid, toolUseID: "toolu_one", type: "Explore", description: "First job"), home: home)
        try runHook(payload: preToolUseAgent(sid: sid, toolUseID: "toolu_two", type: "Explore", description: "Second job"), home: home)
        try runHook(payload: subagentStart(sid: sid, agentID: "agent_one", type: "Explore"), home: home)
        try runHook(payload: subagentStart(sid: sid, agentID: "agent_two", type: "Explore"), home: home)

        XCTAssertEqual(
            agentFiles(in: home, sessionId: sid), ["agent_one.json", "agent_two.json"],
            "each concurrently dispatched agent must claim its own pending entry"
        )
    }

    /// The defect live testing caught. `PreToolUse` and `SubagentStart`
    /// are separate processes fired at the same moment, and the
    /// `PreToolUse` hook is the slower of the two (~490ms vs ~390ms
    /// measured — it probes cleat and shells out to lsof), so
    /// `SubagentStart` routinely runs FIRST. A claim that only ever
    /// looks backwards finds nothing, `PostToolUse` then sweeps the
    /// late-arriving pending entry, and the agent never appears at all.
    func testSubagentStartArrivingBeforePreToolUseStillYieldsOneEntry() throws {
        let home = tempHome()
        let sid = "22222222-aaaa-bbbb-cccc-000000000001"

        try runHook(payload: subagentStart(sid: sid, agentID: "agent_early", type: "Explore"), home: home)
        try runHook(payload: preToolUseAgent(sid: sid, toolUseID: "toolu_late", type: "Explore", description: "Late description"), home: home)
        try runHook(payload: postToolUseAgent(sid: sid, toolUseID: "toolu_late", type: "Explore", description: "Late description"), home: home)

        XCTAssertEqual(
            agentFiles(in: home, sessionId: sid), ["agent_early.json"],
            "SubagentStart landing first must not lose the agent — the merge has to work in both directions"
        )
        XCTAssertEqual(
            agentJSON(in: home, sessionId: sid, file: "agent_early.json")["summary"] as? String,
            "Late description",
            "PreToolUse arriving second must fill in the description it alone carries"
        )
    }

    /// Both hooks launched at once, which is what Claude Code actually
    /// does. Whoever wins, the session must end up with exactly one row
    /// for one agent — never two.
    func testConcurrentPreToolUseAndSubagentStartYieldExactlyOneEntry() throws {
        for attempt in 0..<5 {
            let home = tempHome()
            let sid = "33333333-aaaa-bbbb-cccc-00000000000\(attempt)"

            let a = try startHook(payload: preToolUseAgent(sid: sid, toolUseID: "toolu_race", type: "Explore", description: "Racy job"), home: home)
            let b = try startHook(payload: subagentStart(sid: sid, agentID: "agent_race", type: "Explore"), home: home)
            a.waitUntilExit()
            b.waitUntilExit()

            XCTAssertEqual(
                agentFiles(in: home, sessionId: sid), ["agent_race.json"],
                "attempt \(attempt): concurrent dispatch must converge on exactly one entry keyed by agent_id"
            )
        }
    }

    /// An interrupted agent never gets a SubagentStop, so nothing would
    /// tear its entry down — it would sit in the panel as a phantom row
    /// until the 30-minute GC. v27 swept it via PostToolUse; the
    /// agent_id rework has to keep that guarantee.
    func testInterruptSweepsClaimedAgents() throws {
        let home = tempHome()
        let sid = "44444444-aaaa-bbbb-cccc-000000000001"

        try runHook(payload: preToolUseAgent(sid: sid, toolUseID: "toolu_doomed", type: "Explore", description: "Doomed job"), home: home)
        try runHook(payload: subagentStart(sid: sid, agentID: "agent_doomed", type: "Explore"), home: home)
        XCTAssertEqual(agentFiles(in: home, sessionId: sid), ["agent_doomed.json"], "precondition: agent is tracked")

        let interrupt = #"{"hook_event_name":"PostToolUseFailure","session_id":"\#(sid)","cwd":"/tmp","tool_name":"Agent","tool_use_id":"toolu_doomed","is_interrupt":true,"tool_input":{"subagent_type":"Explore"}}"#
        try runHook(payload: interrupt, home: home)

        XCTAssertEqual(
            agentFiles(in: home, sessionId: sid), [],
            "a user interrupt kills the whole turn — no agent row may survive it"
        )
    }

    // MARK: - TeammateIdle

    /// `TeammateIdle` addresses the agent by `agent_id` — the same key
    /// space the subagent records now live in — so it can annotate an
    /// existing record in place rather than needing a store of its own.
    func testTeammateIdleMarksExistingAgentRecordIdle() throws {
        let home = tempHome()
        let sid = "55555555-aaaa-bbbb-cccc-000000000001"

        try runHook(payload: preToolUseAgent(sid: sid, toolUseID: "toolu_tm", type: "Explore", description: "Team job"), home: home)
        try runHook(payload: subagentStart(sid: sid, agentID: "agent_tm", type: "Explore"), home: home)
        try runHook(payload: teammateIdle(sid: sid, agentID: "agent_tm", type: "Explore"), home: home)

        let json = agentJSON(in: home, sessionId: sid, file: "agent_tm.json")
        XCTAssertEqual(json["idle"] as? Bool, true, "TeammateIdle must mark the record idle")
        XCTAssertEqual(
            json["summary"] as? String, "Team job",
            "annotating must not clobber the rest of the record"
        )
    }

    /// A teammate we never saw start must NOT materialise a row. Inventing
    /// a record from an idle notification is how phantom rows appear — the
    /// event is log-only in that case.
    func testTeammateIdleWithoutExistingRecordWritesNothing() throws {
        let home = tempHome()
        let sid = "55555555-aaaa-bbbb-cccc-000000000002"

        try runHook(payload: teammateIdle(sid: sid, agentID: "agent_ghost", type: "Explore"), home: home)

        XCTAssertEqual(
            agentFiles(in: home, sessionId: sid), [],
            "an unknown teammate going idle must not create a row"
        )
    }

    /// Deliberately NOT an attention signal. v0.5.1 mapped an
    /// ambiguous-but-attention-sounding event onto the badge and v0.5.2
    /// had to revert it a day later; until the real firing frequency of
    /// TeammateIdle is known, it must not light the panel up.
    func testTeammateIdleDoesNotRaiseAttention() throws {
        let home = tempHome()
        let sid = "55555555-aaaa-bbbb-cccc-000000000003"

        try runHook(payload: preToolUseAgent(sid: sid, toolUseID: "toolu_tm2", type: "Explore", description: "Team job"), home: home)
        try runHook(payload: subagentStart(sid: sid, agentID: "agent_tm2", type: "Explore"), home: home)
        try runHook(payload: teammateIdle(sid: sid, agentID: "agent_tm2", type: "Explore"), home: home)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: eventFile(in: home, sessionId: sid).path),
            "TeammateIdle must stay out of the attention pipeline"
        )
    }
}
