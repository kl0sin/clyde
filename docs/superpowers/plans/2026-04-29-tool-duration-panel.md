# Tool + Duration Panel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Clyde's expanded panel show *what* Claude is currently doing (tool name + summary + live duration) on the second line of each session row, with a smooth slide animation as the tool indicator appears and disappears.

**Architecture:** New per-session state file `~/.clyde/state/<sid>-tool` written by `clyde-hook.sh` on `PreToolUse` and removed on every "tool finished" event (`PostToolUse`, `PostToolUseFailure`, `Stop`, `SessionEnd`). `ProcessMonitor` mirrors the existing `-subagent` plumbing one-for-one to ingest the file. `SessionRow` swaps the path text for an animated `ZStack` containing a `TimelineView`-driven duration string.

**Tech Stack:** Swift 5.9, SwiftUI (macOS 13+), XCTest, bash 3.2 (system bash on macOS).

**Source spec:** `docs/superpowers/specs/2026-04-29-tool-duration-panel-design.md`

---

## File Structure

**Modify:**
- `Clyde/Resources/clyde-hook.sh` — bump version to 17, extract `tool_name` + per-tool summary on `PreToolUse`, write `-tool` JSON, clear it on `PostToolUse` / `PostToolUseFailure` / `Stop` / `SessionEnd`.
- `Clyde/Services/HookInstaller.swift` — bump `currentScriptVersion` from 16 to 17.
- `Clyde/Models/Session.swift` — add `ActiveTool` struct + `activeTool` field + `toolDisplayLabel` computed property.
- `Clyde/Services/ProcessMonitor.swift` — add `hookToolByPID` + `refreshHookTools()`, wire into `poll()`, `pollHookState()`, `applyBusyStateToSessions()`, `updatedSession()`.
- `Clyde/Views/Components/SessionRow.swift` — replace single-line path `Text` with animated `ZStack` (path or tool+duration), add `formatDuration` helper.
- `ClydeTests/SessionTests.swift` — add tests for `toolDisplayLabel`.
- `ClydeTests/ProcessMonitorTests.swift` — add `writeToolFile` helper + tests for `-tool` ingestion lifecycle.
- `ROADMAP.md` — tick off the v0.3.0 tool+duration item with one-line summary.
- `CHANGELOG.md` — add bullet under `## [Unreleased]`.

**No new files.** All work fits cleanly into existing files; no scope creep into new modules.

---

## Task 1: Hook script — extract tool field on PreToolUse, write `-tool`

**Files:**
- Modify: `Clyde/Resources/clyde-hook.sh` (whole file — multiple sections)

This task is hook-only. It writes the new state file but nothing in Clyde reads it yet. Do not bump `HookInstaller.currentScriptVersion` here — that goes in Task 2 so the hook self-installs only after Swift is ready.

- [ ] **Step 1: Add nested-field extraction helper**

After the existing `extract_field()` definition (currently ends around line 81) add:

```bash
# Extract a string from `tool_input.<key>` in the Claude hook payload.
# Mirrors extract_field's python3 + grep fallback strategy. Returns
# empty string when the key is missing, when tool_input isn't an
# object, or when the value isn't a string.
extract_tool_input_field() {
    local key=$1
    local value=""

    if command -v python3 >/dev/null 2>&1; then
        value=$(printf '%s' "$INPUT" | python3 -c "
import json, sys
try:
    d = json.loads(sys.stdin.read())
    ti = d.get('tool_input') or {}
    v = ti.get('$key', '')
    print(v if isinstance(v, str) else '')
except Exception:
    print('')
" 2>/dev/null) || value=""
    fi

    if [ -z "$value" ]; then
        # Pure-shell fallback. We can't reliably parse nested JSON
        # without a real parser, so we just look for the first
        # "key": "value" occurrence anywhere in the payload. Acceptable
        # because Claude's tool_input fields use distinct names
        # (file_path, command, pattern, url, query, subagent_type) that
        # don't collide with top-level payload keys.
        value=$(printf '%s' "$INPUT" \
            | tr -d '\n' \
            | grep -o "\"$key\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" \
            | head -n1 \
            | sed -E 's/.*"([^"]*)"$/\1/')
    fi

    printf '%s' "$value"
}

# Truncate $1 to at most $2 characters, appending an ellipsis if
# truncated. Pure shell, byte-counted (fine for ASCII summaries; the
# whitelisted fields below are all ASCII paths/commands/patterns).
truncate_summary() {
    local s=$1
    local max=$2
    if [ ${#s} -le "$max" ]; then
        printf '%s' "$s"
    else
        printf '%s…' "${s:0:$max}"
    fi
}

# Compute a short summary string for the active tool, based on
# tool_name. Empty for unknown / MCP / TodoWrite tools — Swift will
# render just the tool name in that case.
compute_tool_summary() {
    local tool=$1
    local raw=""
    case "$tool" in
        Edit|Write|Read|MultiEdit|NotebookEdit)
            raw=$(extract_tool_input_field file_path)
            # basename without forking
            printf '%s' "${raw##*/}"
            ;;
        Bash)
            raw=$(extract_tool_input_field command)
            # First line only — collapse any embedded newlines just in
            # case the grep fallback grabbed a multi-line value.
            raw=$(printf '%s' "$raw" | tr '\n' ' ' | head -c 200)
            truncate_summary "$raw" 40
            ;;
        Glob|Grep)
            raw=$(extract_tool_input_field pattern)
            truncate_summary "$raw" 40
            ;;
        Task)
            extract_tool_input_field subagent_type
            ;;
        WebFetch)
            raw=$(extract_tool_input_field url)
            # Extract host: drop scheme, then keep up to next slash.
            raw=${raw#*://}
            printf '%s' "${raw%%/*}"
            ;;
        WebSearch)
            raw=$(extract_tool_input_field query)
            truncate_summary "$raw" 40
            ;;
        *)
            # TodoWrite, MCP tools, and any future built-in fall through
            # to the empty-summary path. Swift renders just tool_name.
            printf ''
            ;;
    esac
}
```

