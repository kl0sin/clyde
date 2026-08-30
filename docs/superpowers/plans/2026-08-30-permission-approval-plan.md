# Approving permission requests from the panel — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Answer a Claude permission request from Clyde's panel with one click, falling back to the terminal's own prompt whenever anything is unusual.

**Architecture:** The hook's `PermissionRequest` branch writes a request file under `~/.clyde/permissions/`, waits a few seconds for a matching decision file, prints the decision on stdout and deletes both. Clyde watches that directory, renders the request on the session's row, and writes the decision when the user clicks. Silence, a missing Clyde, a malformed file or an expired window all end as `behavior: "ask"`, which is the terminal prompt the user has today.

**Tech Stack:** bash (the hook), Swift 6 / SwiftUI / Combine (the app), XCTest.

**Spec:** `docs/superpowers/specs/2026-08-30-permission-approval-design.md`

## Global Constraints

- The hook never `set -e`, never exits non-zero, and never blocks past its own window. A hook that fails noisily raises "Stop hook error" in the user's session every turn.
- Bump `# clyde-hook-version:` in `Clyde/Resources/clyde-hook.sh` **and** `HookInstaller.currentScriptVersion` to the same number, in the same commit. Both are 40 today; this plan takes them to 41.
- The always-on log format `[YYYY-MM-DD HH:MM:SS] event=NAME sid=… ppid=… pid=… cwd=…` only ever gains fields at the end.
- Every unhandled path resolves to `behavior: "ask"`. There is no path that denies on Clyde's behalf.
- The feature is off unless the user turns it on. Default `false`, read once per request.
- `swift test` from the repo root must pass before every commit that touches Swift.
- No `git add -A`. Stage paths individually. No Claude attribution anywhere.

## File structure

| File | Responsibility |
|---|---|
| `Clyde/Resources/clyde-hook.sh` | `PermissionRequest` branch: write request, wait, print decision, clean up |
| `Clyde/Services/HookInstaller.swift` | `currentScriptVersion` 40 → 41 |
| `Clyde/Services/AppPaths.swift` | `permissionsDir`, `permissionRequest(id:)`, `permissionDecision(id:)` |
| `Clyde/Models/PermissionRequest.swift` | The request as Clyde sees it: id, session, tool, input, deadline |
| `Clyde/Services/PermissionRequestStore.swift` | Watch the directory, publish live requests, write decisions |
| `Clyde/Views/Components/PermissionRequestRow.swift` | Tool, command, Allow / Deny |
| `Clyde/Views/Components/SessionRow.swift` | Host the row under the session it belongs to |
| `Clyde/Views/SettingsView.swift` | The toggle, off by default |
| `scripts/dev/scenarios.sh` | `permission-request` scenario for the live checks |

---

### Task 1: The request file the hook writes

**Files:**
- Modify: `Clyde/Resources/clyde-hook.sh`
- Modify: `Clyde/Services/HookInstaller.swift`
- Test: `ClydeTests/HookScriptTests.swift`

**Interfaces:**
- Produces: `~/.clyde/permissions/<request_id>.request` containing `request_id`, `session_id`, `pid`, `cwd`, `tool_name`, `tool_input`, `created_at`, `expires_at`.

- [ ] **Step 1: Write the failing test**

```swift
func testPermissionRequestWritesARequestFileWithTheToolAndItsInput() throws {
    let home = try makeSandboxedHome()
    let payload = """
    {"hook_event_name":"PermissionRequest","session_id":"sess-1","cwd":"/repo",
     "tool_name":"Bash","tool_input":{"command":"rm -rf build","description":"Clean"}}
    """

    _ = try runHook(payload: payload, home: home)

    let dir = home.appendingPathComponent(".clyde/permissions")
    let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        .filter { $0.hasSuffix(".request") }
    XCTAssertEqual(files.count, 1, "one request file per request")
    let body = try JSONSerialization.jsonObject(
        with: Data(contentsOf: dir.appendingPathComponent(files[0]))) as? [String: Any]
    XCTAssertEqual(body?["tool_name"] as? String, "Bash")
    XCTAssertEqual((body?["tool_input"] as? [String: Any])?["command"] as? String, "rm -rf build")
    XCTAssertEqual(body?["session_id"] as? String, "sess-1")
    XCTAssertNotNil(body?["request_id"])
    XCTAssertNotNil(body?["expires_at"])
}
```

