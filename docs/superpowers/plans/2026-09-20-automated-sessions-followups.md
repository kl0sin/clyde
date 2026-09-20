# Automated Sessions Follow-ups Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The Activity trail ignores the "Show automated sessions" toggle, the hook's cleat branch is tested, and the review window stops counting automated sessions as work.

**Architecture:** `ActivityLog` snapshots every tracked live session and emits only for published ones. The hook gains a `CLYDE_HOOK_CLEAT` test seam and writes `"headless": true` into spool lines. `HistoryStore` records automated session ids in a table and exposes a `human_events` view that `HistoryStats` reads.

**Tech Stack:** Swift 5.9, SQLite (C API), XCTest, bash.

**Spec:** `docs/superpowers/specs/2026-09-20-automated-sessions-followups-design.md`

## Global Constraints

- Prose markdown not hard-wrapped. No Claude attribution. Conventional commits; stage specific paths. `swift test` before every Swift commit (677 pass at base).
- Hook: bump `# clyde-hook-version:` to 47 and `HookInstaller.currentScriptVersion` to 47 in the same commit; never `set -e`; always `exit 0`; seams (`CLYDE_HOOK_STDIN`, `CLYDE_HOOK_CLEAT`) only act when set.
- `HistoryStore.eventCount()`, `oldestEventDate()`, `clear()` keep operating on `events`; only `HistoryStats` switches to `human_events`.
- Tests never touch the real `~/.clyde`/`~/.claude`.

---

### Task 1: `ActivityLog` ignores the toggle

**Files:**
- Modify: `Clyde/Services/ActivityLog.swift`
- Test: `ClydeTests/ActivityLogTests.swift`

**Interfaces:**
- Consumes: `ProcessMonitor.trackedSessions` (internal, all sessions), `ProcessMonitor.sessions` (published), `ProcessMonitor.init(…, showsAutomatedSessions:)`, `replaceTrackedSessions(_:)`.

- [ ] **Step 1: Failing tests** (append to `ActivityLogTests`; `writeInfo` exists — add a `headless: Bool = false` parameter that appends `,"headless":true` to the JSON when set)

```swift
    // MARK: - Automated sessions

    private func makeMonitor(showsAutomated: @escaping () -> Bool) -> ProcessMonitor {
        ProcessMonitor(shell: emptyShell(), pollingInterval: 1, stateDir: stateDir,
                       isLiveClaudeProcessCheck: { _ in true },
                       showsAutomatedSessions: showsAutomated)
    }

    func testHiddenSessionNeverReachesTheTrail() async throws {
        let monitor = makeMonitor(showsAutomated: { false })
        let log = ActivityLog(processMonitor: monitor, attentionMonitor: AttentionMonitor(eventsDir: eventsDir))
        let pid = writeInfo(sessionId: "bot", headless: true)
        await monitor.poll()
        writeBusy(sessionId: "bot", pid: pid)
        await monitor.poll()
        removeBusy(sessionId: "bot")
        await monitor.poll()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(log.events, [])
    }

    func testTogglingTheSettingIsNotAStartOrAnEnd() async throws {
        var show = false
        let monitor = makeMonitor(showsAutomated: { show })
        let log = ActivityLog(processMonitor: monitor, attentionMonitor: AttentionMonitor(eventsDir: eventsDir))
        writeInfo(sessionId: "bot", headless: true)
        await monitor.poll()
        try await Task.sleep(nanoseconds: 100_000_000)

        show = true
        monitor.republish()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(log.events, [], "showing a session that was already running is not a start")

        show = false
        monitor.republish()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(log.events, [], "hiding a session that is still running is not an end")
    }

    func testShownAutomatedSessionBehavesLikeAnyOther() async throws {
        let monitor = makeMonitor(showsAutomated: { true })
        let log = ActivityLog(processMonitor: monitor, attentionMonitor: AttentionMonitor(eventsDir: eventsDir))
        writeInfo(sessionId: "bot", headless: true)
        await monitor.poll()
        try await waitForEvents(log, count: 1)
        XCTAssertEqual(log.events.first?.kind, .sessionStarted)

        try FileManager.default.removeItem(at: stateDir.appendingPathComponent("bot-info"))
        await monitor.poll()
        try await waitForEvents(log, count: 2)
        XCTAssertEqual(log.events.first?.kind, .sessionEnded)
    }
```