- [ ] **Step 2: Hoist `tool_name` next to `SOURCE` extraction**

In the block that hoists `SOURCE` (currently around line 93), add `TOOL_NAME` extraction. Update so the file looks like:

```bash
# `source` only ships on SessionStart payloads…
SOURCE=""
if [ "$HOOK_EVENT" = "SessionStart" ]; then
    SOURCE=$(extract_field source)
fi

# `tool_name` ships on PreToolUse / PostToolUse / PostToolUseFailure
# payloads. Hoist it once so the case branches don't each call
# extract_field redundantly.
TOOL_NAME=""
case "$HOOK_EVENT" in
    PreToolUse|PostToolUse|PostToolUseFailure)
        TOOL_NAME=$(extract_field tool_name)
        ;;
esac
```

- [ ] **Step 3: Extend `PreToolUse` case to write `-tool` file**

Replace the existing `PreToolUse)` branch (currently ~lines 232-242) with:

```bash
    PreToolUse)
        # Tools can only run after permission was granted, so clear any
        # pending attention flag. The session stays busy via its marker.
        rm -f "$EVENTS_DIR/$KEY.json"
        # Touch the busy marker so its mtime tracks tool activity (used
        # for diagnostics / activity timeline). Clyde itself no longer
        # expires markers on staleness — they're sticky for as long as
        # the Claude process is alive — but keeping mtime current is
        # cheap and useful.
        [ -f "$STATE_DIR/$KEY-busy" ] && touch "$STATE_DIR/$KEY-busy"
        # Capture which tool is now running and a short summary of its
        # primary input field. Clyde renders this on the session row so
        # the user sees "Edit · SessionRow.swift" instead of just the
        # busy spinner. Empty TOOL_NAME would only happen for malformed
        # payloads — skip the write rather than producing a junk file.
        if [ -n "$TOOL_NAME" ]; then
            ESC_TOOL=$(printf '%s' "$TOOL_NAME" | sed 's/\\/\\\\/g; s/"/\\"/g')
            TOOL_SUMMARY=$(compute_tool_summary "$TOOL_NAME")
            ESC_SUMMARY=$(printf '%s' "$TOOL_SUMMARY" | sed 's/\\/\\\\/g; s/"/\\"/g')
            atomic_write "$STATE_DIR/$KEY-tool" \
                "{\"session_id\": \"$ESC_SID\", \"pid\": $CLAUDE_PID, \"tool_name\": \"$ESC_TOOL\", \"summary\": \"$ESC_SUMMARY\", \"started_at\": $TIMESTAMP}"
        fi
        ;;
```

- [ ] **Step 4: Add `PostToolUse` case + extend `PostToolUseFailure`, `Stop`, `SessionEnd`**

There is currently no `PostToolUse)` branch — add one. Extend the other three to also `rm -f` the `-tool` file.

`SessionEnd` (currently around line 171-173) — add `-tool` to the rm list:

