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

    private func permissionsDir(in home: URL) -> URL {
        home.appendingPathComponent(".clyde/permissions")
    }

    private func requestFiles(in home: URL) -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(
            atPath: permissionsDir(in: home).path)) ?? []
        return files.filter { $0.hasSuffix(".request") }.sorted()
    }

    private func permissionRequest(sid: String,
                                   name: String = "Bash",
                                   command: String = "rm -rf build") -> String {
        #"{"hook_event_name":"PermissionRequest","session_id":"\#(sid)","cwd":"/repo","tool_name":"\#(name)","tool_input":{"command":"\#(command)","description":"Clean"}}"#
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

    private func toolsDir(in home: URL, sessionId: String) -> URL {
        home.appendingPathComponent(".clyde/state/\(sessionId)-tools")
    }

    private func toolFiles(in home: URL, sessionId: String) -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(
            atPath: toolsDir(in: home, sessionId: sessionId).path)) ?? []
        return files.filter { $0.hasSuffix(".json") }.sorted()
    }

    private func preToolUse(sid: String, toolUseID: String, name: String, command: String) -> String {
        #"{"hook_event_name":"PreToolUse","session_id":"\#(sid)","cwd":"/tmp","tool_name":"\#(name)","tool_use_id":"\#(toolUseID)","tool_input":{"command":"\#(command)"}}"#
    }

    private func postToolUse(sid: String, toolUseID: String, name: String) -> String {
        #"{"hook_event_name":"PostToolUse","session_id":"\#(sid)","cwd":"/tmp","tool_name":"\#(name)","tool_use_id":"\#(toolUseID)","tool_input":{"command":"x"}}"#
    }

    private func lastMessageJSON(in home: URL, sessionId: String) -> [String: Any] {
        let url = home.appendingPathComponent(".clyde/state/\(sessionId)-lastmsg")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return json
    }

    /// Contents of the `-tool` marker the panel renders as
    /// `<Tool> · <summary>` on the session row.
    /// The in-flight tool record. Since hook v30 each call occupies its
    /// own slot under `-tools/`; these cases drive a single call, so the
    /// sole slot is the one under test. Falls back to the pre-v30
    /// single-file marker.
    private func toolJSON(in home: URL, sessionId: String) -> [String: Any] {
        let dir = toolsDir(in: home, sessionId: sessionId)
        if let slot = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .first(where: { $0.hasSuffix(".json") }),
           let data = try? Data(contentsOf: dir.appendingPathComponent(slot)),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return json
        }
        let legacy = home.appendingPathComponent(".clyde/state/\(sessionId)-tool")
        guard let data = try? Data(contentsOf: legacy),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return json
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

    // MARK: - Bash summary readability

    /// Observed in the panel on a live session: `Bash · SP=/private/tmp/
    /// claude-501/-U…`. The summary is the command's first 40 characters,
    /// and a leading environment assignment eats every one of them, so the
    /// row names the tool and then says nothing about what it is doing.
    func testBashSummarySkipsLeadingEnvAssignment() throws {
        let home = tempHome()
        let sid = "bash-0001"

        try runHook(payload: #"{"hook_event_name":"PreToolUse","session_id":"\#(sid)","cwd":"/repo","tool_name":"Bash","tool_use_id":"toolu_b1","tool_input":{"command":"SP=/private/tmp/claude-501 swift test"}}"#, home: home)

        XCTAssertEqual(toolJSON(in: home, sessionId: sid)["summary"] as? String, "swift test")
    }

    func testBashSummarySkipsSeveralEnvAssignments() throws {
        let home = tempHome()
        let sid = "bash-0002"

        try runHook(payload: #"{"hook_event_name":"PreToolUse","session_id":"\#(sid)","cwd":"/repo","tool_name":"Bash","tool_use_id":"toolu_b2","tool_input":{"command":"FOO=1 BAR=2 make build"}}"#, home: home)

        XCTAssertEqual(toolJSON(in: home, sessionId: sid)["summary"] as? String, "make build")
    }

    /// `cd <somewhere> && <the actual thing>` is the other shape that
    /// spends the whole budget before saying anything.
    func testBashSummarySkipsLeadingCd() throws {
        let home = tempHome()
        let sid = "bash-0003"

        try runHook(payload: #"{"hook_event_name":"PreToolUse","session_id":"\#(sid)","cwd":"/repo","tool_name":"Bash","tool_use_id":"toolu_b3","tool_input":{"command":"cd /Users/me/very/long/path && swift build"}}"#, home: home)

        XCTAssertEqual(toolJSON(in: home, sessionId: sid)["summary"] as? String, "swift build")
    }

    /// The shape that slipped through the first implementation, caught by
    /// running it against a live session: an assignment as its own
    /// statement, `VAR=value && command`. Stripping the assignment leaves
    /// a dangling `&&`, so the row read `Bash · && cat ~/.clyde/state/…`.
    func testBashSummaryDropsDanglingAndAfterAssignment() throws {
        let home = tempHome()
        let sid = "bash-0007"

        try runHook(payload: #"{"hook_event_name":"PreToolUse","session_id":"\#(sid)","cwd":"/repo","tool_name":"Bash","tool_use_id":"toolu_b7","tool_input":{"command":"SP=/private/tmp/scratch && cat state.json"}}"#, home: home)

        XCTAssertEqual(toolJSON(in: home, sessionId: sid)["summary"] as? String, "cat state.json")
    }

    /// Same shape with a semicolon separator.
    func testBashSummaryDropsDanglingSemicolonAfterAssignment() throws {
        let home = tempHome()
        let sid = "bash-0008"

        try runHook(payload: #"{"hook_event_name":"PreToolUse","session_id":"\#(sid)","cwd":"/repo","tool_name":"Bash","tool_use_id":"toolu_b8","tool_input":{"command":"FOO=1 ; make build"}}"#, home: home)

        XCTAssertEqual(toolJSON(in: home, sessionId: sid)["summary"] as? String, "make build")
    }

    /// An `=` further along the line is not an assignment. Stripping on
    /// that would silently eat the actual command.
    func testBashSummaryKeepsEqualsSignInsideArguments() throws {
        let home = tempHome()
        let sid = "bash-0004"

        try runHook(payload: #"{"hook_event_name":"PreToolUse","session_id":"\#(sid)","cwd":"/repo","tool_name":"Bash","tool_use_id":"toolu_b4","tool_input":{"command":"git log --format=short"}}"#, home: home)

        XCTAssertEqual(toolJSON(in: home, sessionId: sid)["summary"] as? String, "git log --format=short")
    }

    /// A quoted value may contain spaces, so the naive "cut at the first
    /// space" rule would slice it in half. Leave those alone rather than
    /// produce a summary that is actively wrong.
    func testBashSummaryLeavesQuotedAssignmentAlone() throws {
        let home = tempHome()
        let sid = "bash-0005"

        try runHook(payload: #"{"hook_event_name":"PreToolUse","session_id":"\#(sid)","cwd":"/repo","tool_name":"Bash","tool_use_id":"toolu_b5","tool_input":{"command":"MSG=\"a b\" echo hi"}}"#, home: home)

        XCTAssertEqual(toolJSON(in: home, sessionId: sid)["summary"] as? String, "MSG=\"a b\" echo hi")
    }

    /// A command that is nothing but assignments still has to say
    /// something rather than collapse to an empty summary.
    func testBashSummaryOfBareAssignmentIsKept() throws {
        let home = tempHome()
        let sid = "bash-0006"

        try runHook(payload: #"{"hook_event_name":"PreToolUse","session_id":"\#(sid)","cwd":"/repo","tool_name":"Bash","tool_use_id":"toolu_b6","tool_input":{"command":"FOO=bar"}}"#, home: home)

        XCTAssertEqual(toolJSON(in: home, sessionId: sid)["summary"] as? String, "FOO=bar")
    }

    // MARK: - Per-event regression coverage
    //
    // Twelve of the hook's twenty-three handled events had no test at
    // all: the suite grew around whatever was being debugged that week,
    // which left the quiet, load-bearing events — session lifecycle,
    // attention, plan progress — as the least-covered code in the
    // pipeline. Each case below pins one event's state-file contract,
    // the thing ProcessMonitor reads on the other side.

    /// Convenience for the `~/.clyde/state/<sid>-<suffix>` path.
    private func stateFile(in home: URL, sessionId: String, suffix: String) -> URL {
        home.appendingPathComponent(".clyde/state/\(sessionId)-\(suffix)")
    }

    private func json(at url: URL) throws -> [String: Any] {
        let data = try XCTUnwrap(try? Data(contentsOf: url), "expected a file at \(url.lastPathComponent)")
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testSessionStartWritesInfoWithCwdAndSource() throws {
        let home = tempHome()
        let sid = "ev-0001"

        try runHook(payload: #"{"hook_event_name":"SessionStart","session_id":"\#(sid)","cwd":"/repo","source":"startup"}"#, home: home)

        let info = try json(at: stateFile(in: home, sessionId: sid, suffix: "info"))
        XCTAssertEqual(info["cwd"] as? String, "/repo")
        XCTAssertEqual(info["source"] as? String, "startup")
    }

    /// `source` is what tells ActivityLog an auto-compact restart apart
    /// from a fresh session, so it has to survive verbatim.
    func testSessionStartRecordsCompactSource() throws {
        let home = tempHome()
        let sid = "ev-0002"

        try runHook(payload: #"{"hook_event_name":"SessionStart","session_id":"\#(sid)","cwd":"/repo","source":"compact"}"#, home: home)

        let info = try json(at: stateFile(in: home, sessionId: sid, suffix: "info"))
        XCTAssertEqual(info["source"] as? String, "compact")
    }

    func testCwdChangedRewritesInfoCwd() throws {
        let home = tempHome()
        let sid = "ev-0003"
        try runHook(payload: #"{"hook_event_name":"SessionStart","session_id":"\#(sid)","cwd":"/repo","source":"startup"}"#, home: home)

        try runHook(payload: #"{"hook_event_name":"CwdChanged","session_id":"\#(sid)","cwd":"/repo/sub"}"#, home: home)

        let info = try json(at: stateFile(in: home, sessionId: sid, suffix: "info"))
        XCTAssertEqual(info["cwd"] as? String, "/repo/sub")
    }

    /// This used to assert the opposite — that CwdChanged must never create
    /// an `-info` — back when `pgrep` could also surface a session and a
    /// stray marker risked resurrecting a dead one. Now that hook state is
    /// the ONLY way a session becomes visible, refusing to record a live
    /// session is the bigger failure: it would stay invisible until its
    /// next prompt. A dead PID is still pruned on the next poll.
    func testCwdChangedForAnUnseenSessionBackfillsInfo() throws {
        let home = tempHome()
        let sid = "ev-0004"

        try runHook(payload: #"{"hook_event_name":"CwdChanged","session_id":"\#(sid)","cwd":"/repo/sub"}"#, home: home)

        let info = try json(at: stateFile(in: home, sessionId: sid, suffix: "info"))
        XCTAssertEqual(info["cwd"] as? String, "/repo/sub")
    }

    /// SessionEnd is the one event that has to leave nothing behind —
    /// every marker the hook can write, plus both directories.
    func testSessionEndClearsEveryMarker() throws {
        let home = tempHome()
        let sid = "ev-0005"
        try runHook(payload: #"{"hook_event_name":"SessionStart","session_id":"\#(sid)","cwd":"/repo","source":"startup"}"#, home: home)
        try runHook(payload: #"{"hook_event_name":"UserPromptSubmit","session_id":"\#(sid)","cwd":"/repo"}"#, home: home)
        try runHook(payload: #"{"hook_event_name":"PreToolUse","session_id":"\#(sid)","cwd":"/repo","tool_name":"Read","tool_use_id":"toolu_e5","tool_input":{"file_path":"/repo/a.swift"}}"#, home: home)
        try runHook(payload: #"{"hook_event_name":"TaskCreated","session_id":"\#(sid)","cwd":"/repo"}"#, home: home)
        try runHook(payload: #"{"hook_event_name":"PermissionRequest","session_id":"\#(sid)","cwd":"/repo"}"#, home: home)
        try runHook(payload: #"{"hook_event_name":"StopFailure","session_id":"\#(sid)","cwd":"/repo","stop_reason":"rate_limit"}"#, home: home)
        try runHook(payload: #"{"hook_event_name":"UserPromptExpansion","session_id":"\#(sid)","cwd":"/repo","command_name":"loop"}"#, home: home)

        try runHook(payload: #"{"hook_event_name":"SessionEnd","session_id":"\#(sid)","cwd":"/repo"}"#, home: home)

        for suffix in ["info", "busy", "error", "tool", "plan", "lastmsg", "command", "worktree"] {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: stateFile(in: home, sessionId: sid, suffix: suffix).path),
                "-\(suffix) survived SessionEnd")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: agentsDir(in: home, sessionId: sid).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: toolsDir(in: home, sessionId: sid).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: eventFile(in: home, sessionId: sid).path))
    }

    func testPermissionRequestRaisesAttentionEvent() throws {
        let home = tempHome()
        let sid = "ev-0006"

        try runHook(payload: #"{"hook_event_name":"PermissionRequest","session_id":"\#(sid)","cwd":"/repo"}"#, home: home)

        let event = try json(at: eventFile(in: home, sessionId: sid))
        XCTAssertEqual(event["event"] as? String, "PermissionRequest")
    }

    func testPermissionDeniedClearsAttentionEvent() throws {
        let home = tempHome()
        let sid = "ev-0007"
        try runHook(payload: #"{"hook_event_name":"PermissionRequest","session_id":"\#(sid)","cwd":"/repo"}"#, home: home)
        XCTAssertTrue(FileManager.default.fileExists(atPath: eventFile(in: home, sessionId: sid).path), "precondition")

        try runHook(payload: #"{"hook_event_name":"PermissionDenied","session_id":"\#(sid)","cwd":"/repo"}"#, home: home)

        XCTAssertFalse(FileManager.default.fileExists(atPath: eventFile(in: home, sessionId: sid).path))
    }

    /// An MCP tool asking for input is the same class of signal as a
    /// permission gate — the session is blocked on the human either way.
    func testElicitationRaisesAttentionEvent() throws {
        let home = tempHome()
        let sid = "ev-0008"

        try runHook(payload: #"{"hook_event_name":"Elicitation","session_id":"\#(sid)","cwd":"/repo"}"#, home: home)

        let event = try json(at: eventFile(in: home, sessionId: sid))
        XCTAssertEqual(event["event"] as? String, "Elicitation")
    }

    func testElicitationResultClearsAttentionEvent() throws {
        let home = tempHome()
        let sid = "ev-0009"
        try runHook(payload: #"{"hook_event_name":"Elicitation","session_id":"\#(sid)","cwd":"/repo"}"#, home: home)

        try runHook(payload: #"{"hook_event_name":"ElicitationResult","session_id":"\#(sid)","cwd":"/repo"}"#, home: home)

        XCTAssertFalse(FileManager.default.fileExists(atPath: eventFile(in: home, sessionId: sid).path))
    }

    func testStopFailureRecordsStopReason() throws {
        let home = tempHome()
        let sid = "ev-0010"

        try runHook(payload: #"{"hook_event_name":"StopFailure","session_id":"\#(sid)","cwd":"/repo","stop_reason":"rate_limit"}"#, home: home)

        let error = try json(at: stateFile(in: home, sessionId: sid, suffix: "error"))
        XCTAssertEqual(error["reason"] as? String, "rate_limit")
    }

    /// No reason, nothing to tell the user — an empty error card is worse
    /// than none.
    func testStopFailureWithoutReasonWritesNothing() throws {
        let home = tempHome()
        let sid = "ev-0011"

        try runHook(payload: #"{"hook_event_name":"StopFailure","session_id":"\#(sid)","cwd":"/repo"}"#, home: home)

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: stateFile(in: home, sessionId: sid, suffix: "error").path))
    }

    func testTaskCreatedIncrementsTaskCountAndKeepsStartedAt() throws {
        let home = tempHome()
        let sid = "ev-0012"

        try runHook(payload: #"{"hook_event_name":"TaskCreated","session_id":"\#(sid)","cwd":"/repo"}"#, home: home)
        let first = try json(at: stateFile(in: home, sessionId: sid, suffix: "plan"))
        try runHook(payload: #"{"hook_event_name":"TaskCreated","session_id":"\#(sid)","cwd":"/repo"}"#, home: home)
        let second = try json(at: stateFile(in: home, sessionId: sid, suffix: "plan"))

        XCTAssertEqual(first["task_count"] as? Int, 1)
        XCTAssertEqual(second["task_count"] as? Int, 2)
        XCTAssertEqual(second["done_count"] as? Int, 0)
        XCTAssertEqual(second["started_at"] as? Int, first["started_at"] as? Int,
                       "started_at must survive later TaskCreated events")
    }

    func testTaskCompletedIncrementsDoneCountWithoutTouchingTaskCount() throws {
        let home = tempHome()
        let sid = "ev-0013"
        try runHook(payload: #"{"hook_event_name":"TaskCreated","session_id":"\#(sid)","cwd":"/repo"}"#, home: home)
        try runHook(payload: #"{"hook_event_name":"TaskCreated","session_id":"\#(sid)","cwd":"/repo"}"#, home: home)

        try runHook(payload: #"{"hook_event_name":"TaskCompleted","session_id":"\#(sid)","cwd":"/repo"}"#, home: home)

        let plan = try json(at: stateFile(in: home, sessionId: sid, suffix: "plan"))
        XCTAssertEqual(plan["task_count"] as? Int, 2)
        XCTAssertEqual(plan["done_count"] as? Int, 1)
    }

    /// A TaskCompleted with no plan on disk is a lost event, not a plan of
    /// one. Fabricating the file would render as "1/0" on the row.
    func testTaskCompletedWithoutPlanWritesNothing() throws {
        let home = tempHome()
        let sid = "ev-0014"

        try runHook(payload: #"{"hook_event_name":"TaskCompleted","session_id":"\#(sid)","cwd":"/repo"}"#, home: home)

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: stateFile(in: home, sessionId: sid, suffix: "plan").path))
    }

    /// Compaction says nothing about whether the session needs the human,
    /// so it must not raise an attention event or touch the busy/tool
    /// markers. It does prove the session is alive, so — unlike before the
    /// discovery rework — it is allowed to backfill `-info`.
    func testCompactionEventsRaiseNoAttentionAndTouchNoActivityMarkers() throws {
        let home = tempHome()
        let sid = "ev-0015"

        try runHook(payload: #"{"hook_event_name":"PreCompact","session_id":"\#(sid)","cwd":"/repo"}"#, home: home)
        try runHook(payload: #"{"hook_event_name":"PostCompact","session_id":"\#(sid)","cwd":"/repo"}"#, home: home)

        for suffix in ["busy", "tool", "plan", "error", "lastmsg", "command"] {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: stateFile(in: home, sessionId: sid, suffix: suffix).path),
                "compaction must not write -\(suffix)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: eventFile(in: home, sessionId: sid).path))
    }

    // MARK: - Tool duration in the spool

    /// `PostToolUse` is the only event that knows how long a call actually
    /// took — Claude Code reports `duration_ms` on it. Without that figure
    /// the review can only say how long a turn lasted, never how much of
    /// it was the model thinking versus the machine compiling.
    func testPostToolUseSpoolsItsDuration() throws {
        let home = tempHome()
        let sid = "dur-0001"

        try runHook(payload: #"{"hook_event_name":"PostToolUse","session_id":"\#(sid)","cwd":"/repo","tool_name":"Bash","tool_use_id":"toolu_d1","duration_ms":4200,"tool_input":{"command":"swift test"}}"#, home: home)

        let line = try XCTUnwrap(spoolLines(in: home).first)
        XCTAssertEqual(line["event"] as? String, "PostToolUse")
        XCTAssertEqual(line["dur"] as? Int, 4200)
    }

    /// Events without a duration must not grow a null field — the key set
    /// is asserted elsewhere and every extra key is one more thing that
    /// could carry something it should not.
    func testEventsWithoutADurationCarryNoDurationKey() throws {
        let home = tempHome()
        let sid = "dur-0002"

        try runHook(payload: #"{"hook_event_name":"UserPromptSubmit","session_id":"\#(sid)","cwd":"/repo"}"#, home: home)

        let line = try XCTUnwrap(spoolLines(in: home).first)
        XCTAssertNil(line["dur"])
    }

    // MARK: - Info backfill for sessions Clyde never saw start

    /// Discovery by process name is gone, so the hook is now the only way a
    /// session becomes visible. A session that predates Clyde's install
    /// never fired SessionStart, and waiting for the user's next prompt
    /// would hide a session that is actively working right now. Any event
    /// that proves the session is alive backfills `-info`.
    func testPreToolUseBackfillsInfoForAnUnseenSession() throws {
        let home = tempHome()
        let sid = "backfill-0001"

        try runHook(payload: #"{"hook_event_name":"PreToolUse","session_id":"\#(sid)","cwd":"/repo","tool_name":"Read","tool_use_id":"toolu_bf1","tool_input":{"file_path":"/repo/a.swift"}}"#, home: home)

        let info = try json(at: stateFile(in: home, sessionId: sid, suffix: "info"))
        XCTAssertEqual(info["cwd"] as? String, "/repo")
        XCTAssertEqual(info["session_id"] as? String, sid)
    }

    func testStopAlsoBackfillsInfoForAnUnseenSession() throws {
        let home = tempHome()
        let sid = "backfill-0002"

        try runHook(payload: #"{"hook_event_name":"Stop","session_id":"\#(sid)","cwd":"/repo","last_assistant_message":"done"}"#, home: home)

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: stateFile(in: home, sessionId: sid, suffix: "info").path))
    }

    /// The backfill must not resurrect a session that just ended. SessionEnd
    /// removes every marker; recreating -info from the same event would
    /// leave a row that never goes away.
    func testSessionEndDoesNotLeaveABackfilledInfoBehind() throws {
        let home = tempHome()
        let sid = "backfill-0003"
        try runHook(payload: #"{"hook_event_name":"UserPromptSubmit","session_id":"\#(sid)","cwd":"/repo"}"#, home: home)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: stateFile(in: home, sessionId: sid, suffix: "info").path), "precondition")

        try runHook(payload: #"{"hook_event_name":"SessionEnd","session_id":"\#(sid)","cwd":"/repo"}"#, home: home)

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: stateFile(in: home, sessionId: sid, suffix: "info").path))
    }

    /// An existing -info must be left alone: SessionStart records `source`,
    /// and a backfill overwriting it would erase the compact/resume
    /// distinction the activity timeline depends on.
    func testBackfillDoesNotOverwriteAnExistingInfo() throws {
        let home = tempHome()
        let sid = "backfill-0004"
        try runHook(payload: #"{"hook_event_name":"SessionStart","session_id":"\#(sid)","cwd":"/repo","source":"compact"}"#, home: home)

        try runHook(payload: #"{"hook_event_name":"PreToolUse","session_id":"\#(sid)","cwd":"/repo","tool_name":"Read","tool_use_id":"toolu_bf4","tool_input":{"file_path":"/repo/a.swift"}}"#, home: home)

        let info = try json(at: stateFile(in: home, sessionId: sid, suffix: "info"))
        XCTAssertEqual(info["source"] as? String, "compact")
    }

    // MARK: - Worktree marker

    /// Derived from the `cwd` that every event carries — NOT from
    /// `WorktreeCreate`. That event is a *delegating* hook: Claude Code
    /// hands worktree creation to whatever subscribes and demands the
    /// created path on stdout, so Clyde subscribing to it broke
    /// `EnterWorktree` outright (v32, fixed before release). Measured
    /// live: with the subscription
    /// gone, entering a worktree lands the session in
    /// `<repo>/.claude/worktrees/<name>` and every subsequent event
    /// carries that cwd.
    func testWorktreeMarkerDerivedFromSessionCwd() throws {
        let home = tempHome()
        let sid = "aaaabbbb-aaaa-bbbb-cccc-000000000001"
        let cwd = "/repo/.claude/worktrees/fix-race"

        try runHook(
            payload: #"{"hook_event_name":"UserPromptSubmit","session_id":"\#(sid)","cwd":"\#(cwd)"}"#,
            home: home)

        let url = home.appendingPathComponent(".clyde/state/\(sid)-worktree")
        let data = try XCTUnwrap(try? Data(contentsOf: url))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["name"] as? String, "fix-race")
        XCTAssertEqual(json["path"] as? String, cwd)
    }

    /// The marker is re-derived on every event, so leaving the worktree
    /// drops the badge without depending on `WorktreeRemove` firing.
    func testWorktreeMarkerClearedWhenSessionLeavesWorktree() throws {
        let home = tempHome()
        let sid = "aaaabbbb-aaaa-bbbb-cccc-000000000002"
        let url = home.appendingPathComponent(".clyde/state/\(sid)-worktree")

        try runHook(
            payload: #"{"hook_event_name":"PreToolUse","session_id":"\#(sid)","cwd":"/repo/.claude/worktrees/wt","tool_name":"Read","tool_use_id":"toolu_wt1"}"#,
            home: home)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "precondition")

        try runHook(
            payload: #"{"hook_event_name":"PreToolUse","session_id":"\#(sid)","cwd":"/repo","tool_name":"Read","tool_use_id":"toolu_wt2"}"#,
            home: home)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    /// An ordinary project cwd must not manufacture a badge.
    func testOrdinaryCwdWritesNoWorktreeMarker() throws {
        let home = tempHome()
        let sid = "aaaabbbb-aaaa-bbbb-cccc-000000000003"

        try runHook(
            payload: #"{"hook_event_name":"UserPromptSubmit","session_id":"\#(sid)","cwd":"/Users/dev/_Projects/clyde"}"#,
            home: home)

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: home.appendingPathComponent(".clyde/state/\(sid)-worktree").path))
    }

    // MARK: - Slash command badge

    /// Payload shape per the documented `UserPromptExpansion` fields —
    /// NOT confirmed against a live session, because the event only
    /// fires when a human types a slash command.
    func testUserPromptExpansionRecordsCommandName() throws {
        let home = tempHome()
        let sid = "99999999-aaaa-bbbb-cccc-000000000001"
        let payload = #"{"hook_event_name":"UserPromptExpansion","session_id":"\#(sid)","cwd":"/tmp","command_name":"code-review","command_input":"high"}"#

        try runHook(payload: payload, home: home)

        let url = home.appendingPathComponent(".clyde/state/\(sid)-command")
        let data = try XCTUnwrap(try? Data(contentsOf: url))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["command"] as? String, "code-review")
    }

    /// The command belongs to the turn — when the turn ends, so does it.
    func testStopClearsCommandBadge() throws {
        let home = tempHome()
        let sid = "99999999-aaaa-bbbb-cccc-000000000002"
        let url = home.appendingPathComponent(".clyde/state/\(sid)-command")

        try runHook(payload: #"{"hook_event_name":"UserPromptExpansion","session_id":"\#(sid)","cwd":"/tmp","command_name":"loop"}"#, home: home)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "precondition")

        try runHook(payload: #"{"hook_event_name":"Stop","session_id":"\#(sid)","cwd":"/tmp"}"#, home: home)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    /// A malformed expansion with no name must not leave an empty badge.
    func testUserPromptExpansionWithoutNameWritesNothing() throws {
        let home = tempHome()
        let sid = "99999999-aaaa-bbbb-cccc-000000000003"
        try runHook(payload: #"{"hook_event_name":"UserPromptExpansion","session_id":"\#(sid)","cwd":"/tmp"}"#, home: home)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: home.appendingPathComponent(".clyde/state/\(sid)-command").path))
    }

    // MARK: - Parallel tool calls

    /// The `-tool` marker was a single file, so a batch of parallel
    /// calls overwrote each other and the row showed whichever
    /// PreToolUse happened to land last. One slot per tool_use_id, the
    /// same shape `-agents/` already uses.
    func testParallelToolCallsEachGetTheirOwnSlot() throws {
        let home = tempHome()
        let sid = "88888888-aaaa-bbbb-cccc-000000000001"

        try runHook(payload: preToolUse(sid: sid, toolUseID: "t_a", name: "Bash", command: "probe-A"), home: home)
        try runHook(payload: preToolUse(sid: sid, toolUseID: "t_b", name: "Bash", command: "probe-B"), home: home)
        try runHook(payload: preToolUse(sid: sid, toolUseID: "t_c", name: "Bash", command: "probe-C"), home: home)

        XCTAssertEqual(toolFiles(in: home, sessionId: sid), ["t_a.json", "t_b.json", "t_c.json"])
    }

    /// One call finishing must not blank the row while its siblings are
    /// still running.
    func testPostToolUseRemovesOnlyItsOwnSlot() throws {
        let home = tempHome()
        let sid = "88888888-aaaa-bbbb-cccc-000000000002"

        try runHook(payload: preToolUse(sid: sid, toolUseID: "t_a", name: "Bash", command: "probe-A"), home: home)
        try runHook(payload: preToolUse(sid: sid, toolUseID: "t_b", name: "Bash", command: "probe-B"), home: home)
        try runHook(payload: postToolUse(sid: sid, toolUseID: "t_a", name: "Bash"), home: home)

        XCTAssertEqual(
            toolFiles(in: home, sessionId: sid), ["t_b.json"],
            "the sibling call is still in flight and must stay on the row"
        )
    }

    /// Safety net. Real payload shape, captured from a live session:
    /// `tool_calls` is a list of {tool_name, tool_use_id, tool_input,
    /// tool_response} — and there is no `batch_id`, despite the docs.
    func testPostToolBatchSweepsEveryCallInTheBatch() throws {
        let home = tempHome()
        let sid = "88888888-aaaa-bbbb-cccc-000000000003"

        try runHook(payload: preToolUse(sid: sid, toolUseID: "t_a", name: "Bash", command: "probe-A"), home: home)
        try runHook(payload: preToolUse(sid: sid, toolUseID: "t_b", name: "Bash", command: "probe-B"), home: home)
        XCTAssertEqual(toolFiles(in: home, sessionId: sid).count, 2, "precondition")

        let batch = #"{"hook_event_name":"PostToolBatch","session_id":"\#(sid)","cwd":"/tmp","tool_calls":[{"tool_name":"Bash","tool_use_id":"t_a","tool_input":{"command":"probe-A"},"tool_response":"ok"},{"tool_name":"Bash","tool_use_id":"t_b","tool_input":{"command":"probe-B"},"tool_response":"ok"}]}"#
        try runHook(payload: batch, home: home)

        XCTAssertEqual(toolFiles(in: home, sessionId: sid), [], "PostToolBatch must clear the whole batch")
    }

    /// The turn is over — nothing can still be in flight.
    func testStopClearsAllToolSlots() throws {
        let home = tempHome()
        let sid = "88888888-aaaa-bbbb-cccc-000000000004"

        try runHook(payload: preToolUse(sid: sid, toolUseID: "t_a", name: "Bash", command: "probe-A"), home: home)
        try runHook(payload: #"{"hook_event_name":"Stop","session_id":"\#(sid)","cwd":"/tmp"}"#, home: home)

        XCTAssertEqual(toolFiles(in: home, sessionId: sid), [])
    }

    // MARK: - Last assistant message preview

    /// `Stop` has always carried `last_assistant_message` and the hook
    /// always threw it away. It is the cheapest possible "what did it
    /// actually say" affordance for a session sitting idle.
    func testStopRecordsLastAssistantMessage() throws {
        let home = tempHome()
        let sid = "77777777-aaaa-bbbb-cccc-000000000001"
        let payload = #"{"hook_event_name":"Stop","session_id":"\#(sid)","cwd":"/tmp","last_assistant_message":"All 158 tests pass."}"#

        try runHook(payload: payload, home: home)

        XCTAssertEqual(
            lastMessageJSON(in: home, sessionId: sid)["message"] as? String,
            "All 158 tests pass."
        )
    }

    /// The row shows one line, and the file is written to disk — both
    /// argue for keeping only a short prefix rather than whole replies.
    func testLastAssistantMessageIsCollapsedAndTruncated() throws {
        let home = tempHome()
        let sid = "77777777-aaaa-bbbb-cccc-000000000002"
        let long = String(repeating: "x", count: 200)
        let payload = #"{"hook_event_name":"Stop","session_id":"\#(sid)","cwd":"/tmp","last_assistant_message":"first line\nsecond line \#(long)"}"#

        try runHook(payload: payload, home: home)

        let msg = try XCTUnwrap(lastMessageJSON(in: home, sessionId: sid)["message"] as? String)
        XCTAssertFalse(msg.contains("\n"), "newlines must be collapsed — the row renders one line")
        XCTAssertLessThanOrEqual(msg.count, 81, "must be truncated, got \(msg.count) chars")
        XCTAssertTrue(msg.hasPrefix("first line second line"), "prefix must be preserved, got \(msg)")
    }

    /// A reply preview from the previous turn must not sit under a
    /// session that is busy again — the moment the user submits, it is
    /// stale.
    func testUserPromptSubmitClearsLastAssistantMessage() throws {
        let home = tempHome()
        let sid = "77777777-aaaa-bbbb-cccc-000000000003"

        try runHook(payload: #"{"hook_event_name":"Stop","session_id":"\#(sid)","cwd":"/tmp","last_assistant_message":"stale reply"}"#, home: home)
        XCTAssertFalse(lastMessageJSON(in: home, sessionId: sid).isEmpty, "precondition: preview recorded")

        try runHook(payload: #"{"hook_event_name":"UserPromptSubmit","session_id":"\#(sid)","cwd":"/tmp"}"#, home: home)

        XCTAssertTrue(
            lastMessageJSON(in: home, sessionId: sid).isEmpty,
            "a new prompt makes the previous reply preview stale"
        )
    }

    /// A Stop with no message (or an empty one) must not leave an empty
    /// row artefact behind.
    func testStopWithoutMessageWritesNoPreview() throws {
        let home = tempHome()
        let sid = "77777777-aaaa-bbbb-cccc-000000000004"

        try runHook(payload: #"{"hook_event_name":"Stop","session_id":"\#(sid)","cwd":"/tmp"}"#, home: home)

        XCTAssertTrue(lastMessageJSON(in: home, sessionId: sid).isEmpty)
    }

    // MARK: - Tool summary whitelist

    /// `Skill`, `Workflow` and `Artifact` all fell through to the
    /// empty-summary branch, so the row rendered a bare tool name while
    /// the interesting part — which skill, which workflow, which page —
    /// sat unused in tool_input.
    func testSkillToolSummaryIsTheSkillName() throws {
        let home = tempHome()
        let sid = "66666666-aaaa-bbbb-cccc-000000000001"
        let payload = #"{"hook_event_name":"PreToolUse","session_id":"\#(sid)","cwd":"/tmp","tool_name":"Skill","tool_use_id":"t1","tool_input":{"skill":"superpowers:brainstorming","args":"something"}}"#

        try runHook(payload: payload, home: home)

        let json = toolJSON(in: home, sessionId: sid)
        XCTAssertEqual(json["tool_name"] as? String, "Skill")
        XCTAssertEqual(json["summary"] as? String, "superpowers:brainstorming")
    }

    func testWorkflowToolSummaryIsTheWorkflowName() throws {
        let home = tempHome()
        let sid = "66666666-aaaa-bbbb-cccc-000000000002"
        let payload = #"{"hook_event_name":"PreToolUse","session_id":"\#(sid)","cwd":"/tmp","tool_name":"Workflow","tool_use_id":"t2","tool_input":{"name":"review-changes"}}"#

        try runHook(payload: payload, home: home)

        XCTAssertEqual(toolJSON(in: home, sessionId: sid)["summary"] as? String, "review-changes")
    }

    /// A Workflow invoked with an inline script has no name — fall back
    /// to the script file's basename rather than rendering nothing.
    func testWorkflowToolSummaryFallsBackToScriptBasename() throws {
        let home = tempHome()
        let sid = "66666666-aaaa-bbbb-cccc-000000000003"
        let payload = #"{"hook_event_name":"PreToolUse","session_id":"\#(sid)","cwd":"/tmp","tool_name":"Workflow","tool_use_id":"t3","tool_input":{"scriptPath":"/tmp/wf/find-flaky-tests.js"}}"#

        try runHook(payload: payload, home: home)

        XCTAssertEqual(toolJSON(in: home, sessionId: sid)["summary"] as? String, "find-flaky-tests.js")
    }

    func testArtifactToolSummaryIsTheTitle() throws {
        let home = tempHome()
        let sid = "66666666-aaaa-bbbb-cccc-000000000004"
        let payload = #"{"hook_event_name":"PreToolUse","session_id":"\#(sid)","cwd":"/tmp","tool_name":"Artifact","tool_use_id":"t4","tool_input":{"file_path":"/tmp/report.html","title":"Quarterly Report"}}"#

        try runHook(payload: payload, home: home)

        XCTAssertEqual(toolJSON(in: home, sessionId: sid)["summary"] as? String, "Quarterly Report")
    }

    /// Most Artifact calls carry no title — the file being published is
    /// the next most useful identifier.
    func testArtifactToolSummaryFallsBackToFileBasename() throws {
        let home = tempHome()
        let sid = "66666666-aaaa-bbbb-cccc-000000000005"
        let payload = #"{"hook_event_name":"PreToolUse","session_id":"\#(sid)","cwd":"/tmp","tool_name":"Artifact","tool_use_id":"t5","tool_input":{"file_path":"/tmp/dashboard.html"}}"#

        try runHook(payload: payload, home: home)

        XCTAssertEqual(toolJSON(in: home, sessionId: sid)["summary"] as? String, "dashboard.html")
    }

    // MARK: - History spool

    private func spoolLines(in home: URL) -> [[String: Any]] {
        let url = home.appendingPathComponent(".clyde/history/spool.jsonl")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap {
            guard let data = $0.data(using: .utf8) else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
    }

    /// Nothing drains the spool but a running Clyde. Uninstall the app,
    /// or simply never launch it again, and the hook keeps appending a
    /// line per event forever — a file that grows without bound in a
    /// directory the user has no reason to look in. Past the cap the hook
    /// stops appending rather than deleting: when Clyde comes back it
    /// ingests everything that was already recorded, and the events lost
    /// in between are the ones nobody could have been looking at.
    func testSpoolStopsGrowingPastItsCap() throws {
        let home = tempHome()
        let spool = home.appendingPathComponent(".clyde/history/spool.jsonl")
        try FileManager.default.createDirectory(at: spool.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let oversized = String(repeating: "x", count: 11 * 1024 * 1024) + "\n"
        try oversized.write(to: spool, atomically: true, encoding: .utf8)
        let sizeBefore = try FileManager.default
            .attributesOfItem(atPath: spool.path)[.size] as? Int

        try runHook(payload: #"{"hook_event_name":"PreToolUse","session_id":"capped","cwd":"/repo","tool_name":"Bash","tool_input":{"command":"swift test"}}"#, home: home)

        let sizeAfter = try FileManager.default
            .attributesOfItem(atPath: spool.path)[.size] as? Int
        XCTAssertEqual(sizeAfter, sizeBefore, "an oversized spool must neither grow nor be truncated")
    }

    /// The cap must not cost the common case anything: a spool of ordinary
    /// size keeps taking every line.
    func testSpoolBelowTheCapStillRecords() throws {
        let home = tempHome()
        let spool = home.appendingPathComponent(".clyde/history/spool.jsonl")
        try FileManager.default.createDirectory(at: spool.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try (String(repeating: "x", count: 1024) + "\n")
            .write(to: spool, atomically: true, encoding: .utf8)

        try runHook(payload: #"{"hook_event_name":"PreToolUse","session_id":"under","cwd":"/repo","tool_name":"Bash","tool_input":{"command":"swift test"}}"#, home: home)

        XCTAssertEqual(spoolLines(in: home).count, 1, "the JSON line was appended after the padding")
    }

    func testSpoolRecordsAToolCallWithItsSummary() throws {
        let home = tempHome()
        let sid = "spool-0001"

        try runHook(payload: #"{"hook_event_name":"PreToolUse","session_id":"\#(sid)","cwd":"/repo","tool_name":"Bash","tool_use_id":"toolu_s1","tool_input":{"command":"swift test"}}"#, home: home)

        let lines = spoolLines(in: home)
        XCTAssertEqual(lines.count, 1)
        let first = try XCTUnwrap(lines.first)
        XCTAssertEqual(first["event"] as? String, "PreToolUse")
        XCTAssertEqual(first["session_id"] as? String, sid)
        XCTAssertEqual(first["cwd"] as? String, "/repo")
        XCTAssertEqual(first["tool"] as? String, "Bash")
        XCTAssertEqual(first["summary"] as? String, "swift test")
        XCTAssertNotNil(first["ts"] as? Int)
    }

    /// Turn boundaries are what every duration in the review is computed
    /// from, so they have to land in the spool even though they write no
    /// tool summary.
    func testSpoolRecordsTurnBoundaries() throws {
        let home = tempHome()
        let sid = "spool-0002"

        try runHook(payload: #"{"hook_event_name":"UserPromptSubmit","session_id":"\#(sid)","cwd":"/repo"}"#, home: home)
        try runHook(payload: #"{"hook_event_name":"Stop","session_id":"\#(sid)","cwd":"/repo","last_assistant_message":"done"}"#, home: home)

        XCTAssertEqual(spoolLines(in: home).map { $0["event"] as? String },
                       ["UserPromptSubmit", "Stop"])
    }

    /// The spool must never carry message bodies — that decision was made
    /// in v0.7.0 and the store does not get to reopen it.
    func testSpoolNeverCarriesTheAssistantMessage() throws {
        let home = tempHome()
        let sid = "spool-0003"

        try runHook(payload: #"{"hook_event_name":"Stop","session_id":"\#(sid)","cwd":"/repo","last_assistant_message":"secret sentence"}"#, home: home)

        let text = try String(contentsOf: home.appendingPathComponent(".clyde/history/spool.jsonl"), encoding: .utf8)
        XCTAssertFalse(text.contains("secret sentence"))
    }

    /// The spool is additive: every existing marker keeps working.
    func testSpoolWritingDoesNotDisturbStateMarkers() throws {
        let home = tempHome()
        let sid = "spool-0004"

        try runHook(payload: #"{"hook_event_name":"UserPromptSubmit","session_id":"\#(sid)","cwd":"/repo"}"#, home: home)

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: home.appendingPathComponent(".clyde/state/\(sid)-busy").path))
    }

    /// T-A: the branch's headline privacy claim — "only tool names and
    /// summaries, never conversation content" — is only real if every
    /// spool line's keys are a subset of this allowlist. A test that
    /// greps for one literal string (as `testSpoolNeverCarriesTheAssistantMessage`
    /// does above) would not catch someone adding a brand-new field
    /// (e.g. a `"prompt"` key) tomorrow; this one would, for any event
    /// shape. Exercises a turn boundary, an Agent dispatch (which
    /// carries both `tool` and `summary`), and a Stop that carries
    /// `last_assistant_message` in the payload — the field this whole
    /// allowlist exists to keep out.
    func testEverySpoolLineKeySetIsWithinTheAllowlist() throws {
        let home = tempHome()
        let sid = "spool-keys"
        let allowedKeys: Set<String> = ["ts", "event", "session_id", "cwd", "tool", "summary", "dur"]

        try runHook(payload: #"{"hook_event_name":"UserPromptSubmit","session_id":"\#(sid)","cwd":"/repo"}"#, home: home)
        try runHook(payload: preToolUseAgent(
            sid: sid, toolUseID: "toolu_keys1", type: "general-purpose",
            description: "explore the repo"), home: home)
        try runHook(payload: #"{"hook_event_name":"Stop","session_id":"\#(sid)","cwd":"/repo","last_assistant_message":"the secret reply text"}"#, home: home)

        let lines = spoolLines(in: home)
        XCTAssertEqual(lines.count, 3)
        for line in lines {
            let keys = Set(line.keys)
            XCTAssertTrue(keys.isSubset(of: allowedKeys),
                          "unexpected spool key(s): \(keys.subtracting(allowedKeys))")
        }
    }

    /// T-B: the only test that drives the hook and the store together.
    /// Every other test on either side of this boundary assumes its own
    /// idea of the spool line format — this one runs the real script,
    /// hands its real output straight to `HistoryStore.ingestPending()`,
    /// and checks the ingested data through `HistoryStats`, the same
    /// read path the review window uses.
    func testRealHookOutputIngestsEndToEndIntoTheStore() throws {
        let home = tempHome()
        let sid = "spool-e2e"

        try runHook(payload: #"{"hook_event_name":"UserPromptSubmit","session_id":"\#(sid)","cwd":"/repo"}"#, home: home)
        try runHook(payload: #"{"hook_event_name":"PreToolUse","session_id":"\#(sid)","cwd":"/repo","tool_name":"Bash","tool_use_id":"toolu_e1","tool_input":{"command":"swift test"}}"#, home: home)
        try runHook(payload: #"{"hook_event_name":"Stop","session_id":"\#(sid)","cwd":"/repo","last_assistant_message":"done"}"#, home: home)

        let store = try HistoryStore(directory: home.appendingPathComponent(".clyde/history"))
        let ingested = store.ingestPending()

        XCTAssertEqual(ingested, 3)
        XCTAssertEqual(store.eventCount(), 3)

        let stats = HistoryStats(store: store)
        let rows = stats.projects(from: Date(timeIntervalSince1970: 0), to: Date().addingTimeInterval(60))
        let repoRow = try XCTUnwrap(rows.first { $0.project == "/repo" })
        XCTAssertEqual(repoRow.turns, 1)
    }

    /// T-D (B2): the spool accumulates Bash commands, Grep patterns and
    /// search queries, so it must get the same 0600 posture as the
    /// database and state markers rather than the shell's default 0644.
    func testSpoolFileIsCreated0600() throws {
        let home = tempHome()
        let sid = "spool-perm"

        try runHook(payload: #"{"hook_event_name":"UserPromptSubmit","session_id":"\#(sid)","cwd":"/repo"}"#, home: home)

        let spoolURL = home.appendingPathComponent(".clyde/history/spool.jsonl")
        let attrs = try FileManager.default.attributesOfItem(atPath: spoolURL.path)
        let mode = try XCTUnwrap(attrs[.posixPermissions] as? NSNumber).uint16Value
        XCTAssertEqual(mode, 0o600, "spool.jsonl must be 0600, was \(String(mode, radix: 8))")
    }

    // MARK: - PermissionRequest: what is being asked

    /// Answering a permission request from the panel needs the panel to
    /// know what the question is. The event carries `tool_name` and the
    /// full `tool_input`; the hook used to throw both away and record
    /// only that *something* wanted attention.
    func testPermissionRequestRecordsTheToolAndItsInput() throws {
        let home = tempHome()

        try runHook(payload: permissionRequest(sid: "sess-1"), home: home)

        let files = requestFiles(in: home)
        XCTAssertEqual(files.count, 1, "one request file per request")
        let name = try XCTUnwrap(files.first)
        let body = try JSONSerialization.jsonObject(
            with: Data(contentsOf: permissionsDir(in: home).appendingPathComponent(name))
        ) as? [String: Any]
        XCTAssertEqual(body?["tool_name"] as? String, "Bash")
        XCTAssertEqual((body?["tool_input"] as? [String: Any])?["command"] as? String, "rm -rf build")
        XCTAssertEqual(body?["session_id"] as? String, "sess-1")
        XCTAssertEqual(body?["cwd"] as? String, "/repo")
        XCTAssertNotNil(body?["request_id"], "the payload carries no tool_use_id, so the hook mints one")
        XCTAssertNotNil(body?["expires_at"])
    }

    /// The attention badge is what the panel shows today and must keep
    /// working exactly as before.
    func testPermissionRequestStillRaisesTheAttentionEvent() throws {
        let home = tempHome()

        try runHook(payload: permissionRequest(sid: "sess-2"), home: home)

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: eventsDir(in: home).appendingPathComponent("sess-2.json").path))
    }

    /// Two requests in flight are two questions, not one overwriting
    /// the other — parallel sessions ask at the same time.
    func testTwoRequestsGetTwoFiles() throws {
        let home = tempHome()

        try runHook(payload: permissionRequest(sid: "sess-a", command: "ls"), home: home)
        try runHook(payload: permissionRequest(sid: "sess-b", command: "pwd"), home: home)

        XCTAssertEqual(requestFiles(in: home).count, 2)
    }

    /// A tool with no input at all must not produce a file the reader
    /// cannot parse.
    func testARequestWithoutToolInputIsStillValidJSON() throws {
        let home = tempHome()
        let payload = #"{"hook_event_name":"PermissionRequest","session_id":"s","cwd":"/repo","tool_name":"Read"}"#

        try runHook(payload: payload, home: home)

        let files = requestFiles(in: home)
        XCTAssertEqual(files.count, 1)
        let name = try XCTUnwrap(files.first)
        XCTAssertNoThrow(try JSONSerialization.jsonObject(
            with: Data(contentsOf: permissionsDir(in: home).appendingPathComponent(name))))
    }

}