- [ ] **Step 2: Run** `swift test --filter ActivityLogTests` — the toggle test fails with `sessionStarted`/`sessionEnded` events.

- [ ] **Step 3: Implement.** In `reconcile(sessions:)`:
  - Compute `let trackedLive = (processMonitor?.trackedSessions ?? []).filter { !$0.isGhost }` and `let trackedLivePIDs = Set(trackedLive.map(\.pid))`.
  - After the existing per-session loop over `live` (published), add a silent pass: for each `session in trackedLive where !livePIDs.contains(session.pid)`, write `snapshots[session.pid] = Snapshot(...)` with the same fields (no `append`). This seeds hidden sessions and keeps their snapshots current so a later reveal emits nothing spurious.
  - Change the "gone" set from `knownPIDs.subtracting(livePIDs)` to `knownPIDs.subtracting(trackedLivePIDs)`.
  - Extend the fingerprint's short-circuit condition from `snapshots.keys.allSatisfy(livePIDs.contains)` to `snapshots.keys.allSatisfy(trackedLivePIDs.contains)`, and include `trackedLivePIDs.count` in the hasher so a toggle (which changes `live` but not `trackedLive`) still passes through and re-seeds correctly.
  - Seeding in `init` iterates `processMonitor.trackedSessions` instead of `sessions`.
  Add a doc comment on `reconcile` explaining the tracked/published split in two sentences.

- [ ] **Step 4:** `swift test --filter ActivityLogTests`, then the full suite. Commit:
```bash
git add Clyde/Services/ActivityLog.swift ClydeTests/ActivityLogTests.swift
git commit -m "fix(activity): a toggle is not a session starting or ending

The trail diffed the published list, so showing or hiding automated sessions wrote started and ended rows for sessions that never stopped. It now remembers every tracked session and speaks only about the published ones."
```

---

### Task 2: The hook — cleat seam, spool flag, version 47

**Files:**
- Modify: `Clyde/Resources/clyde-hook.sh`, `Clyde/Services/HookInstaller.swift`
- Test: `ClydeTests/HookScriptTests.swift`

- [ ] **Step 1: Failing tests**

```swift
    func testCleatSessionIsNeverClassifiedByStdin() throws {
        let home = tempHome(), sid = UUID().uuidString
        try runHook(payload: sessionStart(sid: sid), home: home,
                    extraEnv: ["CLYDE_HOOK_CLEAT": "cleat-test-1", "CLAUDE_CODE_ENTRYPOINT": "cli", "CLYDE_HOOK_STDIN": "pipe"])
        let json = try infoJSON(sid: sid, home: home)
        XCTAssertNil(json["headless"])
        XCTAssertEqual(json["runtime"] as? String, "cleat")
        XCTAssertEqual(json["container"] as? String, "cleat-test-1")
    }

    func testCleatSessionWithSDKEntrypointIsHeadless() throws {
        let home = tempHome(), sid = UUID().uuidString
        try runHook(payload: sessionStart(sid: sid), home: home,
                    extraEnv: ["CLYDE_HOOK_CLEAT": "cleat-test-1", "CLAUDE_CODE_ENTRYPOINT": "sdk-ts"])
        XCTAssertEqual(try infoJSON(sid: sid, home: home)["headless"] as? Bool, true)
    }

    func testSpoolLineCarriesHeadless() throws {
        let home = tempHome(), sid = UUID().uuidString
        try runHook(payload: sessionStart(sid: sid), home: home,
                    extraEnv: ["CLAUDE_CODE_ENTRYPOINT": "cli", "CLYDE_HOOK_STDIN": "pipe"])
        let spool = try String(contentsOf: home.appendingPathComponent(".clyde/history/spool.jsonl"), encoding: .utf8)
        let line = try XCTUnwrap(spool.split(separator: "\n").first { $0.contains(sid) })
        XCTAssertTrue(line.contains(#""headless": true"#), String(line))
    }

    func testSpoolLineOmitsHeadlessForATerminalSession() throws {
        let home = tempHome(), sid = UUID().uuidString
        try runHook(payload: sessionStart(sid: sid), home: home,
                    extraEnv: ["CLAUDE_CODE_ENTRYPOINT": "cli", "CLYDE_HOOK_STDIN": "/dev/ttys004"])
        let spool = try String(contentsOf: home.appendingPathComponent(".clyde/history/spool.jsonl"), encoding: .utf8)
        XCTAssertFalse(spool.contains("headless"))
    }
```