```bash
    SessionEnd)
        rm -f "$STATE_DIR/$KEY-info" "$STATE_DIR/$KEY-busy" "$STATE_DIR/$KEY-error" "$STATE_DIR/$KEY-subagent" "$STATE_DIR/$KEY-tool" "$EVENTS_DIR/$KEY.json"
        ;;
```

`Stop` (currently around line 199-203) — add `-tool` to the rm list:

```bash
    Stop)
        # Clear busy, error, subagent, tool, and attention markers. Stop
        # means the turn is over — everything from that turn is resolved.
        rm -f "$STATE_DIR/$KEY-busy" "$STATE_DIR/$KEY-error" "$STATE_DIR/$KEY-subagent" "$STATE_DIR/$KEY-tool" "$EVENTS_DIR/$KEY.json"
        ;;
```

`PostToolUseFailure` (currently around line 217-231) — add an unconditional `-tool` removal at the end of the case:

```bash
    PostToolUseFailure)
        # A tool execution failed. The most important sub-case is the
        # user pressing Ctrl+C to interrupt — Claude Code reports that
        # via `is_interrupt: true` in the payload. When that flag is
        # set, the turn is effectively done and we drop the busy marker
        # immediately so Clyde reflects reality without waiting for the
        # mtime-staleness fallback (~2 min).
        #
        # For non-interrupt failures (command exited non-zero, etc.)
        # Claude usually keeps working and tries to recover, so we
        # leave the busy marker alone in that case.
        if printf '%s' "$INPUT" | grep -q '"is_interrupt"[[:space:]]*:[[:space:]]*true'; then
            rm -f "$STATE_DIR/$KEY-busy"
        fi
        # The tool call itself has terminated either way (interrupt or
        # error), so the active-tool indicator must clear.
        rm -f "$STATE_DIR/$KEY-tool"
        ;;
```

Add a brand-new `PostToolUse)` branch immediately before the `CwdChanged)` branch:

```bash
    PostToolUse)
        # Tool finished cleanly. Drop the active-tool indicator; the
        # session row will slide back to the project path until the
        # next PreToolUse fires.
        rm -f "$STATE_DIR/$KEY-tool"
        ;;
```

- [ ] **Step 5: Update header docs and bump hook version**

At the top of the file:

- Change `# clyde-hook-version: 16` → `# clyde-hook-version: 17`.
- In the `# Handled events:` block, update existing lines and add new ones:

```
#   SessionEnd          → removes info + busy + error + subagent + tool + event
#   Stop                → removes busy + error + subagent + tool + event marker
#   PreToolUse          → clears event file + refreshes busy mtime + writes -tool
#   PostToolUse         → removes -tool marker
#   PostToolUseFailure  → removes -tool marker; removes busy IF is_interrupt=true
```

(Keep the rest of the block as-is.)

- [ ] **Step 6: Smoke-test the hook against fake payloads**

The hook's `find_claude_pid` walks the PPID chain looking for a process named `claude` and exits early (no state writes) if none is found. To smoke-test without a real Claude session, wrap the call so the parent shell is renamed to `claude` via `exec -a`. Run from the repo root:

