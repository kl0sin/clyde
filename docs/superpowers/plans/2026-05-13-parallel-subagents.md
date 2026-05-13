# Parallel Subagents Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the single `-subagent` marker file with a per-agent list, displayed as a two-lines-per-agent block under the session row with 3-visible / "+N more" expand affordance.

**Architecture:** Each `PreToolUse(Task)` writes `state/<sid>-agents/<tool_use_id>.json`; the matching `PostToolUse(Task)` removes it. `ProcessMonitor` scans the directory each reconcile and exposes `Session.activeSubagents` (sorted by `started_at`). `SessionRow` renders a left-bordered block for N≥2; for N≥4 the tail collapses into a tap-to-expand label whose open state lives on `AppViewModel`.

**Tech Stack:** Bash 3.2 (`clyde-hook.sh`), Swift 5.9 / SwiftUI on macOS 13+, XCTest (Swift Package Manager via `swift test`).

**Reference spec:** `docs/superpowers/specs/2026-05-13-parallel-subagents-design.md`.

---

## File map

- **Modify** `Clyde/Resources/clyde-hook.sh` — extract `tool_use_id`, write/remove `state/<sid>-agents/<id>.json` on `PreToolUse(Task)` / `PostToolUse(Task)` / `PostToolUseFailure(Task)`, clear directory on `SessionEnd`, defensive cleanup on `SubagentStop`, header comment + version bump to 20.
- **Modify** `Clyde/Services/HookInstaller.swift` — bump `currentScriptVersion` from 19 to 20.
- **Modify** `Clyde/Models/Session.swift` — add `ActiveSubagent` struct and `var activeSubagents: [ActiveSubagent]` field.
- **Modify** `Clyde/Services/ProcessMonitor.swift` — add `refreshHookAgents()` mirroring `refreshHookTools`, wire into `pollHookState` reconcile + apply path, extend `resetSessionState` to `rm -rf state/<sid>-agents`.
- **Modify** `Clyde/ViewModels/AppViewModel.swift` — add `expandedSubagentSessions: Set<UUID>` published state + `toggleSubagentExpansion(_:)` + auto-collapse logic.
- **Modify** `Clyde/Views/Components/SessionRow.swift` — render `<N> agents · <dur>` second line for N≥2; render a `SubagentList` view (new private struct in the same file) with two-lines-per-agent layout, 3-visible + expand label, reduce-motion-aware crossfade, accessibility labels.
- **Modify** `ClydeTests/ProcessMonitorTests.swift` — add tests for list growth/ordering, 30-min GC, backwards-compat with legacy `-subagent`, `resetSessionState` clearing the dir.
- **Modify** `docs/hook-smoke.md` — add parallel-Task scenario.
- **Modify** `ROADMAP.md` — add v0.3.x item (ticked when done).
- **Modify** `CHANGELOG.md` — add bullet under `## [Unreleased]`.

---

## Task 1: Hook — extract `tool_use_id` for Task payloads

**Files:**
- Modify: `Clyde/Resources/clyde-hook.sh`

- [ ] **Step 1: Add tool_use_id extraction next to TOOL_NAME**

Locate the block that sets `TOOL_NAME` (around line 237–240). Add a sibling extraction:

```bash
TOOL_NAME=""
TOOL_USE_ID=""
case "$HOOK_EVENT" in
    PreToolUse|PostToolUse|PostToolUseFailure)
        TOOL_NAME=$(extract_field tool_name)
        TOOL_USE_ID=$(extract_field tool_use_id)
        ;;
esac
```