- [ ] **Step 2: Run it and watch it fail**

Run: `swift test --filter testPermissionRequestWritesARequestFileWithTheToolAndItsInput`
Expected: FAIL — the permissions directory does not exist.

- [ ] **Step 3: Write the request file**

In `clyde-hook.sh`, hoist `tool_input` alongside the existing `TOOL_NAME` hoist (which today only covers `PreToolUse|PostToolUse|PostToolUseFailure` — `PermissionRequest` carries `tool_name` and `tool_input` too, and the current branch throws both away):

```sh
PERMISSIONS_DIR="$CLYDE_DIR/permissions"
DECISION_WINDOW_SECONDS=4

# `tool_input` is a JSON object, not a string — extract_field returns
# scalars, so read it as raw JSON and keep it that way.
extract_json_field() {
    printf '%s' "$INPUT" | python3 -c "
import json, sys
try:
    d = json.loads(sys.stdin.read())
except Exception:
    d = {}
print(json.dumps(d.get('$1', {})))
" 2>/dev/null || printf '{}'
}
```

and in the `PermissionRequest)` branch, before the existing attention-event write:

```sh
        mkdir -p "$PERMISSIONS_DIR" 2>/dev/null
        # The payload carries no tool_use_id, so the hook mints the id
        # that ties a request to its answer.
        REQUEST_ID="$KEY-$TIMESTAMP-$$"
        TOOL_INPUT_JSON=$(extract_json_field tool_input)
        atomic_write "$PERMISSIONS_DIR/$REQUEST_ID.request" \
            "{\"request_id\": \"$REQUEST_ID\", \"session_id\": \"$ESC_SID\", \"pid\": $CLAUDE_PID, \"cwd\": \"$ESC_CWD\", \"tool_name\": \"$ESC_TOOL_NAME\", \"tool_input\": $TOOL_INPUT_JSON, \"created_at\": $TIMESTAMP, \"expires_at\": $((TIMESTAMP + DECISION_WINDOW_SECONDS))}"
```

- [ ] **Step 4: Run the test — it passes**

- [ ] **Step 5: Bump both versions together**

`# clyde-hook-version: 41` in the script, `static let currentScriptVersion = 41` in `HookInstaller.swift`.

- [ ] **Step 6: Full suite, then commit**

```bash
swift test
git add Clyde/Resources/clyde-hook.sh Clyde/Services/HookInstaller.swift ClydeTests/HookScriptTests.swift
git commit -m "feat(hooks): record what a permission request is asking for"
```

---

### Task 2: The hook waits, then answers

**Files:**
- Modify: `Clyde/Resources/clyde-hook.sh`
- Test: `ClydeTests/HookScriptTests.swift`

**Interfaces:**
- Consumes: `~/.clyde/permissions/<request_id>.decision` containing `{"behavior": "allow"|"deny"}`.
- Produces: on stdout, `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"…"}}}`.

- [ ] **Step 1: Write the failing tests — the answer, and the three ways it must not hang**