```bash
TMPHOME=$(mktemp -d)
HOOK=$(pwd)/Clyde/Resources/clyde-hook.sh

# Fire the hook with a fake "claude"-named parent so find_claude_pid
# succeeds and the case branches actually run. Each invocation is its
# own subshell so the renamed exec doesn't replace our test shell.
fire_hook() {
    ( HOME=$TMPHOME exec -a claude bash -c "bash '$HOOK'" <<<"$1" )
}

# 1. PreToolUse(Edit) writes -tool with basename
fire_hook '{"hook_event_name":"PreToolUse","session_id":"11111111-1111-1111-1111-111111111111","cwd":"/tmp","tool_name":"Edit","tool_input":{"file_path":"/Users/me/Projects/clyde/SessionRow.swift"}}'
cat "$TMPHOME/.clyde/state/11111111-1111-1111-1111-111111111111-tool"
# Expect: {"session_id": "...", "pid": ..., "tool_name": "Edit", "summary": "SessionRow.swift", "started_at": ...}

# 2. PostToolUse clears it
fire_hook '{"hook_event_name":"PostToolUse","session_id":"11111111-1111-1111-1111-111111111111","cwd":"/tmp","tool_name":"Edit"}'
ls "$TMPHOME/.clyde/state/" | grep -- '-tool' && echo "FAIL: -tool still present" || echo "OK: cleared"

# 3. PreToolUse(Bash) truncates long commands
fire_hook '{"hook_event_name":"PreToolUse","session_id":"22222222-2222-2222-2222-222222222222","cwd":"/tmp","tool_name":"Bash","tool_input":{"command":"swift test --filter ProcessMonitorTests --enable-code-coverage --parallel"}}'
cat "$TMPHOME/.clyde/state/22222222-2222-2222-2222-222222222222-tool"
# Expect summary truncated to 40 chars + ellipsis: "swift test --filter ProcessMonitorTests …"

# 4. WebFetch extracts host
fire_hook '{"hook_event_name":"PreToolUse","session_id":"33333333-3333-3333-3333-333333333333","cwd":"/tmp","tool_name":"WebFetch","tool_input":{"url":"https://github.com/some/repo/blob/main/README.md"}}'
cat "$TMPHOME/.clyde/state/33333333-3333-3333-3333-333333333333-tool"
# Expect summary: "github.com"

# 5. Unknown tool → empty summary, but file still written
fire_hook '{"hook_event_name":"PreToolUse","session_id":"44444444-4444-4444-4444-444444444444","cwd":"/tmp","tool_name":"mcp__github__create_issue","tool_input":{"title":"test"}}'
cat "$TMPHOME/.clyde/state/44444444-4444-4444-4444-444444444444-tool"
# Expect summary: "" (and tool_name preserved verbatim)

# 6. Stop clears both -busy and -tool
fire_hook '{"hook_event_name":"UserPromptSubmit","session_id":"55555555-5555-5555-5555-555555555555","cwd":"/tmp"}'
fire_hook '{"hook_event_name":"PreToolUse","session_id":"55555555-5555-5555-5555-555555555555","cwd":"/tmp","tool_name":"Edit","tool_input":{"file_path":"/foo.swift"}}'
fire_hook '{"hook_event_name":"Stop","session_id":"55555555-5555-5555-5555-555555555555","cwd":"/tmp"}'
ls "$TMPHOME/.clyde/state/" | grep -E -- '-(tool|busy|error|subagent)$' && echo "FAIL: leftover marker" || echo "OK: cleared"

rm -rf "$TMPHOME"
```

If any step shows FAIL or unexpected `summary`, fix the script before continuing.

All six checks must print the expected output. If any fails, fix the script before continuing.

- [ ] **Step 7: Commit**

```bash
git add Clyde/Resources/clyde-hook.sh
git commit -m "feat(hook): write -tool state file with tool_name + summary"
```

---

## Task 2: Bump `HookInstaller.currentScriptVersion`

**Files:**
- Modify: `Clyde/Services/HookInstaller.swift:67`

This is intentionally split from Task 1 — bumping the version forces auto-reinstall on next launch, so the Swift side must already understand the new file format before this lands. (In this plan that ordering is enforced because Task 3 introduces the model and Task 4 wires up reading; we bump after both. So this task actually moves to **after Task 4**.)

> **Note to the implementer:** **Skip this task for now.** It runs as Task 6 below, after the Swift changes are in place. Listed here only because conceptually it pairs with Task 1.

---

## Task 3: `Session.ActiveTool` model + `toolDisplayLabel`

**Files:**
- Modify: `Clyde/Models/Session.swift`
- Test: `ClydeTests/SessionTests.swift`

- [ ] **Step 1: Write the failing tests**

Append to `ClydeTests/SessionTests.swift`:

```swift
    // MARK: - activeTool / toolDisplayLabel

    func testToolDisplayLabelIsNilWhenNoActiveTool() {
        let session = Session(pid: 123, workingDirectory: "/tmp")
        XCTAssertNil(session.toolDisplayLabel)
    }

    func testToolDisplayLabelCombinesNameAndSummary() {
        var session = Session(pid: 123, workingDirectory: "/tmp")
        session.activeTool = ActiveTool(
            toolName: "Edit",
            summary: "SessionRow.swift",
            startedAt: Date()
        )
        XCTAssertEqual(session.toolDisplayLabel, "Edit · SessionRow.swift")
    }

    func testToolDisplayLabelOmitsSeparatorWhenSummaryEmpty() {
        var session = Session(pid: 123, workingDirectory: "/tmp")
        session.activeTool = ActiveTool(
            toolName: "TodoWrite",
            summary: "",
            startedAt: Date()
        )
        XCTAssertEqual(session.toolDisplayLabel, "TodoWrite")
    }
```

- [ ] **Step 2: Run tests to verify they fail**

```
swift test --filter SessionTests
```

Expected: 3 new tests fail with "Cannot find 'ActiveTool' in scope" / "Value of type 'Session' has no member 'activeTool'".

