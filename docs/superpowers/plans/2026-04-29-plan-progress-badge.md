# Plan Progress Badge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Surface plan-then-execute progress on the session row. When Claude calls `TaskCreate`/`TaskCompleted`, Clyde shows a small `📋 N/M` badge with a progress bar (turns to `✓ N/N` in green on completion) inline next to the session name.

**Architecture:** New per-session state file `~/.clyde/state/<sid>-plan` (JSON: `task_count`, `done_count`, `started_at`) written by `clyde-hook.sh` v18 on `TaskCreated`/`TaskCompleted` (read-modify-write), removed on `SessionEnd`. `ProcessMonitor.refreshHookPlans()` mirrors the v17 `-tool` plumbing one-for-one. `SessionRow` adds a private `PlanBadge` view inline in the existing name HStack.

**Tech Stack:** Swift 5.9, SwiftUI (macOS 13+), XCTest, bash 3.2 (system bash on macOS), python3 (already used in the hook script).

**Source spec:** `docs/superpowers/specs/2026-04-29-plan-progress-badge-design.md`

**Predecessor:** v0.3.0 #1 (tool + duration in panel, commits `1961afa..01917be`). This feature reuses the same architectural patterns; many tasks below are direct mirrors of the v17 implementation.

---

## File Structure

**Modify:**
- `Clyde/Resources/clyde-hook.sh` — bump version to 18, add `read_plan_field` helper, add `TaskCreated` and `TaskCompleted` cases (read-modify-write `-plan` file), append `-plan` to `SessionEnd` rm list, update `# Handled events:` block.
- `Clyde/Services/HookInstaller.swift` — bump `currentScriptVersion` 17→18, add `TaskCreated` and `TaskCompleted` to `registeredHookEvents`, update doc block.
- `Clyde/Models/Session.swift` — add `ActivePlan` struct (`taskCount`, `doneCount`, `startedAt`, `isComplete`, `progress`) and `activePlan: ActivePlan?` field on `Session`.
- `Clyde/Services/ProcessMonitor.swift` — add `hookPlanByPID`, `refreshHookPlans()`, wire into `poll()`, `pollHookState()`, `applyBusyStateToSessions()`, all three branches of `updatedSession()`.
- `Clyde/Views/Components/SessionRow.swift` — add private `PlanBadge` view, place it inside the name HStack between `Text(session.displayName)` and `disambiguator`.
- `Clyde/ViewModels/AppViewModel.swift` — extend `resetSession(_:)` to also remove `-error`, `-subagent`, `-tool`, `-plan` (currently only clears `-info` and `-busy`; the spec assumed full coverage that doesn't actually exist).
- `ClydeTests/SessionTests.swift` — add `ActivePlan` unit tests + `Session.activePlan` default-nil test.
- `ClydeTests/ProcessMonitorTests.swift` — add `writePlanFile` helper + 5 tests covering populate / clear / dead-PID / malformed / re-write-increment.
- `ClydeTests/AppViewModelTests.swift` — add a regression test that `resetSession` removes `-plan` (and the other state files) from disk.
- `ROADMAP.md` — tick off the v0.3.0 `TaskCreated` item.
- `CHANGELOG.md` — add bullet under `## [Unreleased]`.

**No new files.** Everything fits in existing modules; the new Swift types (`ActivePlan`, `PlanBadge`) are private value types alongside their consumers.

---

## Task 1: Hook script v18 — `TaskCreated` / `TaskCompleted` cases

**Files:**
- Modify: `Clyde/Resources/clyde-hook.sh`

This task is hook-only. It writes the new state file but nothing in Clyde reads it yet. Do not bump `HookInstaller.currentScriptVersion` here — that goes in Task 7 after the Swift consumer is wired up.

- [ ] **Step 1: Add `read_plan_field` helper**

After the existing `compute_tool_summary` function (around line 177) add:

```bash
# Read a numeric field from the existing -plan file (if any). Returns
# 0 if the file is missing, the key is absent, or python3 fails. Uses
# python3 because hand-parsing arbitrary-order JSON keys in shell is
# fragile (the existing extract_field grep fallback works because
# Claude's payloads have predictable shapes, but our own state files
# could be re-ordered by a future hook revision).
read_plan_field() {
    local key=$1
    local plan_file="$STATE_DIR/$KEY-plan"
    if [ ! -f "$plan_file" ]; then
        printf '0'
        return
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        # python3 missing — best-effort grep for the key. Acceptable
        # because we only emit integer values for these keys, no
        # quoting / escaping concerns.
        local value
        value=$(grep -o "\"$key\"[[:space:]]*:[[:space:]]*[0-9]*" "$plan_file" 2>/dev/null \
            | head -n1 \
            | sed -E 's/.*:[[:space:]]*([0-9]+)/\1/')
        printf '%s' "${value:-0}"
        return
    fi
    python3 -c "
import json, sys
try:
    with open('$plan_file') as f:
        d = json.load(f)
    v = d.get('$key', 0)
    print(int(v) if isinstance(v, (int, float)) else 0)
except Exception:
    print(0)
" 2>/dev/null || printf '0'
}
```

- [ ] **Step 2: Add `TaskCreated` case branch**

Insert immediately before the existing `Notification|PreCompact|PostCompact)` branch (~end of the case statement):

```bash
    TaskCreated)
        # Plan-then-execute progress. Read the existing -plan record
        # (if any) so we can increment task_count without losing
        # done_count or the original started_at. First TaskCreated
        # initializes started_at to the current timestamp.
        PLAN_TASK_COUNT=$(read_plan_field task_count)
        PLAN_DONE_COUNT=$(read_plan_field done_count)
        PLAN_STARTED_AT=$(read_plan_field started_at)
        if [ "$PLAN_STARTED_AT" -eq 0 ] 2>/dev/null; then
            PLAN_STARTED_AT=$TIMESTAMP
        fi
        PLAN_TASK_COUNT=$((PLAN_TASK_COUNT + 1))
        atomic_write "$STATE_DIR/$KEY-plan" \
            "{\"session_id\": \"$ESC_SID\", \"pid\": $CLAUDE_PID, \"task_count\": $PLAN_TASK_COUNT, \"done_count\": $PLAN_DONE_COUNT, \"started_at\": $PLAN_STARTED_AT}"
        ;;
    TaskCompleted)
        # Increment done_count only if a -plan file already exists.
        # A TaskCompleted without a prior TaskCreated would be a race
        # / lost event — fabricating a new file with done_count=1 and
        # task_count=0 would render as "1/0" in the UI, which is worse
        # than skipping silently.
        if [ -f "$STATE_DIR/$KEY-plan" ]; then
            PLAN_TASK_COUNT=$(read_plan_field task_count)
            PLAN_DONE_COUNT=$(read_plan_field done_count)
            PLAN_STARTED_AT=$(read_plan_field started_at)
            PLAN_DONE_COUNT=$((PLAN_DONE_COUNT + 1))
            atomic_write "$STATE_DIR/$KEY-plan" \
                "{\"session_id\": \"$ESC_SID\", \"pid\": $CLAUDE_PID, \"task_count\": $PLAN_TASK_COUNT, \"done_count\": $PLAN_DONE_COUNT, \"started_at\": $PLAN_STARTED_AT}"
        fi
        ;;
```

- [ ] **Step 3: Extend `SessionEnd` to remove `-plan`**

Find the existing `SessionEnd)` branch (currently around line 278 — after Task 1 of the previous feature it was: `rm -f "$STATE_DIR/$KEY-info" "$STATE_DIR/$KEY-busy" "$STATE_DIR/$KEY-error" "$STATE_DIR/$KEY-subagent" "$STATE_DIR/$KEY-tool" "$EVENTS_DIR/$KEY.json"`). Append `state/$KEY-plan` to the rm list:

```bash
    SessionEnd)
        rm -f "$STATE_DIR/$KEY-info" "$STATE_DIR/$KEY-busy" "$STATE_DIR/$KEY-error" "$STATE_DIR/$KEY-subagent" "$STATE_DIR/$KEY-tool" "$STATE_DIR/$KEY-plan" "$EVENTS_DIR/$KEY.json"
        ;;
```

Note: do NOT add `-plan` to the `Stop)` rm list. Cross-turn persistence is a feature.

- [ ] **Step 4: Update header docs and bump hook version**

At the top of the file:

- Change `# clyde-hook-version: 17` → `# clyde-hook-version: 18`.
- In the `# Handled events:` block, update the SessionEnd line and add two new lines (keep the rest of the block as-is):

```
#   SessionEnd          → removes info + busy + error + subagent + tool + plan + event
#   TaskCreated         → bumps task_count in state/<session_id>-plan
#   TaskCompleted       → bumps done_count in state/<session_id>-plan (if file exists)
```

- [ ] **Step 5: Smoke-test the hook**

Use the same `exec -a claude` wrapper from the v17 smoke test (the hook's `find_claude_pid` walks PPID looking for a process named `claude` and exits early if none is found). Run from the repo root:

```bash
TMPHOME=$(mktemp -d)
HOOK=$(pwd)/Clyde/Resources/clyde-hook.sh

fire_hook() {
    ( HOME=$TMPHOME exec -a claude bash -c "bash '$HOOK'" <<<"$1" )
}

SID=11111111-1111-1111-1111-111111111111

# 1. First TaskCreated initializes the file
fire_hook "{\"hook_event_name\":\"TaskCreated\",\"session_id\":\"$SID\",\"cwd\":\"/tmp\"}"
cat "$TMPHOME/.clyde/state/$SID-plan"
# Expect: task_count=1, done_count=0, started_at=<some unix epoch>

# 2. Second TaskCreated increments task_count, preserves started_at
sleep 1
fire_hook "{\"hook_event_name\":\"TaskCreated\",\"session_id\":\"$SID\",\"cwd\":\"/tmp\"}"
cat "$TMPHOME/.clyde/state/$SID-plan"
# Expect: task_count=2, done_count=0, started_at unchanged from step 1

# 3. Three more TaskCreated → task_count=5
fire_hook "{\"hook_event_name\":\"TaskCreated\",\"session_id\":\"$SID\",\"cwd\":\"/tmp\"}"
fire_hook "{\"hook_event_name\":\"TaskCreated\",\"session_id\":\"$SID\",\"cwd\":\"/tmp\"}"
fire_hook "{\"hook_event_name\":\"TaskCreated\",\"session_id\":\"$SID\",\"cwd\":\"/tmp\"}"
cat "$TMPHOME/.clyde/state/$SID-plan"
# Expect: task_count=5, done_count=0

# 4. Two TaskCompleted → done_count=2, task_count unchanged
fire_hook "{\"hook_event_name\":\"TaskCompleted\",\"session_id\":\"$SID\",\"cwd\":\"/tmp\"}"
fire_hook "{\"hook_event_name\":\"TaskCompleted\",\"session_id\":\"$SID\",\"cwd\":\"/tmp\"}"
cat "$TMPHOME/.clyde/state/$SID-plan"
# Expect: task_count=5, done_count=2

# 5. Output is valid JSON
python3 -c "import json; print(json.load(open('$TMPHOME/.clyde/state/$SID-plan')))"
# Expect: {'session_id': '...', 'pid': <int>, 'task_count': 5, 'done_count': 2, 'started_at': <int>}

# 6. TaskCompleted without prior TaskCreated does NOT create a file
SID2=22222222-2222-2222-2222-222222222222
fire_hook "{\"hook_event_name\":\"TaskCompleted\",\"session_id\":\"$SID2\",\"cwd\":\"/tmp\"}"
ls "$TMPHOME/.clyde/state/" | grep -- "$SID2-plan" && echo "FAIL: file created" || echo "OK: no file created"

# 7. SessionEnd removes -plan
fire_hook "{\"hook_event_name\":\"SessionEnd\",\"session_id\":\"$SID\",\"cwd\":\"/tmp\"}"
ls "$TMPHOME/.clyde/state/" | grep -- "$SID-plan" && echo "FAIL: -plan still present" || echo "OK: cleared"

rm -rf "$TMPHOME"
```

All seven checks must pass. Fix the script if any fail.

- [ ] **Step 6: Commit**

```bash
git add Clyde/Resources/clyde-hook.sh
git commit -m "feat(hook): track plan-then-execute progress via -plan state file"
```

---

## Task 2: `Session.ActivePlan` model

**Files:**
- Modify: `Clyde/Models/Session.swift`
- Test: `ClydeTests/SessionTests.swift`

TDD — tests first.

- [ ] **Step 1: Write the failing tests**

Append to `ClydeTests/SessionTests.swift` inside the `SessionTests` class:

```swift
    // MARK: - ActivePlan / activePlan

    func testActivePlanIsIncompleteWhenZeroTasks() {
        let plan = ActivePlan(taskCount: 0, doneCount: 0, startedAt: Date())
        XCTAssertFalse(plan.isComplete)
        XCTAssertEqual(plan.progress, 0.0)
    }

    func testActivePlanIsIncompleteWhenSomeDone() {
        let plan = ActivePlan(taskCount: 5, doneCount: 2, startedAt: Date())
        XCTAssertFalse(plan.isComplete)
        XCTAssertEqual(plan.progress, 0.4, accuracy: 0.001)
    }

    func testActivePlanIsCompleteWhenAllDone() {
        let plan = ActivePlan(taskCount: 5, doneCount: 5, startedAt: Date())
        XCTAssertTrue(plan.isComplete)
        XCTAssertEqual(plan.progress, 1.0)
    }

    func testActivePlanProgressClampsOnOverflow() {
        // Defensive: a runaway TaskCompleted shouldn't push progress past 100%.
        let plan = ActivePlan(taskCount: 5, doneCount: 6, startedAt: Date())
        XCTAssertTrue(plan.isComplete)
        XCTAssertEqual(plan.progress, 1.0)
    }

    func testSessionActivePlanDefaultsToNil() {
        let session = Session(pid: 123, workingDirectory: "/tmp")
        XCTAssertNil(session.activePlan)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

```
swift test --filter SessionTests
```

Expected: 5 new tests fail with "Cannot find 'ActivePlan' in scope" / "no member 'activePlan'".

- [ ] **Step 3: Add `ActivePlan` and `Session.activePlan`**

In `Clyde/Models/Session.swift`, add the `ActivePlan` struct just below the existing `ActiveTool` struct (top of the file, between the model types and the `Session` struct):

```swift
struct ActivePlan: Equatable {
    /// Number of TaskCreated events seen for the current session run
    /// (starts at 0, increments by 1 per event). Reset only on
    /// SessionEnd or a manual session reset.
    let taskCount: Int
    /// Number of TaskCompleted events seen since the first TaskCreated
    /// in the current run. Bounded above by `taskCount` for display
    /// purposes via `progress` clamping.
    let doneCount: Int
    /// Wall-clock time the first TaskCreated event fired. Held across
    /// turns so a multi-turn plan-then-execute keeps the same start.
    let startedAt: Date

    /// True when the badge should switch to the green ✓ rendering.
    var isComplete: Bool { taskCount > 0 && doneCount >= taskCount }

    /// 0.0…1.0 fill ratio for the progress bar. Clamped so
    /// `doneCount > taskCount` (defensive — Claude shouldn't fire
    /// extra TaskCompleted events but if it does we don't overflow).
    var progress: Double {
        guard taskCount > 0 else { return 0 }
        return Double(min(doneCount, taskCount)) / Double(taskCount)
    }
}
```

Inside the `Session` struct, add the field next to `activeTool`:

```swift
    /// Non-nil while a plan-then-execute run is in progress. Populated
    /// by ProcessMonitor from -plan marker files written by the
    /// TaskCreated / TaskCompleted hook events. Cleared on SessionEnd
    /// or manual session reset.
    var activePlan: ActivePlan? = nil
```

- [ ] **Step 4: Run tests to verify they pass**

```
swift test --filter SessionTests
```

Expected: all SessionTests pass (existing 11 + new 5 = 16).

- [ ] **Step 5: Run the full suite**

```
swift test
```

Expected: full suite passes (~75 tests).

- [ ] **Step 6: Commit**

```bash
git add Clyde/Models/Session.swift ClydeTests/SessionTests.swift
git commit -m "feat(session): add ActivePlan model"
```

---

## Task 3: `ProcessMonitor.refreshHookPlans()` + wiring

**Files:**
- Modify: `Clyde/Services/ProcessMonitor.swift`
- Test: `ClydeTests/ProcessMonitorTests.swift`

TDD — tests first.

- [ ] **Step 1: Add the test helper**

At the top of `ClydeTests/ProcessMonitorTests.swift`, alongside `writeBusyFile` / `writeToolFile`, add:

```swift
    /// Writes a `-plan` marker the way TaskCreated/TaskCompleted hook
    /// would (after read-modify-write). Same PID semantics as
    /// `writeInfoFile` (uses the current process PID so kill(pid, 0)
    /// succeeds in tests).
    private func writePlanFile(
        in dir: URL,
        sessionId: String,
        taskCount: Int,
        doneCount: Int,
        startedAt: TimeInterval = Date().timeIntervalSince1970,
        pid: pid_t = getpid()
    ) {
        let body = #"{"session_id":"\#(sessionId)","pid":\#(pid),"task_count":\#(taskCount),"done_count":\#(doneCount),"started_at":\#(Int(startedAt))}"#
        let url = dir.appendingPathComponent("\(sessionId)-plan")
        try? body.write(to: url, atomically: true, encoding: .utf8)
    }
```

- [ ] **Step 2: Write the failing tests**

Append to `ClydeTests/ProcessMonitorTests.swift` inside the class:

```swift
    func testActivePlanIsPopulatedFromPlanFile() async {
        let dir = tempStateDir()
        let sid = UUID().uuidString
        _ = writeInfoFile(in: dir, sessionId: sid)
        let started = Date().timeIntervalSince1970 - 30
        writePlanFile(in: dir, sessionId: sid, taskCount: 5, doneCount: 2, startedAt: started)

        let monitor = ProcessMonitor(
            shell: emptyShell(),
            pollingInterval: 1,
            stateDir: dir,
            isLiveClaudeProcessCheck: { _ in true }
        )
        await monitor.poll()

        XCTAssertEqual(monitor.sessions.count, 1)
        let plan = monitor.sessions[0].activePlan
        XCTAssertEqual(plan?.taskCount, 5)
        XCTAssertEqual(plan?.doneCount, 2)
        XCTAssertEqual(plan?.startedAt.timeIntervalSince1970, started, accuracy: 1)
    }

    func testActivePlanClearsWhenFileRemoved() async {
        let dir = tempStateDir()
        let sid = UUID().uuidString
        _ = writeInfoFile(in: dir, sessionId: sid)
        writePlanFile(in: dir, sessionId: sid, taskCount: 3, doneCount: 1)

        let monitor = ProcessMonitor(
            shell: emptyShell(),
            pollingInterval: 1,
            stateDir: dir,
            isLiveClaudeProcessCheck: { _ in true }
        )
        await monitor.poll()
        XCTAssertNotNil(monitor.sessions.first?.activePlan)

        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(sid)-plan"))
        await monitor.poll()
        XCTAssertNil(monitor.sessions.first?.activePlan)
    }

    func testActivePlanUpdatesAfterRewrite() async {
        let dir = tempStateDir()
        let sid = UUID().uuidString
        _ = writeInfoFile(in: dir, sessionId: sid)
        writePlanFile(in: dir, sessionId: sid, taskCount: 5, doneCount: 1)

        let monitor = ProcessMonitor(
            shell: emptyShell(),
            pollingInterval: 1,
            stateDir: dir,
            isLiveClaudeProcessCheck: { _ in true }
        )
        await monitor.poll()
        XCTAssertEqual(monitor.sessions.first?.activePlan?.doneCount, 1)

        // Simulate the hook re-writing the file with an incremented done_count.
        writePlanFile(in: dir, sessionId: sid, taskCount: 5, doneCount: 3)
        await monitor.poll()
        XCTAssertEqual(monitor.sessions.first?.activePlan?.doneCount, 3)
        XCTAssertEqual(monitor.sessions.first?.activePlan?.taskCount, 5)
    }

    func testPlanFileIsRemovedWhenPIDIsDead() async {
        let dir = tempStateDir()
        let sid = UUID().uuidString
        _ = writeInfoFile(in: dir, sessionId: sid)
        // Write -plan with a PID that almost certainly doesn't exist.
        let body = #"{"session_id":"\#(sid)","pid":999999,"task_count":3,"done_count":1,"started_at":0}"#
        let url = dir.appendingPathComponent("\(sid)-plan")
        try? body.write(to: url, atomically: true, encoding: .utf8)

        let monitor = ProcessMonitor(
            shell: emptyShell(),
            pollingInterval: 1,
            stateDir: dir,
            isLiveClaudeProcessCheck: { _ in true }
        )
        await monitor.poll()

        XCTAssertNil(monitor.sessions.first?.activePlan)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testMalformedPlanFileIsRemoved() async {
        let dir = tempStateDir()
        let sid = UUID().uuidString
        _ = writeInfoFile(in: dir, sessionId: sid)
        let url = dir.appendingPathComponent("\(sid)-plan")
        try? "not json".write(to: url, atomically: true, encoding: .utf8)

        let monitor = ProcessMonitor(
            shell: emptyShell(),
            pollingInterval: 1,
            stateDir: dir,
            isLiveClaudeProcessCheck: { _ in true }
        )
        await monitor.poll()

        XCTAssertNil(monitor.sessions.first?.activePlan)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
```

- [ ] **Step 3: Run tests to verify they fail**

```
swift test --filter ProcessMonitorTests
```

Expected: 5 new tests fail.

- [ ] **Step 4: Add `hookPlanByPID` and `refreshHookPlans()`**

In `Clyde/Services/ProcessMonitor.swift`, just below the `hookToolByPID` declaration (~line 67), add:

```swift
    /// Active plan progress per PID, populated from `-plan` marker
    /// files written by TaskCreated / TaskCompleted. Cleared only on
    /// SessionEnd or a manual session reset; persists across Stop /
    /// UserPromptSubmit so a multi-turn plan keeps tracking.
    private var hookPlanByPID: [pid_t: ActivePlan] = [:]
```

After the `refreshHookTools()` method (find it by name — the file is ~770 lines now, line numbers in this plan are approximate), add:

```swift
    /// Reads `-plan` marker files written by the TaskCreated /
    /// TaskCompleted hooks. Returns true if the dictionary changed.
    @discardableResult
    private func refreshHookPlans() -> Bool {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: stateDir, includingPropertiesForKeys: nil
        ) else {
            let changed = !hookPlanByPID.isEmpty
            if changed { hookPlanByPID = [:] }
            return changed
        }
        var plans: [pid_t: ActivePlan] = [:]
        for file in files where file.lastPathComponent.hasSuffix("-plan") {
            guard let data = try? Data(contentsOf: file),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pidValue = json["pid"] as? Int,
                  let taskCount = json["task_count"] as? Int,
                  let doneCount = json["done_count"] as? Int,
                  let startedAt = json["started_at"] as? Int else {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            let pid = pid_t(pidValue)
            if kill(pid, 0) != 0 {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            plans[pid] = ActivePlan(
                taskCount: taskCount,
                doneCount: doneCount,
                startedAt: Date(timeIntervalSince1970: TimeInterval(startedAt))
            )
        }
        let changed = plans != hookPlanByPID
        if changed { hookPlanByPID = plans }
        return changed
    }
```

- [ ] **Step 5: Wire `refreshHookPlans` into `poll()`**

In `poll()`, alongside the other refresh calls (after `refreshHookTools()`):

```swift
        refreshHookBusyPIDs()
        refreshHookErrors()
        refreshHookSubagents()
        refreshHookTools()
        refreshHookPlans()
```

- [ ] **Step 6: Wire into `pollHookState()` for the fast path**

In `pollHookState()`, add `planChanged` tracking and include it in BOTH `if` guards. Replace the relevant section (the part starting with `let busyChanged` and ending with the second `if` block that posts `Task { await self.poll() }`) with:

```swift
        let busyChanged = refreshHookBusyPIDs()
        let errorChanged = refreshHookErrors()
        let subagentChanged = refreshHookSubagents()
        let toolChanged = refreshHookTools()
        let planChanged = refreshHookPlans()

        // Detect session arrivals/departures via -info file presence so a new
        // session is reflected in the UI immediately instead of waiting for
        // the next main poll tick.
        let infoFilenames: Set<String>
        if let files = try? FileManager.default.contentsOfDirectory(
            at: stateDir, includingPropertiesForKeys: nil
        ) {
            infoFilenames = Set(files.lazy
                .map(\.lastPathComponent)
                .filter { $0.hasSuffix("-info") })
        } else {
            infoFilenames = []
        }
        let infoChanged = infoFilenames != lastInfoFilenames
        lastInfoFilenames = infoFilenames

        // Fast path: when only the busy state of an EXISTING session
        // flipped (no new info files = no new sessions), reflect that
        // on the in-memory sessions array immediately, synchronously.
        // This avoids waiting on the full `poll()` cycle (which shells
        // out to pgrep — ~50–200 ms of latency before the UI catches
        // up to the hook event).
        if busyChanged || errorChanged || subagentChanged || toolChanged || planChanged {
            applyBusyStateToSessions()
        }

        if busyChanged || infoChanged || errorChanged || subagentChanged || toolChanged || planChanged {
            Task { await self.poll() }
        }
```

- [ ] **Step 7: Apply plan state in `applyBusyStateToSessions()`**

Inside the `for index in updated.indices where !updated[index].isGhost` loop, after the tool block (find by `let newTool = hookToolByPID[pid]`), add:

```swift
            let newPlan = hookPlanByPID[pid]
            if updated[index].activePlan != newPlan {
                updated[index].activePlan = newPlan
                changed = true
            }
```

- [ ] **Step 8: Apply plan state in all three branches of `updatedSession(pid:newStatus:)`**

In path 1 (live row), right after `existing.activeTool = hookToolByPID[pid]`:

```swift
            existing.activePlan = hookPlanByPID[pid]
```

In path 2 (revival via sessionId), right after the corresponding `revived.activeTool = hookToolByPID[pid]`:

```swift
            revived.activePlan = hookPlanByPID[pid]
```

In path 3 (brand-new session), right after the corresponding `fresh.activeTool = hookToolByPID[pid]` (or wherever the v17 implementation placed it — the field assignment goes in the same spot):

```swift
            fresh.activePlan = hookPlanByPID[pid]
```

If the brand-new branch in your file uses a `Session(pid:..., workingDirectory:..., status:..., sessionId:...)` constructor and then assigns `subagentType` / `activeTool` separately, follow that same pattern for `activePlan`. Don't add a constructor argument.

- [ ] **Step 9: Run the new tests**

```
swift test --filter ProcessMonitorTests
```

Expected: all `ProcessMonitorTests` pass (existing + 5 new).

- [ ] **Step 10: Run the full suite**

```
swift test
```

Expected: ~80 tests pass, 0 failures.

- [ ] **Step 11: Commit**

```bash
git add Clyde/Services/ProcessMonitor.swift ClydeTests/ProcessMonitorTests.swift
git commit -m "feat(monitor): ingest -plan marker into Session.activePlan"
```

---

## Task 4: `PlanBadge` view in `SessionRow`

**Files:**
- Modify: `Clyde/Views/Components/SessionRow.swift`

No automated test layer for SwiftUI views in this codebase — verification is by `swift build` + `swift test` + visual smoke after the rest of the wiring lands.

- [ ] **Step 1: Add the `PlanBadge` private view**

At the bottom of `SessionRow.swift` (after `formatDuration` from the v17 implementation, before the `// MARK: - Session Status Indicator` block), add:

```swift
// MARK: - Plan Progress Badge

/// Inline badge that surfaces TaskCreated / TaskCompleted progress on
/// the session row's name line. Purple while in progress, green ✓ on
/// completion. The fixed-width 24pt progress bar prevents the badge
/// from changing width as digit counts grow (1/9 → 9/9 stays the same).
private struct PlanBadge: View {
    let plan: ActivePlan

    var body: some View {
        HStack(spacing: 4) {
            Text(plan.isComplete ? "✓" : "📋")
                .font(.system(size: 9))
            Text("\(plan.doneCount)/\(plan.taskCount)")
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .monospacedDigit()
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(accent.opacity(0.25))
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(accent)
                    .frame(width: 24 * plan.progress)
            }
            .frame(width: 24, height: 3)
        }
        .foregroundStyle(accent)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(accent.opacity(0.12))
        .clipShape(Capsule())
        .animation(.easeInOut(duration: 0.25), value: plan.doneCount)
        .animation(.easeInOut(duration: 0.25), value: plan.isComplete)
    }

    private var accent: Color {
        plan.isComplete
            ? Color(red: 0.47, green: 0.78, blue: 0.55)   // soft green
            : Color(red: 0.71, green: 0.55, blue: 0.86)   // soft purple
    }
}
```

- [ ] **Step 2: Place the badge inline in the session name HStack**

Find the existing name-and-pencil HStack inside the row body (around the `Text(session.displayName)` block — the one that lives inside the `else` branch of the `isEditing` if). It currently looks roughly like:

```swift
                    HStack(spacing: 6) {
                        Text(session.displayName)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white)
                            .lineLimit(1)

                        if let suffix = disambiguator {
                            Text(suffix)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Color(white: 0.35))
                        }

                        if isHovered {
                            Button(action: {
                                editName = session.customName ?? ""
                                isEditing = true
                            }) {
                                Image(systemName: "pencil")
                                    ...
                            }
                            .buttonStyle(.plain)
                            .transition(.opacity)
                        }
                    }
```

Insert the `PlanBadge` between `Text(session.displayName)` and the `disambiguator` block:

```swift
                    HStack(spacing: 6) {
                        Text(session.displayName)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white)
                            .lineLimit(1)

                        if let plan = session.activePlan {
                            PlanBadge(plan: plan)
                        }

                        if let suffix = disambiguator {
                            Text(suffix)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Color(white: 0.35))
                        }

                        if isHovered {
                            // ... existing pencil button, untouched ...
                        }
                    }
```

- [ ] **Step 3: Build to confirm no compile errors**

```
swift build
```

Expected: clean build.

- [ ] **Step 4: Run the full test suite**

```
swift test
```

Expected: still passes (~80 tests). The view change isn't directly test-covered, but this catches inadvertent type breakage.

- [ ] **Step 5: Commit**

```bash
git add Clyde/Views/Components/SessionRow.swift
git commit -m "feat(ui): show plan progress badge on session row"
```

---

## Task 5: Extend `resetSession` to clear `-plan` (and the other state files)

**Files:**
- Modify: `Clyde/ViewModels/AppViewModel.swift:396-409`
- Test: `ClydeTests/AppViewModelTests.swift`

The current `resetSession` only removes `-info` and `-busy`, not the `-error` / `-subagent` / `-tool` / `-plan` files. The spec for the v0.3.0 plan-progress feature designates `resetSession` as the manual escape hatch for stale plan state, and the same gap also applies retroactively to `-tool` / `-subagent` / `-error`. Fix all four at once.

TDD — test first.

- [ ] **Step 1: Inspect the existing test file**

```
grep -n "resetSession\|class AppViewModelTests" /Users/m.klosinski/_Projects/clyde/ClydeTests/AppViewModelTests.swift | head
```

If `resetSession` already has tests, append the new ones to the same area. If not, you'll be adding the first test for it. Either way, the test below stands on its own.

- [ ] **Step 2: Write the failing test**

`AppPaths.homeOverride` exists specifically for tests — set it to a temp dir at the start of the test so `resetSession` operates against the throwaway tree instead of the user's real `~/.clyde/`. Match the actor-isolation conventions used by the surrounding tests (most tests in the file are `@MainActor` because `AppViewModel` is); copy the existing instantiation pattern verbatim.

Append to `ClydeTests/AppViewModelTests.swift` inside the test class:

```swift
    @MainActor
    func testResetSessionRemovesAllHookStateFilesForSessionId() throws {
        // Redirect AppPaths to a throwaway tempdir so we don't touch
        // the user's real ~/.clyde/. AppPaths.homeOverride is the
        // codebase's documented test seam for exactly this purpose.
        let tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("clyde-resetsession-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
        let previousOverride = AppPaths.homeOverride
        AppPaths.homeOverride = tempHome
        defer {
            AppPaths.homeOverride = previousOverride
            try? FileManager.default.removeItem(at: tempHome)
        }

        try FileManager.default.createDirectory(at: AppPaths.stateDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: AppPaths.eventsDir, withIntermediateDirectories: true)

        let sid = UUID().uuidString
        let suffixes = ["info", "busy", "error", "subagent", "tool", "plan"]
        for suffix in suffixes {
            try "{}".write(
                to: AppPaths.stateDir.appendingPathComponent("\(sid)-\(suffix)"),
                atomically: true,
                encoding: .utf8
            )
        }
        try "{}".write(
            to: AppPaths.eventsDir.appendingPathComponent("\(sid).json"),
            atomically: true,
            encoding: .utf8
        )

        let viewModel = AppViewModel()
        let session = Session(pid: 99999, workingDirectory: "/tmp", sessionId: sid)
        viewModel.resetSession(session)

        for suffix in suffixes {
            let url = AppPaths.stateDir.appendingPathComponent("\(sid)-\(suffix)")
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: url.path),
                "Expected \(url.lastPathComponent) to be removed by resetSession"
            )
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: AppPaths.eventsDir.appendingPathComponent("\(sid).json").path
            )
        )
    }
```

If `AppViewModel()` zero-arg init isn't available (check the existing tests in the file for the canonical instantiation), use the pattern those tests use. If they wrap creation in `MainActor.run` or similar, do the same here.

- [ ] **Step 3: Run the test to verify it fails**

```
swift test --filter AppViewModelTests
```

Expected: the new test fails with `Expected <sid>-error to be removed by resetSession` (or one of the suffixes other than `info`/`busy`).

- [ ] **Step 4: Extend `resetSession` to remove all state files**

In `Clyde/ViewModels/AppViewModel.swift`, replace the existing `resetSession(_:)` method (lines ~396-409) with:

```swift
    /// Wipe state for a single session: every hook-written marker
    /// (info / busy / error / subagent / tool / plan) plus any pending
    /// attention event. Used by the per-session reset action in the
    /// expanded view's context menu — the manual escape hatch when a
    /// marker (typically -plan) wedges in a state that no future hook
    /// event will resolve.
    func resetSession(_ session: Session) {
        if let sid = session.sessionId {
            let suffixes = ["info", "busy", "error", "subagent", "tool", "plan"]
            for suffix in suffixes {
                try? FileManager.default.removeItem(
                    at: AppPaths.stateDir.appendingPathComponent("\(sid)-\(suffix)")
                )
            }
            try? FileManager.default.removeItem(
                at: AppPaths.eventsDir.appendingPathComponent("\(sid).json")
            )
        }
        // Also clear the in-memory attention flag for this PID, in case
        // there were legacy events keyed by something else.
        attentionMonitor.clearAttention(pid: session.pid)
        ClydeLog.general.info("Session \(session.pid, privacy: .public) state cleared by user")
        Task { await processMonitor.poll() }
    }
```

- [ ] **Step 5: Run the test to verify it passes**

```
swift test --filter AppViewModelTests
```

Expected: PASS.

- [ ] **Step 6: Run the full suite**

```
swift test
```

Expected: ~81 tests pass.

- [ ] **Step 7: Commit**

```bash
git add Clyde/ViewModels/AppViewModel.swift ClydeTests/AppViewModelTests.swift
git commit -m "fix(reset): clear all hook state files including -plan on session reset"
```

---

## Task 6: Register `TaskCreated` / `TaskCompleted` in `HookInstaller` and bump version

**Files:**
- Modify: `Clyde/Services/HookInstaller.swift`

This is the activation step. Bumping `currentScriptVersion` triggers auto-reinstall of the v18 hook on next launch; registering the events in `~/.claude/settings.json` makes Claude Code actually deliver them.

- [ ] **Step 1: Add the two events to `registeredHookEvents`**

Find the array literal (around line 96) that currently ends at `"PostCompact",` (or similar — Task 1 of the previous feature added `"PostToolUse"`). Append `"TaskCreated"` and `"TaskCompleted"` before the closing `]`:

```swift
    static let registeredHookEvents = [
        "SessionStart",
        "SessionEnd",
        "UserPromptSubmit",
        "Stop",
        "StopFailure",
        "PermissionRequest",
        "PermissionDenied",
        "PreToolUse",
        "PostToolUse",
        "PostToolUseFailure",
        // v15 additions:
        "CwdChanged",
        "Elicitation",
        "ElicitationResult",
        "SubagentStart",
        "SubagentStop",
        "Notification",
        "PreCompact",
        "PostCompact",
        // v18 additions:
        "TaskCreated",
        "TaskCompleted",
```

(Preserve whatever closing pattern the existing array uses.)

- [ ] **Step 2: Update the docstring**

In the docblock above `registeredHookEvents` (lines ~85-95), append two lines describing the new events:

```swift
    /// - `TaskCreated`: Claude called the TaskCreate tool → bump
    ///                 task_count in `state/<sid>-plan` (or initialize)
    /// - `TaskCompleted`: a task was marked done → bump done_count in
    ///                 `state/<sid>-plan` (no-op if the file is missing)
```

- [ ] **Step 3: Bump `currentScriptVersion`**

```swift
    static let currentScriptVersion = 18
```

(Was `17`.)

- [ ] **Step 4: Run the full suite**

```
swift test
```

Expected: full suite passes. `HookInstallerTests.testHealthCheckDetectsOutdatedScript` should pass — it reads `currentScriptVersion` dynamically when computing the substitution, so the bump alone doesn't break it.

If a test pinned the constant value to 17, update its expected value too.

- [ ] **Step 5: Commit**

```bash
git add Clyde/Services/HookInstaller.swift
git commit -m "chore(hook): register TaskCreated/TaskCompleted and bump to v18"
```

---

## Task 7: ROADMAP + CHANGELOG

**Files:**
- Modify: `ROADMAP.md` (the v0.3.0 phase, second bullet)
- Modify: `CHANGELOG.md` (`## [Unreleased]` section)

- [ ] **Step 1: Tick the ROADMAP item**

Replace the `[ ] Subscribe to TaskCreated hook event — …` line under `## Phase: v0.3.0 — Richer session telemetry` with a one-line summary (per CLAUDE.md convention — original spec text moves to git history):

```markdown
- [x] Subscribe to TaskCreated hook event — `clyde-hook` v18 maintains `state/<sid>-plan` (`task_count` + `done_count`) via read-modify-write on `TaskCreated` and `TaskCompleted`, cleared on `SessionEnd`. `SessionRow` shows an inline `PlanBadge` (purple while in progress, green ✓ on completion) with a 24×3 px progress bar; cross-turn persistent (no clear on `Stop`). Manual escape hatch via context-menu "Reset session state", which now clears every hook marker (`-info`/`-busy`/`-error`/`-subagent`/`-tool`/`-plan`) plus any pending event !lo #hooks #ux
```

- [ ] **Step 2: Add CHANGELOG bullet**

Under `## [Unreleased]` in `CHANGELOG.md`, append a bullet (no hard-wrap, per CLAUDE.md — single long line):

```markdown
- **Plan-then-execute progress on the session row.** When Claude maps out tasks via `TaskCreate` (the planning tool), Clyde shows a small `📋 N/M` badge with a progress bar next to the session name. The bar fills as Claude completes tasks and switches to a green `✓ N/N` when the plan is done. The badge persists across turns, so a long plan that Claude works on over several "continue" prompts keeps tracking — no flicker, no reset.
```

- [ ] **Step 3: Commit**

```bash
git add ROADMAP.md CHANGELOG.md
git commit -m "docs: tick v0.3.0 plan-badge item, add CHANGELOG entry"
```

---

## Verification Checklist

Before declaring the feature done:

- [ ] `swift test` passes (full suite, ~81 tests).
- [ ] Hook smoke test from Task 1 Step 5 passes all 7 checks.
- [ ] `Clyde/Services/HookInstaller.swift`: `currentScriptVersion == 18` AND `registeredHookEvents` contains both `TaskCreated` and `TaskCompleted`.
- [ ] `Clyde/Resources/clyde-hook.sh`: `# clyde-hook-version: 18` matches.
- [ ] Visual smoke test (run with `swift run Clyde`):
  - Make a Claude session use TaskCreate to plan something with multiple steps.
  - Confirm the badge appears next to the session name as `📋 N/M` and updates as TaskCompleted fires.
  - Confirm the bar fills smoothly (animation visible).
  - Confirm the badge switches to `✓ N/N` in green when all tasks complete.
  - Confirm the badge persists if Claude `Stop`s and the user issues a "continue" prompt.
  - Confirm the badge disappears on `/clear` or session exit.
  - Confirm right-click "Reset session state" instantly clears the badge.
- [ ] No new files created (sanity check — all changes fit existing files).
- [ ] Git log shows ~7 focused commits with Conventional Commit subjects, no `Co-Authored-By: Claude` and no `Generated with Claude Code` footers.