- [ ] **Step 2:** `swift test --filter HookScriptTests` — the cleat tests fail on `runtime`/`headless`, the spool test on the missing field.

- [ ] **Step 3: Implement.** In the cleat entry block, replace `if detect_cleat_host_process; then` with a seam branch first:
```bash
if [ -n "${CLYDE_HOOK_CLEAT:-}" ]; then
    # Test seam. The real detection walks the parent chain for a cleat
    # process and asks Docker for the container; a test can stage
    # neither. The seam names the container and leaves PID resolution
    # to the ordinary walk, so the cleat-only branches run for real.
    CLEAT_RUNTIME="cleat"
    CLEAT_CNAME=$CLYDE_HOOK_CLEAT
    CLAUDE_PID=$(find_claude_pid || echo "")
elif detect_cleat_host_process; then
```
(keep the existing body and its `else`). Where `SPOOL_EXTRA` is assembled, add `[ -n "$HEADLESS" ] && SPOOL_EXTRA="$SPOOL_EXTRA, \"headless\": true"` with a comment that this rides on the same detection as `-info`, so it appears on the events that wrote `-info`. Bump the stamp and `currentScriptVersion` to 47; extend the header comment.

- [ ] **Step 4:** focused tests, full suite, commit:
```bash
git add Clyde/Resources/clyde-hook.sh Clyde/Services/HookInstaller.swift ClydeTests/HookScriptTests.swift
git commit -m "feat(hooks): the spool knows which sessions were automated, and the cleat branch is tested

History could not tell a test suite's sessions from the user's; the spool line now carries the same flag -info does. The cleat branch of the headless rule had no test because nothing could stage cleat — a seam names the container and lets the branch run for real."
```

---

### Task 3: History excludes automated sessions

**Files:**
- Modify: `Clyde/Models/HistoryEvent.swift` (`var headless: Bool = false`), `Clyde/Services/HistorySpool.swift` (parse `json["headless"] as? Bool ?? false`), `Clyde/Services/HistoryStore.swift`, `Clyde/Services/HistoryStats.swift`
- Test: `ClydeTests/HistoryStoreTests.swift`, `ClydeTests/HistoryStatsTests.swift`

- [ ] **Step 1: Failing tests**