- [ ] **Step 3: Add the `ActiveTool` struct + `activeTool` field + `toolDisplayLabel`**

In `Clyde/Models/Session.swift`, add at the top of the file (just after the `SessionStatus` enum):

```swift
struct ActiveTool: Equatable {
    /// Verbatim tool_name from Claude's hook payload (e.g. "Edit",
    /// "Bash", "mcp__github__create_issue"). Never empty — the hook
    /// skips writing the -tool file when tool_name is missing.
    let toolName: String
    /// Short, display-ready summary of the tool's primary input
    /// (basename for Edit/Write, host for WebFetch, etc.). Empty for
    /// unknown tools — `toolDisplayLabel` falls back to just the name.
    let summary: String
    /// Wall-clock time the PreToolUse hook fired. Used by SessionRow's
    /// TimelineView to render a live-ticking duration string.
    let startedAt: Date
}
```

Inside the `Session` struct, add the field next to `subagentType`:

```swift
    /// Non-nil while a built-in or MCP tool call is in flight. The hook
    /// writes this on PreToolUse and clears it on PostToolUse / Stop /
    /// SessionEnd, so it tracks the same per-tool-call lifecycle.
    var activeTool: ActiveTool? = nil
```

And add the computed property near `errorDisplayText`:

```swift
    /// Single-line label rendered on the session row's second line
    /// while a tool is running. Returns `nil` when the session is idle
    /// or busy-but-not-in-a-tool — callers fall back to the project
    /// path in that case.
    var toolDisplayLabel: String? {
        guard let tool = activeTool else { return nil }
        return tool.summary.isEmpty ? tool.toolName : "\(tool.toolName) · \(tool.summary)"
    }
```

- [ ] **Step 4: Run tests to verify they pass**

```
swift test --filter SessionTests
```

Expected: all `SessionTests` pass (existing 7 + new 3).

- [ ] **Step 5: Run the full suite to confirm nothing else regressed**

```
swift test
```

Expected: full suite passes.

- [ ] **Step 6: Commit**

```bash
git add Clyde/Models/Session.swift ClydeTests/SessionTests.swift
git commit -m "feat(session): add ActiveTool model + toolDisplayLabel"
```

---

## Task 4: `ProcessMonitor.refreshHookTools()` + wiring

**Files:**
- Modify: `Clyde/Services/ProcessMonitor.swift`
- Test: `ClydeTests/ProcessMonitorTests.swift`

- [ ] **Step 1: Add the test helper**

At the top of `ClydeTests/ProcessMonitorTests.swift`, alongside the existing `writeBusyFile` helper, add:

```swift
    /// Writes a `-tool` marker the way PreToolUse hook would. Same PID
    /// semantics as `writeInfoFile` (uses the current process PID so
    /// kill(pid, 0) succeeds).
    private func writeToolFile(
        in dir: URL,
        sessionId: String,
        toolName: String,
        summary: String = "",
        startedAt: TimeInterval = Date().timeIntervalSince1970,
        pid: pid_t = getpid()
    ) {
        let body = #"{"session_id":"\#(sessionId)","pid":\#(pid),"tool_name":"\#(toolName)","summary":"\#(summary)","started_at":\#(Int(startedAt))}"#
        let url = dir.appendingPathComponent("\(sessionId)-tool")
        try? body.write(to: url, atomically: true, encoding: .utf8)
    }
```

- [ ] **Step 2: Write the failing tests**

Append to `ClydeTests/ProcessMonitorTests.swift` (inside the `ProcessMonitorTests` class):