```swift
func testTheHookPrintsTheDecisionItWasGiven() throws {
    let home = try makeSandboxedHome()
    // Drop the answer in as soon as the request appears.
    let answerer = answerNextRequest(in: home, with: "allow")
    defer { answerer.cancel() }

    let output = try runHook(payload: permissionPayload(), home: home)

    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
    let specific = json["hookSpecificOutput"] as? [String: Any]
    XCTAssertEqual(specific?["hookEventName"] as? String, "PermissionRequest")
    XCTAssertEqual((specific?["decision"] as? [String: Any])?["behavior"] as? String, "allow")
}

func testNoAnswerFallsThroughToAsk() throws {
    let home = try makeSandboxedHome()

    let started = Date()
    let output = try runHook(payload: permissionPayload(), home: home)

    XCTAssertTrue(output.contains("\"behavior\": \"ask\""), output)
    XCTAssertLessThan(Date().timeIntervalSince(started), 8, "the window must bound the wait")
}

func testAMalformedAnswerIsAsk() throws {
    let home = try makeSandboxedHome()
    let answerer = answerNextRequest(in: home, with: "not json at all", raw: true)
    defer { answerer.cancel() }

    XCTAssertTrue(try runHook(payload: permissionPayload(), home: home).contains("\"ask\""))
}

/// An answer for a different request must not be consumed by this one.
func testAnAnswerForAnotherRequestIsIgnored() throws {
    let home = try makeSandboxedHome()
    let dir = home.appendingPathComponent(".clyde/permissions")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try #"{"behavior":"allow"}"#.write(to: dir.appendingPathComponent("someone-else.decision"),
                                      atomically: true, encoding: .utf8)

    XCTAssertTrue(try runHook(payload: permissionPayload(), home: home).contains("\"ask\""))
}

/// The hook is advisory: whatever happens here, the session continues.
func testTheHookStillExitsZero() throws {
    let home = try makeSandboxedHome()
    XCTAssertEqual(try runHookExitCode(payload: permissionPayload(), home: home), 0)
}
```

- [ ] **Step 2: Run them — all five fail (nothing is printed today)**

- [ ] **Step 3: Wait for the answer, print it, clean up**

```sh
        # Poll for an answer until the window closes. 0.1s granularity
        # keeps a fast click feeling instant without spinning the CPU.
        DECISION_FILE="$PERMISSIONS_DIR/$REQUEST_ID.decision"
        BEHAVIOR=""
        WAITED=0
        while [ "$WAITED" -lt $((DECISION_WINDOW_SECONDS * 10)) ]; do
            if [ -f "$DECISION_FILE" ]; then
                BEHAVIOR=$(extract_decision_behavior "$DECISION_FILE")
                break
            fi
            sleep 0.1
            WAITED=$((WAITED + 1))
        done
        # Anything other than an explicit allow/deny is the terminal's
        # question to ask, including a decision we could not parse.
        case "$BEHAVIOR" in
            allow|deny) ;;
            *) BEHAVIOR="ask" ;;
        esac
        rm -f "$DECISION_FILE" "$PERMISSIONS_DIR/$REQUEST_ID.request"
        printf '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior": "%s"}}}\n' "$BEHAVIOR"
```

with the reader kept small and total:

```sh
extract_decision_behavior() {
    python3 -c "
import json, sys
try:
    print(json.load(open(sys.argv[1])).get('behavior', ''))
except Exception:
    print('')
" "$1" 2>/dev/null || printf ''
}
```

- [ ] **Step 4: Run the tests — all five pass**

- [ ] **Step 5: Smoke-test the hook by hand, per CLAUDE.md**

```bash
HOME=/tmp/clyde-hook-smoke bash Clyde/Resources/clyde-hook.sh <<'EOF'
{"hook_event_name":"PermissionRequest","session_id":"s","cwd":"/tmp","tool_name":"Bash","tool_input":{"command":"ls"}}
EOF
cat /tmp/clyde-hook-smoke/.clyde/logs/hook.log
```
Expected: `"behavior": "ask"` on stdout after ~4s, exit 0, one log line, no leftover files in `permissions/`.

- [ ] **Step 6: Full suite, then commit**

```bash
swift test
git add Clyde/Resources/clyde-hook.sh ClydeTests/HookScriptTests.swift
git commit -m "feat(hooks): let Clyde answer a permission request, briefly"
```

---

### Task 3: Clyde reads requests and writes decisions