`HistoryStoreTests`:
```swift
    func testParsesTheHeadlessFlag() {
        let e = HistorySpool.parse(line: #"{"ts": 1, "event": "SessionStart", "session_id": "b", "cwd": "/r", "headless": true}"#)
        XCTAssertEqual(e?.headless, true)
        XCTAssertEqual(HistorySpool.parse(line: spoolLine("Stop", ts: 2))?.headless, false)
    }

    func testIngestRecordsAutomatedSessions() throws {
        let dir = tempDir()
        writeSpool([#"{"ts": 1, "event": "SessionStart", "session_id": "b", "cwd": "/r", "headless": true}"#,
                    spoolLine("Stop", ts: 2)], in: dir)
        let store = try HistoryStore(directory: dir)
        XCTAssertEqual(store.ingestPending(), 2)
        XCTAssertEqual(store.automatedSessionCount(), 1)
        XCTAssertEqual(store.eventCount(), 2, "the store keeps every event; only the stats exclude")
    }

    func testOpeningAPreFlagDatabaseAddsTheTableAndView() throws {
        // Mirror testOpeningAPreDurationDatabaseMigratesIt: create a db with only the old schema, reopen, insert, query.
    }
```
`HistoryStatsTests` (add `headless: Bool = false` to the file's `event(...)` helper and pass it through):
```swift
    func testAutomatedSessionsAddNoWorkAndNoCount() throws {
        let store = try makeStore()
        try store.insert([
            event("SessionStart", at: 0, session: "bot", headless: true),
            event("UserPromptSubmit", at: 10, session: "bot", headless: true),
            event("Stop", at: 70, session: "bot", headless: true),
            event("UserPromptSubmit", at: 100, session: "me"),
            event("Stop", at: 130, session: "me"),
        ])
        let totals = HistoryStats(store: store).totals(from: wholeRange.from, to: wholeRange.to)
        XCTAssertEqual(totals.workingSeconds, 30)
        XCTAssertEqual(totals.turns, 1)
        XCTAssertEqual(totals.sessions, 1)
    }
```
Check how `HistoryStats` is constructed in this file and match it.

- [ ] **Step 2:** `swift test --filter "HistoryStoreTests|HistoryStatsTests"` — compile errors on `headless`/`automatedSessionCount`.

- [ ] **Step 3: Implement.**
  - `HistoryEvent`: `var headless: Bool = false` (last, defaulted, so existing initialisers compile).
  - `HistoryStore.init`: after the existing schema, `CREATE TABLE IF NOT EXISTS automated_sessions (session_id TEXT PRIMARY KEY); CREATE VIEW IF NOT EXISTS human_events AS SELECT * FROM events WHERE session_id NOT IN (SELECT session_id FROM automated_sessions);` — as separate `execInner` after the `ALTER` migration so old databases get both.
  - `insertWithinTransaction`: for each event with `headless == true`, also `INSERT OR IGNORE INTO automated_sessions (session_id) VALUES (?)` (a second prepared statement).
  - `func automatedSessionCount() -> Int` reading `SELECT COUNT(*) FROM automated_sessions` under the queue lock.
  - `clear()`: also `DELETE FROM automated_sessions`.
  - `HistoryStats`: every `FROM events` becomes `FROM human_events` (eleven sites; the window-function subqueries included).

- [ ] **Step 4:** focused, full suite, commit:
```bash
git add Clyde/Models/HistoryEvent.swift Clyde/Services/HistorySpool.swift Clyde/Services/HistoryStore.swift Clyde/Services/HistoryStats.swift ClydeTests/HistoryStoreTests.swift ClydeTests/HistoryStatsTests.swift
git commit -m "feat(history): the review counts the user's sessions, not the test suite's

Automated sessions are recorded like any other — the store is a record of what ran — but the review reads through a view that leaves them out, so working time, turns and project rows describe the user's own day."
```

---

### Task 4: Docs

**Files:** `CHANGELOG.md`, `ROADMAP.md`, `docs/hook-smoke-test.md`

- [ ] CHANGELOG `### Fixed` (Unreleased): `- Showing or hiding automated sessions no longer writes "session started" and "session ended" rows to the Activity trail for sessions that never stopped. The review window no longer counts automated sessions' turns and working time; Settings › History still reports every stored event.`
- [ ] ROADMAP: tick the three v0.10.0 lines (ActivityLog phantom events; review window counts automated; and the cleat-seam item if present — if the cleat item is only in the ledger, add it as a `[x]` line) with one-line summaries of what was done.
- [ ] `docs/hook-smoke-test.md` scenario 10: add two steps — flip the switch twice with the panel open, the Activity trail must not change; open the review window, today's numbers exclude the three headless sessions.
- [ ] Commit: `docs(sessions): the follow-ups are in — changelog, roadmap, smoke test`

---

## Self-review

Spec §1 → Task 1; §2 → Task 2 (seam + tests + version); §3 → Task 2 (spool flag) + Task 3 (store, view, stats); verification → each task's tests + Task 4's smoke-test steps. Names consistent: `trackedSessions`, `republish()`, `showsAutomatedSessions:`, `CLYDE_HOOK_CLEAT`, `HistoryEvent.headless`, `automated_sessions`, `human_events`, `automatedSessionCount()`.