```swift
    func testActiveToolIsPopulatedFromToolFile() async {
        let dir = tempStateDir()
        let sid = UUID().uuidString
        _ = writeInfoFile(in: dir, sessionId: sid)
        let started = Date().timeIntervalSince1970 - 3
        writeToolFile(in: dir, sessionId: sid, toolName: "Edit", summary: "SessionRow.swift", startedAt: started)

        let monitor = ProcessMonitor(
            shell: emptyShell(),
            pollingInterval: 1,
            stateDir: dir,
            isLiveClaudeProcessCheck: { _ in true }
        )
        await monitor.poll()

        XCTAssertEqual(monitor.sessions.count, 1)
        let tool = monitor.sessions[0].activeTool
        XCTAssertEqual(tool?.toolName, "Edit")
        XCTAssertEqual(tool?.summary, "SessionRow.swift")
        XCTAssertEqual(tool?.startedAt.timeIntervalSince1970, started, accuracy: 1)
    }

    func testActiveToolClearsWhenFileRemoved() async {
        let dir = tempStateDir()
        let sid = UUID().uuidString
        _ = writeInfoFile(in: dir, sessionId: sid)
        writeToolFile(in: dir, sessionId: sid, toolName: "Bash", summary: "swift test")

        let monitor = ProcessMonitor(
            shell: emptyShell(),
            pollingInterval: 1,
            stateDir: dir,
            isLiveClaudeProcessCheck: { _ in true }
        )
        await monitor.poll()
        XCTAssertNotNil(monitor.sessions.first?.activeTool)

        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(sid)-tool"))
        await monitor.poll()
        XCTAssertNil(monitor.sessions.first?.activeTool)
    }

    func testActiveToolHandlesEmptySummary() async {
        let dir = tempStateDir()
        let sid = UUID().uuidString
        _ = writeInfoFile(in: dir, sessionId: sid)
        writeToolFile(in: dir, sessionId: sid, toolName: "TodoWrite", summary: "")

        let monitor = ProcessMonitor(
            shell: emptyShell(),
            pollingInterval: 1,
            stateDir: dir,
            isLiveClaudeProcessCheck: { _ in true }
        )
        await monitor.poll()

        XCTAssertEqual(monitor.sessions.first?.activeTool?.toolName, "TodoWrite")
        XCTAssertEqual(monitor.sessions.first?.activeTool?.summary, "")
    }

    func testToolFileIsRemovedWhenPIDIsDead() async {
        let dir = tempStateDir()
        let sid = UUID().uuidString
        _ = writeInfoFile(in: dir, sessionId: sid)
        // Write -tool with a PID that almost certainly doesn't exist.
        let body = #"{"session_id":"\#(sid)","pid":999999,"tool_name":"Edit","summary":"x.swift","started_at":0}"#
        let url = dir.appendingPathComponent("\(sid)-tool")
        try? body.write(to: url, atomically: true, encoding: .utf8)

        let monitor = ProcessMonitor(
            shell: emptyShell(),
            pollingInterval: 1,
            stateDir: dir,
            isLiveClaudeProcessCheck: { _ in true }
        )
        await monitor.poll()

        XCTAssertNil(monitor.sessions.first?.activeTool)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testMalformedToolFileIsRemoved() async {
        let dir = tempStateDir()
        let sid = UUID().uuidString
        _ = writeInfoFile(in: dir, sessionId: sid)
        let url = dir.appendingPathComponent("\(sid)-tool")
        try? "not json".write(to: url, atomically: true, encoding: .utf8)

        let monitor = ProcessMonitor(
            shell: emptyShell(),
            pollingInterval: 1,
            stateDir: dir,
            isLiveClaudeProcessCheck: { _ in true }
        )
        await monitor.poll()

        XCTAssertNil(monitor.sessions.first?.activeTool)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
```

- [ ] **Step 3: Run tests to verify they fail**

```
swift test --filter ProcessMonitorTests
```