**Files:**
- Create: `Clyde/Models/PermissionRequest.swift`
- Create: `Clyde/Services/PermissionRequestStore.swift`
- Modify: `Clyde/Services/AppPaths.swift`
- Test: `ClydeTests/PermissionRequestStoreTests.swift`

**Interfaces:**
- Produces: `PermissionRequestStore.pending: [PermissionRequest]`, `answer(_:with:)`.

- [ ] **Step 1: Write the failing tests**

```swift
@MainActor
final class PermissionRequestStoreTests: XCTestCase {

    func testAWrittenRequestBecomesPending() throws {
        let dir = tempDir()
        let store = PermissionRequestStore(directory: dir)
        try writeRequest(in: dir, id: "r1", tool: "Bash", command: "rm -rf build",
                         expiresIn: 30)

        store.scan()

        XCTAssertEqual(store.pending.count, 1)
        XCTAssertEqual(store.pending.first?.toolName, "Bash")
        XCTAssertEqual(store.pending.first?.summary, "rm -rf build")
    }

    /// The hook stops waiting when the window closes; a request left on
    /// disk after that is already answered by the terminal.
    func testAnExpiredRequestIsNotPending() throws {
        let dir = tempDir()
        let store = PermissionRequestStore(directory: dir)
        try writeRequest(in: dir, id: "old", tool: "Bash", command: "ls", expiresIn: -1)

        store.scan()

        XCTAssertTrue(store.pending.isEmpty)
    }

    func testAnsweringWritesTheDecisionBesideTheRequest() throws {
        let dir = tempDir()
        let store = PermissionRequestStore(directory: dir)
        try writeRequest(in: dir, id: "r1", tool: "Bash", command: "ls", expiresIn: 30)
        store.scan()

        store.answer(try XCTUnwrap(store.pending.first), with: .allow)

        let written = try JSONSerialization.jsonObject(
            with: Data(contentsOf: dir.appendingPathComponent("r1.decision"))) as? [String: Any]
        XCTAssertEqual(written?["behavior"] as? String, "allow")
        XCTAssertTrue(store.pending.isEmpty, "an answered request leaves the panel at once")
    }

    func testAMalformedRequestIsIgnoredRatherThanCrashing() throws {
        let dir = tempDir()
        try "{ not json".write(to: dir.appendingPathComponent("bad.request"),
                               atomically: true, encoding: .utf8)
        let store = PermissionRequestStore(directory: dir)

        store.scan()

        XCTAssertTrue(store.pending.isEmpty)
    }
}
```

- [ ] **Step 2: Run them — they fail to compile, the types do not exist**

- [ ] **Step 3: Write the model and the store**

```swift
struct PermissionRequest: Identifiable, Equatable {
    let id: String
    let sessionId: String
    let pid: pid_t
    let toolName: String
    let input: [String: Any]
    let expiresAt: Date

    /// What the row shows beside the tool name: the command for Bash,
    /// the path for a file tool, the whole input otherwise. Never
    /// truncated — a shortened command invites approving something the
    /// user did not read.
    var summary: String { … }

    var isLive: Bool { expiresAt > Date() }
}

enum PermissionDecision: String { case allow, deny }
```

The store mirrors `AttentionMonitor`: a `DispatchSource` watcher on the directory for immediate reaction, a 1s timer to expire requests whose window has closed, `@Published private(set) var pending`. The cancel handler captures its descriptor rather than reading a property — the leak fixed in `ProcessMonitor` came from doing otherwise.

- [ ] **Step 4: Run the tests — they pass**

- [ ] **Step 5: Commit**

```bash
swift test
git add Clyde/Models/PermissionRequest.swift Clyde/Services/PermissionRequestStore.swift Clyde/Services/AppPaths.swift ClydeTests/PermissionRequestStoreTests.swift
git commit -m "feat(permissions): read pending requests and write their answers"
```

---

### Task 4: The row in the panel