(Replace the existing `case` block. `tool_use_id` ships on all three events in Claude Code's hook payload.)

- [ ] **Step 2: Verify the hook still parses a Bash PreToolUse payload**

Run from the repo root:

```bash
printf '%s' '{"hook_event_name":"PreToolUse","session_id":"s1","cwd":"/tmp","tool_name":"Bash","tool_use_id":"toolu_x","tool_input":{"command":"ls"}}' \
  | HOME=/tmp/clyde-smoke CLAUDE_PROJECT_DIR=/tmp bash Clyde/Resources/clyde-hook.sh
ls /tmp/clyde-smoke/.clyde/state/ 2>/dev/null
```

Expected: a `s1-tool` file exists. The script exits 0. No errors.

- [ ] **Step 3: Commit**

```bash
git add Clyde/Resources/clyde-hook.sh
git commit -m "feat(hook): extract tool_use_id from PreToolUse/PostToolUse payloads"
```

---

## Task 2: Hook — write `-agents/<id>.json` on `PreToolUse(Task)`

**Files:**
- Modify: `Clyde/Resources/clyde-hook.sh`

- [ ] **Step 1: Update header comment block**

Find the `# clyde-hook-version: 19` line at the top. Bump it:

```bash
# clyde-hook-version: 20
```

In the header event-table comment (around lines 14–28), update the `SubagentStart` line and add `Task fan-out`:

```bash
#   PreToolUse(Task)    → state/<session_id>-agents/<tool_use_id>.json (subagent dispatch)
#   PostToolUse(Task)   → removes state/<session_id>-agents/<tool_use_id>.json
#   SubagentStart       → legacy state/<session_id>-subagent (deprecated, backup only)
#   SubagentStop        → removes legacy -subagent; best-effort -agents/<id>.json removal
```

Also update the `SessionEnd` line in the header to include `-agents/` directory cleanup.

- [ ] **Step 2: Extend `PreToolUse` handler to write the per-agent file**

Locate the `PreToolUse)` branch (around line 393). After the existing `-tool` write block, add a Task-specific branch:

```bash
        if [ "$TOOL_NAME" = "Task" ] && [ -n "$TOOL_USE_ID" ]; then
            SUBAGENT_TYPE=$(extract_tool_input_field subagent_type)
            [ -z "$SUBAGENT_TYPE" ] && SUBAGENT_TYPE="agent"
            DESCRIPTION=$(extract_tool_input_field description)
            if [ -z "$DESCRIPTION" ]; then
                DESCRIPTION=$(extract_tool_input_field prompt | tr '\n' ' ')
                DESCRIPTION=$(truncate_summary "$DESCRIPTION" 40)
            else
                DESCRIPTION=$(truncate_summary "$DESCRIPTION" 80)
            fi
            ESC_AGENT=$(printf '%s' "$SUBAGENT_TYPE" | sed 's/\\/\\\\/g; s/"/\\"/g')
            ESC_SUMMARY=$(printf '%s' "$DESCRIPTION" | sed 's/\\/\\\\/g; s/"/\\"/g')
            ESC_TOOLID=$(printf '%s' "$TOOL_USE_ID" | sed 's/\\/\\\\/g; s/"/\\"/g')
            mkdir -p "$STATE_DIR/$KEY-agents"
            atomic_write "$STATE_DIR/$KEY-agents/$TOOL_USE_ID.json" \
                "{\"session_id\": \"$ESC_SID\", \"tool_use_id\": \"$ESC_TOOLID\", \"subagent_type\": \"$ESC_AGENT\", \"summary\": \"$ESC_SUMMARY\", \"started_at\": $TIMESTAMP}"
        fi
```

(`atomic_write` already writes to a sibling `.clyde-tmp.XXXXXX` then `mv`s into place — it works the same inside a subdirectory because `dirname` resolves correctly.)

- [ ] **Step 3: Smoke-test the new branch**

```bash
rm -rf /tmp/clyde-smoke
printf '%s' '{"hook_event_name":"PreToolUse","session_id":"s1","cwd":"/tmp","tool_name":"Task","tool_use_id":"toolu_a1","tool_input":{"subagent_type":"Explore","description":"find subagent code"}}' \
  | HOME=/tmp/clyde-smoke CLAUDE_PROJECT_DIR=/tmp bash Clyde/Resources/clyde-hook.sh
cat /tmp/clyde-smoke/.clyde/state/s1-agents/toolu_a1.json
```

Expected: JSON with `subagent_type:"Explore"`, `summary:"find subagent code"`, `tool_use_id:"toolu_a1"`, and a numeric `started_at`.

- [ ] **Step 4: Commit**

```bash
git add Clyde/Resources/clyde-hook.sh
git commit -m "feat(hook): write -agents/<id>.json on Task PreToolUse"
```

---

## Task 3: Hook — remove `-agents/<id>.json` on `PostToolUse(Task)` / failure

**Files:**
- Modify: `Clyde/Resources/clyde-hook.sh`

- [ ] **Step 1: Extend `PostToolUse` branch**

Locate the `PostToolUse)` branch (around line 414). Append after the existing `-tool` removal:

```bash
        if [ "$TOOL_NAME" = "Task" ] && [ -n "$TOOL_USE_ID" ]; then
            rm -f "$STATE_DIR/$KEY-agents/$TOOL_USE_ID.json"
        fi
```

- [ ] **Step 2: Extend `PostToolUseFailure` branch**

In `PostToolUseFailure)` (around lines 374–392), after the existing `rm -f "$STATE_DIR/$KEY-tool"` line, append the same Task-specific cleanup:

```bash
        if [ "$TOOL_NAME" = "Task" ] && [ -n "$TOOL_USE_ID" ]; then
            rm -f "$STATE_DIR/$KEY-agents/$TOOL_USE_ID.json"
        fi
```

- [ ] **Step 3: Smoke-test the full Pre→Post lifecycle**

```bash
rm -rf /tmp/clyde-smoke
PRE='{"hook_event_name":"PreToolUse","session_id":"s1","cwd":"/tmp","tool_name":"Task","tool_use_id":"toolu_a1","tool_input":{"subagent_type":"Explore","description":"x"}}'
POST='{"hook_event_name":"PostToolUse","session_id":"s1","cwd":"/tmp","tool_name":"Task","tool_use_id":"toolu_a1"}'
printf '%s' "$PRE"  | HOME=/tmp/clyde-smoke CLAUDE_PROJECT_DIR=/tmp bash Clyde/Resources/clyde-hook.sh
ls /tmp/clyde-smoke/.clyde/state/s1-agents/  # toolu_a1.json
printf '%s' "$POST" | HOME=/tmp/clyde-smoke CLAUDE_PROJECT_DIR=/tmp bash Clyde/Resources/clyde-hook.sh
ls /tmp/clyde-smoke/.clyde/state/s1-agents/ 2>&1  # empty or missing dir
```

Expected: after the PRE, the file exists; after the POST, the directory is empty.

- [ ] **Step 4: Commit**

```bash
git add Clyde/Resources/clyde-hook.sh
git commit -m "feat(hook): clear -agents/<id>.json on Task PostToolUse and failures"
```

---

## Task 4: Hook — `SessionEnd`, `Stop`, `SubagentStop`, header comments

**Files:**
- Modify: `Clyde/Resources/clyde-hook.sh`

- [ ] **Step 1: Extend `SessionEnd` to drop `-agents/`**

Locate the `SessionEnd)` branch (line 318). Replace its body with:

```bash
        rm -f "$STATE_DIR/$KEY-info" "$STATE_DIR/$KEY-busy" "$STATE_DIR/$KEY-error" "$STATE_DIR/$KEY-subagent" "$STATE_DIR/$KEY-tool" "$STATE_DIR/$KEY-plan" "$EVENTS_DIR/$KEY.json"
        rm -rf "$STATE_DIR/$KEY-agents"
```

- [ ] **Step 2: Keep `Stop` as-is for `-agents/`**

The `Stop)` branch (lines 357–360) already removes the legacy `-subagent` file. Do not touch `-agents/` here. Add a comment to make the intent explicit:

```bash
    Stop)
        # Clear busy, error, legacy subagent, tool, and attention markers.
        # NOTE: -agents/ is intentionally NOT cleared here; parallel subagents
        # often outlive the parent's Stop event and we want each one to vanish
        # only when its own PostToolUse(Task) arrives.
        rm -f "$STATE_DIR/$KEY-busy" "$STATE_DIR/$KEY-error" "$STATE_DIR/$KEY-subagent" "$STATE_DIR/$KEY-tool" "$EVENTS_DIR/$KEY.json"
        ;;
```

- [ ] **Step 3: Add defensive cleanup to `SubagentStop`**

Locate the `SubagentStop)` branch (line 449). Replace with:

```bash
    SubagentStop)
        rm -f "$STATE_DIR/$KEY-subagent"
        # Defensive backup cleanup. Pre/Post Task pairs are load-bearing,
        # but if Claude ever ships a SubagentStop with a tool_use_id and
        # the matching PostToolUse never arrives, this catches the orphan.
        SUB_TOOLID=$(extract_field tool_use_id)
        if [ -n "$SUB_TOOLID" ]; then
            rm -f "$STATE_DIR/$KEY-agents/$SUB_TOOLID.json"
        fi
        ;;
```

- [ ] **Step 4: Smoke-test SessionEnd cleanup**

```bash
rm -rf /tmp/clyde-smoke
PRE='{"hook_event_name":"PreToolUse","session_id":"s1","cwd":"/tmp","tool_name":"Task","tool_use_id":"toolu_a1","tool_input":{"subagent_type":"Explore","description":"x"}}'
END='{"hook_event_name":"SessionEnd","session_id":"s1","cwd":"/tmp"}'
printf '%s' "$PRE" | HOME=/tmp/clyde-smoke CLAUDE_PROJECT_DIR=/tmp bash Clyde/Resources/clyde-hook.sh
printf '%s' "$END" | HOME=/tmp/clyde-smoke CLAUDE_PROJECT_DIR=/tmp bash Clyde/Resources/clyde-hook.sh
test ! -d /tmp/clyde-smoke/.clyde/state/s1-agents && echo OK || echo FAIL
```

Expected: prints `OK`.

- [ ] **Step 5: Commit**

```bash
git add Clyde/Resources/clyde-hook.sh
git commit -m "feat(hook): clear -agents on SessionEnd, defensive SubagentStop cleanup"
```

---

## Task 5: Hook — bump installer version to 20

**Files:**
- Modify: `Clyde/Services/HookInstaller.swift`

- [ ] **Step 1: Update `currentScriptVersion`**

Open `Clyde/Services/HookInstaller.swift`, line 67:

```swift
    static let currentScriptVersion = 20
```

(Was `19`.)

- [ ] **Step 2: Build to confirm nothing else references the literal**

```bash
swift build 2>&1 | tail -20
```

Expected: clean build (no warnings about a stale `19` literal).

- [ ] **Step 3: Commit**

```bash
git add Clyde/Services/HookInstaller.swift Clyde/Resources/clyde-hook.sh
git commit -m "chore(hook): bump installed script version to 20"
```

(Note: this commit covers the `# clyde-hook-version: 20` line written in Task 2 if it wasn't separately staged. Verify with `git status` before committing — if the version line is already in a prior commit, just stage the Swift file.)

---

## Task 6: Model — `ActiveSubagent` + `Session.activeSubagents`

**Files:**
- Modify: `Clyde/Models/Session.swift`
- Test: `ClydeTests/ProcessMonitorTests.swift` (read in next task)

- [ ] **Step 1: Add the `ActiveSubagent` struct**

Open `Clyde/Models/Session.swift`. Near the other supporting structs (above the `Session` struct's `var subagentType` field, around line 60), add:

```swift
/// One in-flight Task-dispatched subagent inside a parent session.
struct ActiveSubagent: Equatable, Identifiable, Sendable {
    /// `tool_use_id` from the originating PreToolUse(Task) payload.
    let id: String
    /// `subagent_type` from `tool_input` (e.g. `general-purpose`, `Explore`).
    let type: String
    /// Trimmed `description` (or prompt fallback) from `tool_input`.
    let summary: String
    /// When the parent dispatched the Task call (hook write time).
    let startedAt: Date
}
```

- [ ] **Step 2: Add the field to `Session`**

Below the existing `var subagentType: String? = nil` line (around line 66), add:

```swift
    /// Currently running Task-dispatched subagents inside this session,
    /// sorted by `startedAt` ascending (oldest first). Empty when the
    /// session has no parallel Task fan-out in flight.
    var activeSubagents: [ActiveSubagent] = []
```

- [ ] **Step 3: Build**

```bash
swift build 2>&1 | tail -20
```

Expected: clean build.

- [ ] **Step 4: Commit**

```bash
git add Clyde/Models/Session.swift
git commit -m "feat(model): add ActiveSubagent and Session.activeSubagents"
```

---

## Task 7: Test — `refreshHookAgents` reads the directory (red)

**Files:**
- Modify: `ClydeTests/ProcessMonitorTests.swift`

- [ ] **Step 1: Find a parallel test for shape reference**

Run:

```bash
grep -n "refreshHookTools\|hookToolByPID\|stateDir" ClydeTests/ProcessMonitorTests.swift | head -20
```

Use the existing `-tool` integration test as the structural template (write `-info` + `-agents/foo.json` to a temp dir, instantiate `ProcessMonitor` with that dir, poll, assert).

- [ ] **Step 2: Add the failing test**

Append to `ClydeTests/ProcessMonitorTests.swift` (inside the existing `XCTestCase` subclass, before the closing brace):

```swift
func testActiveSubagentsListedFromAgentsDir() throws {
    let dir = makeTempStateDir()
    let pid = currentTestPID()
    try writeInfoFile(dir: dir, sid: "s1", pid: pid)
    let agentsDir = dir.appendingPathComponent("s1-agents", isDirectory: true)
    try FileManager.default.createDirectory(at: agentsDir, withIntermediateDirectories: true)

    let now = Int(Date().timeIntervalSince1970)
    try writeJSON(
        at: agentsDir.appendingPathComponent("toolu_a.json"),
        body: ["session_id":"s1","pid":pid,"tool_use_id":"toolu_a","subagent_type":"Explore","summary":"find code","started_at":now - 20]
    )
    try writeJSON(
        at: agentsDir.appendingPathComponent("toolu_b.json"),
        body: ["session_id":"s1","pid":pid,"tool_use_id":"toolu_b","subagent_type":"general-purpose","summary":"research","started_at":now - 5]
    )

    let monitor = ProcessMonitor(stateDir: dir)
    monitor.pollForTests()

    let session = try XCTUnwrap(monitor.sessionsForTests().first { $0.pid == pid })
    XCTAssertEqual(session.activeSubagents.map(\.id), ["toolu_a", "toolu_b"])  // sorted oldest-first
    XCTAssertEqual(session.activeSubagents.map(\.type), ["Explore", "general-purpose"])
    XCTAssertEqual(session.activeSubagents.map(\.summary), ["find code", "research"])
}
```

(If the existing test file lacks helpers like `makeTempStateDir` / `writeInfoFile` / `writeJSON` / `pollForTests` / `sessionsForTests`, name them whatever the file already exposes — copy from the existing `-tool` test verbatim and substitute file path and key fields.)

- [ ] **Step 3: Run, verify it fails**

```bash
swift test --filter testActiveSubagentsListedFromAgentsDir 2>&1 | tail -25
```

Expected: FAIL (compile error on `activeSubagents` not on `Session`? No — Task 6 added it. The failure is the assertion: the array is empty because `ProcessMonitor` doesn't read the directory yet).

- [ ] **Step 4: Commit**

```bash
git add ClydeTests/ProcessMonitorTests.swift
git commit -m "test(monitor): expect activeSubagents from -agents directory"
```

---

## Task 8: Implement `refreshHookAgents` + apply state

**Files:**
- Modify: `Clyde/Services/ProcessMonitor.swift`

- [ ] **Step 1: Add a backing dictionary**

Next to the existing `private var hookSubagentByPID` (around line 63), add:

```swift
    /// Active Task-dispatched subagents per PID, populated from `-agents/*.json` markers.
    /// Inner array is sorted by `startedAt` ascending.
    private var hookAgentsByPID: [pid_t: [ActiveSubagent]] = [:]
```

- [ ] **Step 2: Implement `refreshHookAgents`**

Below `refreshHookSubagents` (around line 590), add:

```swift
    /// Reads `state/<sid>-agents/*.json` marker files written by PreToolUse(Task).
    /// Returns true if the dictionary changed since last call.
    @discardableResult
    private func refreshHookAgents() -> Bool {
        let cutoff = Date().addingTimeInterval(-30 * 60)  // 30-minute GC
        var byPID: [pid_t: [ActiveSubagent]] = [:]

        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: stateDir, includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            let changed = !hookAgentsByPID.isEmpty
            if changed { hookAgentsByPID = [:] }
            return changed
        }

        for entry in entries where entry.lastPathComponent.hasSuffix("-agents") {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let sid = String(entry.lastPathComponent.dropLast("-agents".count))
            guard let parentPID = pidForSessionID(sid) else { continue }

            guard let files = try? FileManager.default.contentsOfDirectory(
                at: entry, includingPropertiesForKeys: nil
            ) else { continue }

            var agents: [ActiveSubagent] = []
            for file in files where file.pathExtension == "json" {
                guard let data = try? Data(contentsOf: file),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let id = json["tool_use_id"] as? String,
                      let type = json["subagent_type"] as? String,
                      let startedAt = json["started_at"] as? Int else {
                    continue
                }
                let started = Date(timeIntervalSince1970: TimeInterval(startedAt))
                guard started >= cutoff else {
                    ClydeLog.hooks.info("Dropping stale subagent entry id=\(id, privacy: .public)")
                    continue
                }
                let summary = (json["summary"] as? String) ?? ""
                agents.append(ActiveSubagent(id: id, type: type, summary: summary, startedAt: started))
            }
            if !agents.isEmpty {
                byPID[parentPID] = agents.sorted { $0.startedAt < $1.startedAt }
            }
        }

        let changed = byPID != hookAgentsByPID
        if changed { hookAgentsByPID = byPID }
        return changed
    }
```

- [ ] **Step 3: Add the `pidForSessionID` helper if missing**

Grep first:

```bash
grep -n "pidForSessionID\|sidToPID\|sessionIDToPID" Clyde/Services/ProcessMonitor.swift
```

If absent, add this helper near the other private helpers in `ProcessMonitor`:

```swift
    /// Maps a hook `session_id` (the prefix of marker filenames) to the PID
    /// recorded by its `-info` file. Returns nil if the info file is gone or
    /// the PID it points to is no longer alive.
    private func pidForSessionID(_ sid: String) -> pid_t? {
        let info = stateDir.appendingPathComponent("\(sid)-info")
        guard let data = try? Data(contentsOf: info),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pidValue = json["pid"] as? Int else { return nil }
        let pid = pid_t(pidValue)
        return kill(pid, 0) == 0 ? pid : nil
    }
```

- [ ] **Step 4: Wire `refreshHookAgents` into `pollHookState`**

In `pollHookState()` (around line 670):

```swift
        let busyChanged = refreshHookBusyPIDs()
        let errorChanged = refreshHookErrors()
        let subagentChanged = refreshHookSubagents()
        let toolChanged = refreshHookTools()
        let planChanged = refreshHookPlans()
        let agentsChanged = refreshHookAgents()
```

Extend the two fingerprint conditions (around lines 698 and 702) to OR in `agentsChanged`:

```swift
        if busyChanged || errorChanged || subagentChanged || toolChanged || planChanged || agentsChanged {
            applyBusyStateToSessions()
        }
```

(Same change on the second `if` block on line 702.)

- [ ] **Step 5: Apply to the in-memory sessions array**

In `applyBusyStateToSessions` (around line 730 where `subagentType` is applied), append:

```swift
            let newAgents = hookAgentsByPID[pid] ?? []
            if updated[index].activeSubagents != newAgents {
                updated[index].activeSubagents = newAgents
            }
```

Also extend the equivalent block in the main `poll()` reconcile (line 384):

```swift
            existing.activeSubagents = hookAgentsByPID[pid] ?? []
```

- [ ] **Step 6: Run the failing test, watch it pass**

```bash
swift test --filter testActiveSubagentsListedFromAgentsDir 2>&1 | tail -15
```

Expected: PASS.

- [ ] **Step 7: Run the full suite to confirm no regressions**

```bash
swift test 2>&1 | tail -10
```

Expected: all tests pass (~63 with the new one).

- [ ] **Step 8: Commit**

```bash
git add Clyde/Services/ProcessMonitor.swift
git commit -m "feat(monitor): read -agents/*.json into Session.activeSubagents"
```

---

## Task 9: Test — 30-minute GC drops stale entries

**Files:**
- Modify: `ClydeTests/ProcessMonitorTests.swift`

- [ ] **Step 1: Add the GC test**

Append:

```swift
func testActiveSubagentsGCsEntriesOlderThan30Minutes() throws {
    let dir = makeTempStateDir()
    let pid = currentTestPID()
    try writeInfoFile(dir: dir, sid: "s1", pid: pid)
    let agentsDir = dir.appendingPathComponent("s1-agents", isDirectory: true)
    try FileManager.default.createDirectory(at: agentsDir, withIntermediateDirectories: true)

    let now = Int(Date().timeIntervalSince1970)
    try writeJSON(
        at: agentsDir.appendingPathComponent("toolu_old.json"),
        body: ["session_id":"s1","pid":pid,"tool_use_id":"toolu_old","subagent_type":"Explore","summary":"old","started_at":now - 31 * 60]
    )
    try writeJSON(
        at: agentsDir.appendingPathComponent("toolu_fresh.json"),
        body: ["session_id":"s1","pid":pid,"tool_use_id":"toolu_fresh","subagent_type":"Plan","summary":"fresh","started_at":now - 60]
    )

    let monitor = ProcessMonitor(stateDir: dir)
    monitor.pollForTests()

    let session = try XCTUnwrap(monitor.sessionsForTests().first { $0.pid == pid })
    XCTAssertEqual(session.activeSubagents.map(\.id), ["toolu_fresh"])
    // File for the stale entry is intentionally NOT deleted by the monitor;
    // SessionEnd / manual reset handles disk cleanup.
    XCTAssertTrue(FileManager.default.fileExists(atPath: agentsDir.appendingPathComponent("toolu_old.json").path))
}
```

- [ ] **Step 2: Run**

```bash
swift test --filter testActiveSubagentsGCsEntriesOlderThan30Minutes 2>&1 | tail -15
```

Expected: PASS (Task 8 already implemented the GC; this is a regression guard).

- [ ] **Step 3: Commit**

```bash
git add ClydeTests/ProcessMonitorTests.swift
git commit -m "test(monitor): GC subagents older than 30 minutes"
```

---

## Task 10: Test — legacy `-subagent` fallback when `-agents/` is absent

**Files:**
- Modify: `ClydeTests/ProcessMonitorTests.swift`

- [ ] **Step 1: Add the backwards-compat test**

```swift
func testLegacySubagentMarkerCoexistsWithEmptyAgentsDir() throws {
    let dir = makeTempStateDir()
    let pid = currentTestPID()
    try writeInfoFile(dir: dir, sid: "s1", pid: pid)
    try writeJSON(
        at: dir.appendingPathComponent("s1-subagent"),
        body: ["session_id":"s1","pid":pid,"agent_type":"general-purpose","timestamp":Int(Date().timeIntervalSince1970)]
    )

    let monitor = ProcessMonitor(stateDir: dir)
    monitor.pollForTests()

    let session = try XCTUnwrap(monitor.sessionsForTests().first { $0.pid == pid })
    XCTAssertEqual(session.subagentType, "general-purpose")
    XCTAssertTrue(session.activeSubagents.isEmpty)
}
```

- [ ] **Step 2: Run**

```bash
swift test --filter testLegacySubagentMarkerCoexistsWithEmptyAgentsDir 2>&1 | tail -15
```

Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add ClydeTests/ProcessMonitorTests.swift
git commit -m "test(monitor): legacy -subagent fallback survives the -agents path"
```

---

## Task 11: `resetSessionState` also wipes `-agents/`

**Files:**
- Modify: `Clyde/Services/ProcessMonitor.swift`
- Modify: `ClydeTests/ProcessMonitorTests.swift`

- [ ] **Step 1: Add the failing test**

```swift
func testResetSessionStateClearsAgentsDir() throws {
    let dir = makeTempStateDir()
    let pid = currentTestPID()
    try writeInfoFile(dir: dir, sid: "s1", pid: pid)
    let agentsDir = dir.appendingPathComponent("s1-agents", isDirectory: true)
    try FileManager.default.createDirectory(at: agentsDir, withIntermediateDirectories: true)
    try writeJSON(
        at: agentsDir.appendingPathComponent("toolu_a.json"),
        body: ["session_id":"s1","pid":pid,"tool_use_id":"toolu_a","subagent_type":"Explore","summary":"x","started_at":Int(Date().timeIntervalSince1970)]
    )

    let monitor = ProcessMonitor(stateDir: dir)
    monitor.pollForTests()
    let session = try XCTUnwrap(monitor.sessionsForTests().first { $0.pid == pid })
    monitor.resetSessionState(session)

    XCTAssertFalse(FileManager.default.fileExists(atPath: agentsDir.path))
}
```

- [ ] **Step 2: Run, expect failure**

```bash
swift test --filter testResetSessionStateClearsAgentsDir 2>&1 | tail -15
```

Expected: FAIL — directory still exists.

- [ ] **Step 3: Update `resetSessionState`**

In `Clyde/Services/ProcessMonitor.swift`, find `resetSessionState`. Add `-agents/` directory removal alongside the existing per-file `rm` calls:

```swift
        try? FileManager.default.removeItem(at: stateDir.appendingPathComponent("\(sid)-agents"))
```

(Place it next to the existing `\(sid)-subagent` / `\(sid)-tool` / `\(sid)-plan` removals.)

- [ ] **Step 4: Run, expect pass**

```bash
swift test --filter testResetSessionStateClearsAgentsDir 2>&1 | tail -15
swift test 2>&1 | tail -10
```

Expected: PASS on the new test; full suite still green.

- [ ] **Step 5: Commit**

```bash
git add Clyde/Services/ProcessMonitor.swift ClydeTests/ProcessMonitorTests.swift
git commit -m "feat(monitor): resetSessionState removes -agents directory"
```

---

## Task 12: `AppViewModel` — expand state + toggle

**Files:**
- Modify: `Clyde/ViewModels/AppViewModel.swift`

- [ ] **Step 1: Add published state**

Open `Clyde/ViewModels/AppViewModel.swift`. Near the other `@Published` properties, add:

```swift
    /// Session IDs whose subagent list is currently expanded past the 3-visible cap.
    /// In-memory only — resets on relaunch. Automatically pruned when a session's
    /// active count drops to 3 or fewer.
    @Published var expandedSubagentSessions: Set<UUID> = []
```

- [ ] **Step 2: Add the toggle method**

```swift
    func toggleSubagentExpansion(_ sessionID: UUID) {
        if expandedSubagentSessions.contains(sessionID) {
            expandedSubagentSessions.remove(sessionID)
        } else {
            expandedSubagentSessions.insert(sessionID)
        }
    }
```

- [ ] **Step 3: Auto-prune when sessions update**

Find the spot where `AppViewModel` receives new sessions from `ProcessMonitor` (typically `sessions = newSessions` or a Combine sink). Right after the assignment, add:

```swift
        // Auto-collapse subagent lists when the active count drops to ≤3,
        // so the expand state doesn't get stuck "open" for a future fan-out.
        expandedSubagentSessions = expandedSubagentSessions.filter { sid in
            (sessions.first { $0.id == sid }?.activeSubagents.count ?? 0) > 3
        }
```

(If the assignment lives inside a closure that captures `self` weakly, use `self.sessions` / `self.expandedSubagentSessions` accordingly.)

- [ ] **Step 4: Build**

```bash
swift build 2>&1 | tail -15
```

Expected: clean build.

- [ ] **Step 5: Commit**

```bash
git add Clyde/ViewModels/AppViewModel.swift
git commit -m "feat(viewmodel): track expanded subagent lists per session"
```

---

## Task 13: `SessionRow` — second line shows `<N> agents · <dur>` for N≥2

**Files:**
- Modify: `Clyde/Views/Components/SessionRow.swift`

- [ ] **Step 1: Locate the second-line rendering**

Open `Clyde/Views/Components/SessionRow.swift` and find the block around line 110 that branches on `session.activeTool`. Today it renders `Tool · summary · dur` when a tool is active and the project path otherwise.

- [ ] **Step 2: Add the multi-agent case ahead of the existing branches**

Wrap the existing tool/path branches in a new conditional:

```swift
                    if session.activeSubagents.count >= 2 {
                        SubagentSummaryLine(session: session)
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel(
                                "\(session.activeSubagents.count) agents running"
                            )
                            .accessibilityAddTraits(.updatesFrequently)
                    } else if let tool = session.activeTool, let label = session.toolDisplayLabel {
                        // existing single-tool line
                        ...
                    } else {
                        // existing path line
                        ...
                    }
```

(Preserve the existing slide/`ZStack` animation around the tool/path branches — only the outer `if` is new.)

- [ ] **Step 3: Add the `SubagentSummaryLine` helper**

At the bottom of `SessionRow.swift` (next to `PlanBadge` around line 439), add:

```swift
private struct SubagentSummaryLine: View {
    let session: Session

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let oldest = session.activeSubagents.first?.startedAt ?? ctx.date
            let elapsed = max(0, Int(ctx.date.timeIntervalSince(oldest)))
            HStack(spacing: 4) {
                Text("\(session.activeSubagents.count) agents")
                Text("·")
                Text(Duration.format(elapsed))
                    .monospacedDigit()
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        }
    }
}
```

- [ ] **Step 4: Manual smoke**

```bash
swift build 2>&1 | tail -10
```

Open the app from Xcode, dispatch two parallel `Task` tool calls in a Claude session, watch the row second line flip from `Task · <summary>` to `2 agents · 0:01`.

- [ ] **Step 5: Commit**

```bash
git add Clyde/Views/Components/SessionRow.swift
git commit -m "feat(panel): show '<N> agents · <dur>' when 2+ subagents fan out"
```

---

## Task 14: `SessionRow` — two-lines-per-agent list under the row

**Files:**
- Modify: `Clyde/Views/Components/SessionRow.swift`

- [ ] **Step 1: Add a new `SubagentList` view at the bottom of the file**

```swift
private struct SubagentList: View {
    let session: Session
    let isExpanded: Bool
    let onToggle: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let purple = Color(red: 0.486, green: 0.361, blue: 1.0)  // #7C5CFF

    private var visible: [ActiveSubagent] {
        isExpanded ? session.activeSubagents : Array(session.activeSubagents.prefix(3))
    }

    private var overflowCount: Int {
        max(0, session.activeSubagents.count - 3)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(visible) { agent in
                row(for: agent)
            }
            if overflowCount > 0 || isExpanded {
                expandLabel
            }
        }
        .padding(.leading, 8)
        .padding(.vertical, 2)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(purple.opacity(0.55))
                .frame(width: 2)
        }
        .padding(.top, 6)
        .padding(.leading, 2)
    }

    @ViewBuilder
    private func row(for agent: ActiveSubagent) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let elapsed = max(0, Int(ctx.date.timeIntervalSince(agent.startedAt)))
            VStack(alignment: .leading, spacing: 1) {
                HStack {
                    Text(agent.type)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(purple)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(Duration.format(elapsed))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                if !agent.summary.isEmpty {
                    Text(agent.summary)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(agent.type), \(agent.summary)")
        .accessibilityValue("running")
        .accessibilityAddTraits(.updatesFrequently)
    }

    @ViewBuilder
    private var expandLabel: some View {
        Button(action: onToggle) {
            Text(isExpanded ? "▴ Show less" : "+ \(overflowCount) more agents")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(isExpanded ? .secondary : AnyShapeStyle(purple))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isExpanded ? "Show less" : "\(overflowCount) more agents")
        .accessibilityHint(isExpanded
            ? "Double-tap to collapse the subagent list"
            : "Double-tap to expand the subagent list")
    }
}
```

- [ ] **Step 2: Mount the list in `SessionRow`**

Inside the main `VStack` of the row body, immediately after the second-line `if/else` block from Task 13, add:

```swift
                    if session.activeSubagents.count >= 2 {
                        SubagentList(
                            session: session,
                            isExpanded: viewModel.expandedSubagentSessions.contains(session.id),
                            onToggle: { viewModel.toggleSubagentExpansion(session.id) }
                        )
                        .transition(reduceMotion
                            ? .opacity
                            : .asymmetric(
                                insertion: .opacity.combined(with: .move(edge: .top)),
                                removal: .opacity))
                        .animation(reduceMotion
                            ? .easeInOut(duration: 0.12)
                            : .spring(response: 0.28, dampingFraction: 0.85),
                            value: session.activeSubagents.map(\.id))
                    }
```

If `viewModel` and `reduceMotion` aren't already in scope at the call site, add to the row:

```swift
    @EnvironmentObject private var viewModel: AppViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
```

- [ ] **Step 3: Build + manual smoke**

```bash
swift build 2>&1 | tail -10
```

Run the app, dispatch 5 parallel `Task` calls in Claude, verify:
- second line says `5 agents · …`
- block below shows 3 agents (oldest first) + `+ 2 more agents`
- clicking expands to all 5 + `▴ Show less`
- finishing one drops it from the list; auto-collapse fires once count ≤ 3

- [ ] **Step 4: Commit**

```bash
git add Clyde/Views/Components/SessionRow.swift
git commit -m "feat(panel): render parallel subagents block with 3-visible + expand"
```

---

## Task 15: Voice-over smoke + reduce-motion verification

**Files:**
- Modify: `docs/hook-smoke.md` (or wherever the existing a11y manual scenarios live; grep first)

- [ ] **Step 1: Find the existing a11y/smoke doc**

```bash
grep -rln "reduce.?motion\|VoiceOver" docs/ | head
```

Open whichever file holds the v0.3.1 a11y scenarios. (Most likely `docs/a11y-smoke.md`.)

- [ ] **Step 2: Append three scenarios**

```markdown
### Parallel subagents (v0.3.x)

1. **Fan-out grows and shrinks**
   - Trigger: send a Claude prompt that dispatches 5 parallel `Task` calls.
   - Expect: row second line flips to `5 agents · 0:Ns`, subagent block lists 3 with `+ 2 more agents`. As each `Task` returns, lines disappear oldest-first. When 3 or fewer remain, the `+N more` label disappears automatically.
2. **VoiceOver labels**
   - With VO on, focus the row: should announce `<project>, busy`, then descend into the block and announce each agent as `<type>, <summary>, running, <duration>` with `updates frequently` trait.
   - Focus the `+N more` label: announces `<N> more agents`, hint `Double-tap to expand`.
3. **Reduce-motion**
   - Enable System Settings → Accessibility → Display → Reduce motion.
   - Repeat scenario 1: the block should fade in/out without sliding; expand/collapse changes height instantly with a 120 ms opacity crossfade.
```

- [ ] **Step 3: Commit**

```bash
git add docs/a11y-smoke.md  # or whichever file was edited
git commit -m "docs(a11y): smoke scenarios for parallel subagents"
```

---

## Task 16: ROADMAP + CHANGELOG

**Files:**
- Modify: `ROADMAP.md`
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Add the item to ROADMAP**

In `ROADMAP.md`, append to the `## Phase: v0.3.0+` block (above the Cleat item is fine — order is loose):

```markdown
- [x] Parallel subagents in the panel — `clyde-hook` v20 writes `state/<sid>-agents/<tool_use_id>.json` on every `PreToolUse(Task)` and clears it on the matching `PostToolUse(Task)` / failure; `ProcessMonitor.refreshHookAgents` mirrors the existing `-tool` plumbing. `SessionRow` flips the second line to `<N> agents · <dur>` for N≥2 and renders a two-lines-per-agent block (type · duration, then summary) underneath, sorted oldest-first with a 3-visible cap and tap-to-expand `+N more` label. Defensive 30-min GC drops zombie rows; legacy `-subagent` fallback keeps v0.2.x sessions visible until next `claude` restart. !md #hooks #ux
```

Mark it `[x]` because by the time this lands the work is done. If you prefer to leave `[ ]` and tick after merge, do that — but follow CLAUDE.md's "replace description with a one-line summary of what was actually done" convention when ticking.

- [ ] **Step 2: Add the CHANGELOG bullet**

In `CHANGELOG.md` under `## [Unreleased]`, add:

```markdown
- Panel now surfaces every parallel subagent dispatched via the built-in `Agent` (Task) tool. The session row shows `N agents · live duration`, with a left-bordered list of each subagent's type and short description underneath; lists longer than three collapse behind a `+N more agents` tap. Older `-subagent` markers from running pre-v0.3.x sessions still render the v0.2 single-agent line until the user restarts `claude`.
```

- [ ] **Step 3: Run the test suite one last time**

```bash
swift test 2>&1 | tail -10
```

Expected: all tests pass.

- [ ] **Step 4: Commit**

```bash
git add ROADMAP.md CHANGELOG.md
git commit -m "docs: roadmap tick and changelog entry for parallel subagents"
```

---

## Verification before handoff

Run all of these from the repo root before declaring the plan complete:

```bash
swift test 2>&1 | tail -10                       # full suite green
swift build 2>&1 | tail -5                       # clean build
grep -c "clyde-hook-version: 20" Clyde/Resources/clyde-hook.sh   # 1
grep -c "currentScriptVersion = 20" Clyde/Services/HookInstaller.swift   # 1
```

Manual: launch the app, dispatch 4–5 parallel `Task` calls in a Claude Code session, verify the block appears with correct counts/sorting, expand and collapse, watch entries vanish as each subagent finishes, and confirm reduce-motion path with the System Setting toggled on.
