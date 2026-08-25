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
}