Expected: 5 new tests fail (Session has no `activeTool` setter populated by monitor / ProcessMonitor doesn't read `-tool` files).

- [ ] **Step 4: Add `hookToolByPID` and `refreshHookTools()`**

In `Clyde/Services/ProcessMonitor.swift`, just below the `hookSubagentByPID` declaration (~line 63), add:

```swift
    /// Active tool per PID, populated from `-tool` marker files written
    /// by PreToolUse. Cleared on PostToolUse / Stop / SessionEnd.
    private var hookToolByPID: [pid_t: ActiveTool] = [:]
```

After the `refreshHookSubagents()` method (~line 568), add:

```swift
    /// Reads `-tool` marker files written by the PreToolUse hook.
    /// Returns true if the dictionary changed since last call.
    @discardableResult
    private func refreshHookTools() -> Bool {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: stateDir, includingPropertiesForKeys: nil
        ) else {
            let changed = !hookToolByPID.isEmpty
            if changed { hookToolByPID = [:] }
            return changed
        }
        var tools: [pid_t: ActiveTool] = [:]
        for file in files where file.lastPathComponent.hasSuffix("-tool") {
            guard let data = try? Data(contentsOf: file),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pidValue = json["pid"] as? Int,
                  let toolName = json["tool_name"] as? String,
                  !toolName.isEmpty,
                  let startedAt = json["started_at"] as? Int else {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            let pid = pid_t(pidValue)
            if kill(pid, 0) != 0 {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            let summary = (json["summary"] as? String) ?? ""
            tools[pid] = ActiveTool(
                toolName: toolName,
                summary: summary,
                startedAt: Date(timeIntervalSince1970: TimeInterval(startedAt))
            )
        }
        let changed = tools != hookToolByPID
        if changed { hookToolByPID = tools }
        return changed
    }
```

- [ ] **Step 5: Wire `refreshHookTools` into `poll()`**

In `poll()` (~line 215), add the call alongside the others:

```swift
        refreshHookBusyPIDs()
        refreshHookErrors()
        refreshHookSubagents()
        refreshHookTools()
```

- [ ] **Step 6: Wire into `pollHookState()` for the fast path**

In `pollHookState()` (~line 573), add tracking for `toolChanged` and include it in both `if` guards. Replace the relevant section with:

```swift
        let busyChanged = refreshHookBusyPIDs()
        let errorChanged = refreshHookErrors()
        let subagentChanged = refreshHookSubagents()
        let toolChanged = refreshHookTools()

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
        if busyChanged || errorChanged || subagentChanged || toolChanged {
            applyBusyStateToSessions()
        }

        if busyChanged || infoChanged || errorChanged || subagentChanged || toolChanged {
            Task { await self.poll() }
        }
```

- [ ] **Step 7: Apply tool state in `applyBusyStateToSessions()`**

Inside the `for index in updated.indices where !updated[index].isGhost` loop (~line 616), after the subagent block, add:

```swift
            let newTool = hookToolByPID[pid]
            if updated[index].activeTool != newTool {
                updated[index].activeTool = newTool
                changed = true
            }
```

- [ ] **Step 8: Apply tool state in `updatedSession(pid:newStatus:)`**

In the live-row branch (~line 372), right after `existing.subagentType = hookSubagentByPID[pid]`, add:

```swift
            existing.activeTool = hookToolByPID[pid]
```

- [ ] **Step 9: Run tests to verify the new ones pass**

```
swift test --filter ProcessMonitorTests
```

Expected: all `ProcessMonitorTests` pass.

- [ ] **Step 10: Run the full suite**

```
swift test
```

Expected: full suite passes (~67 tests now).

- [ ] **Step 11: Commit**

```bash
git add Clyde/Services/ProcessMonitor.swift ClydeTests/ProcessMonitorTests.swift
git commit -m "feat(monitor): ingest -tool marker into Session.activeTool"
```

---

## Task 5: Animated path ↔ tool swap in `SessionRow`

**Files:**
- Modify: `Clyde/Views/Components/SessionRow.swift`

There is no automated test layer for SwiftUI views in this codebase — verification is by build + visual smoke. The model + monitor are already covered by Tasks 3-4.

- [ ] **Step 1: Add the duration formatter helper**

At the bottom of `SessionRow.swift` (just before the closing brace of `struct SessionRow`), next to `timeAgo`, add:

```swift
    /// Human-readable elapsed time for the active-tool indicator.
    /// Mirrors `timeAgo`'s style but trims to "Ns" / "Nm" / "Nm Ns" so
    /// the second line stays compact even on a 90s Bash command.
    private func formatDuration(from start: Date, now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(start)))
        if s < 60 { return "\(s)s" }
        let m = s / 60
        let r = s % 60
        return r == 0 ? "\(m)m" : "\(m)m \(r)s"
    }
```

- [ ] **Step 2: Replace the path `Text` with the animated ZStack**

Currently the second line is a single `Text` (around lines 100-104). Replace it with:

```swift
                ZStack(alignment: .leading) {
                    if let label = session.toolDisplayLabel,
                       let started = session.activeTool?.startedAt {
                        TimelineView(.periodic(from: started, by: 1)) { context in
                            Text("\(label) · \(formatDuration(from: started, now: context.date))")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Color(white: 0.65))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    } else {
                        Text(session.workingDirectory.isEmpty
                             ? "Unknown path"
                             : abbreviatePath(session.workingDirectory))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Color(white: 0.4))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .frame(height: 14, alignment: .leading)
                .clipped()
                .animation(.spring(response: 0.28, dampingFraction: 0.85),
                           value: session.activeTool != nil)
```

The `if/else` boundary gives SwiftUI two distinct view identities, which the `.transition` modifiers act on. The `.animation(value:)` only triggers on the appear/disappear edge; the per-second tick is internal to `TimelineView` and produces no transition flicker.

- [ ] **Step 3: Build to confirm no compile errors**

```
swift build
```

Expected: clean build.

- [ ] **Step 4: Run the full test suite**

```
swift test
```

Expected: all tests pass (the view change is not test-covered, but this catches any inadvertent breakage in shared types).

- [ ] **Step 5: Visual smoke test**

Open the project in Xcode (or build & launch the app) and run a real Claude Code session in a terminal. Drive these scenarios manually:

1. Submit a prompt that triggers `Edit` on a file → confirm the second line slides up to show `Edit · <basename> · Ns` and the duration ticks each second.
2. Wait for `PostToolUse` → confirm the path slides back in (no flicker, no row height change).
3. Submit a prompt with `Bash swift test` → confirm long-command truncation displays cleanly with `…`.
4. Trigger a `Stop` mid-tool (Ctrl+C in the Claude session) → confirm the tool indicator clears immediately.

If anything visually misbehaves (row jiggle, animation lag, truncation overflow), fix and re-run.

- [ ] **Step 6: Commit**

```bash
git add Clyde/Views/Components/SessionRow.swift
git commit -m "feat(ui): animate path↔tool swap with live duration on session row"
```

---

## Task 6: Bump `HookInstaller.currentScriptVersion`

**Files:**
- Modify: `Clyde/Services/HookInstaller.swift:67`

Now that the Swift side ingests `-tool` files, it's safe to mark the hook version as 17 — `HookInstaller` will reinstall the bundled v17 hook the next time Clyde launches against a host that has v16 or older installed.

- [ ] **Step 1: Bump the constant**

```swift
    static let currentScriptVersion = 17
```

(Was `16`.)

- [ ] **Step 2: Run the full test suite**

```
swift test
```

Expected: passes. `HookInstallerTests` may verify version-mismatch behavior — if a test pinned the constant to 16, update its expected value too.

- [ ] **Step 3: Commit**

```bash
git add Clyde/Services/HookInstaller.swift
git commit -m "chore(hook): bump bundled hook version to 17"
```

---

## Task 7: ROADMAP + CHANGELOG

**Files:**
- Modify: `ROADMAP.md` (the v0.3.0 phase, first bullet)
- Modify: `CHANGELOG.md` (`## [Unreleased]` section)

- [ ] **Step 1: Tick the ROADMAP item**

Replace the `[ ] Surface current tool + duration in the panel — …` line under `## Phase: v0.3.0 — Richer session telemetry` with a one-line summary of what shipped (per CLAUDE.md convention — original spec text moves to git history). Use:

```markdown
- [x] Surface current tool + duration in the panel — `clyde-hook` v17 writes `state/<sid>-tool` on `PreToolUse` (whitelisted summary per built-in tool, e.g. `file_path` basename for Edit/Write/Read, host for WebFetch, first 40 chars of command for Bash) and clears it on `PostToolUse` / `Stop` / `SessionEnd`. `SessionRow` swaps the second line between project path and `<Tool> · <summary> · <Ns>` with a spring slide animation, live duration via `TimelineView` !md #hooks #ux
```

- [ ] **Step 2: Add CHANGELOG bullet**

Under `## [Unreleased]` in `CHANGELOG.md`, add (no hard-wrap, per CLAUDE.md):

```markdown
- Show the active tool and a live-ticking duration on each session row. When Claude calls Edit, Bash, Read, Glob, Grep, Task, WebFetch, or WebSearch, the second line of the row swaps from the project path to e.g. `Edit · SessionRow.swift · 3s` and slides back to the path when the tool finishes. Other tools (TodoWrite, MCP tools) show just the tool name.
```

If `## [Unreleased]` doesn't yet exist as a section above the most recent release, add it.

- [ ] **Step 3: Commit**

```bash
git add ROADMAP.md CHANGELOG.md
git commit -m "docs: tick v0.3.0 tool+duration item, add CHANGELOG entry"
```

---

## Verification Checklist

Before considering the feature done:

- [ ] `swift test` passes (full suite, including the 5 new `ProcessMonitorTests` and 3 new `SessionTests`).
- [ ] Hook smoke-test from Task 1 Step 6 passes all 6 checks.
- [ ] Manual visual smoke from Task 5 Step 5 confirms slide animation, live duration, and clean clear on PostToolUse / Stop.
- [ ] `HookInstaller.currentScriptVersion == 17` and `# clyde-hook-version: 17` match.
- [ ] No new files created (sanity check — all changes fit existing files).
- [ ] No `// removed` / `// TODO` comments left behind.
- [ ] Git log shows ~6 focused commits, each with a Conventional Commit subject and no `Co-Authored-By: Claude`, no `Generated with Claude Code` footer.