**Files:**
- Create: `Clyde/Views/Components/PermissionRequestRow.swift`
- Modify: `Clyde/Views/Components/SessionRow.swift`
- Test: `ClydeTests/PermissionRequestRowTests.swift`

- [ ] **Step 1: Write the failing tests — the decisions the view makes, not its pixels**

```swift
func testTheRowShowsTheWholeCommand() {
    let long = String(repeating: "a", count: 400)
    XCTAssertEqual(PermissionRequestRow.displayedSummary(for: long), long,
                   "never abbreviate what the user is approving")
}

func testARequestBelongsToItsOwnSession() {
    XCTAssertTrue(PermissionRequestRow.shows(request: request(pid: 42), inRowFor: 42))
    XCTAssertFalse(PermissionRequestRow.shows(request: request(pid: 42), inRowFor: 99))
}

func testAnExpiredRequestIsNotShown() {
    XCTAssertFalse(PermissionRequestRow.shows(request: expiredRequest(pid: 42), inRowFor: 42))
}
```

- [ ] **Step 2: Run them — fail, the type does not exist**

- [ ] **Step 3: Build the row** — tool name, full input in a horizontally scrolling container, Allow and Deny. Follow `SessionRow`'s existing tokens and the accessibility rules already applied there: labels on both buttons, no colour-only meaning.

- [ ] **Step 4: Tests pass. Then look at it** — `./scripts/build-app.sh debug && open .build/debug/Clyde.app`, with a request file dropped in by hand. Read the row. Screenshots have caught two shipped UI defects in this project that green tests did not.

- [ ] **Step 5: Commit**

---

### Task 5: The setting, off by default

**Files:**
- Modify: `Clyde/Views/SettingsView.swift`, `Clyde/ViewModels/AppViewModel.swift`
- Test: `ClydeTests/PermissionRequestStoreTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
func testDisabledMeansClydeNeverAnswers() throws {
    let dir = tempDir()
    let store = PermissionRequestStore(directory: dir, isEnabled: { false })
    try writeRequest(in: dir, id: "r1", tool: "Bash", command: "ls", expiresIn: 30)

    store.scan()

    XCTAssertTrue(store.pending.isEmpty, "nothing to click means the terminal asks")
}
```

- [ ] **Step 2: Run it — it fails**

- [ ] **Step 3: Gate the store on the setting**, defaulting to `false`. Clyde simply never answers; the hook's window closes and the terminal asks, which is exactly today's behaviour. Nothing in the hook needs to know whether the feature is on.

- [ ] **Step 4: Test passes. Add the Settings toggle** with a line saying what it does and that the terminal still asks whenever Clyde does not answer in time.

- [ ] **Step 5: Full suite, then commit**

---

### Task 6: The live checks

**Files:**
- Modify: `scripts/dev/scenarios.sh`
- Modify: `ROADMAP.md`

- [ ] **Step 1: Add a `permission-request` scenario** that installs the hook, launches the dev build, and prints what to do: run `claude --permission-mode manual "touch marker.txt"` in a second terminal, then watch the panel.

- [ ] **Step 2: Run the four cases by hand and record what happened**

1. Answer in the panel → the tool runs, no terminal prompt.
2. Answer in the terminal while the panel shows the request → the row clears itself, nothing is left behind.
3. Answer nowhere → the terminal prompt appears when the window closes.
4. Kill Clyde mid-window → the terminal prompt appears; the session is unaffected.

- [ ] **Step 3: Measure the cost on calls that are not gated.** `PermissionRequest` only fires when permission is requested, so this should be zero. Confirm it rather than assume it: time a session doing ordinary file reads with the hook at v41 against v40.

- [ ] **Step 4: Tick the ROADMAP items and record what the live run showed**

- [ ] **Step 5: Commit**

---

## Not in this plan

Remembering decisions, writing rules to `settings.json`, and acting on `permission_suggestions`. Each is a separate decision about how much authority Clyde holds, and none of them is needed for a user to answer the question in front of them.
