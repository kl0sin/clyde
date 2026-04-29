# Tool + Duration in the Expanded Panel

**Date:** 2026-04-29
**Status:** Approved
**Scope:** `Clyde/Resources/clyde-hook.sh`, `Clyde/Services/HookInstaller.swift`, `Clyde/Services/ProcessMonitor.swift`, `Clyde/Models/Session.swift`, `Clyde/Views/Components/SessionRow.swift`, hook + monitor tests.

## Goal

Show the user *what Claude is doing* — not just that it is busy. When Claude calls a tool, the second line of the session row in the expanded panel temporarily replaces the project path with a short tool descriptor and a live-ticking duration (e.g. `Edit · SessionRow.swift · 3s`). When the tool returns, the line slides back to the path. The tool indicator is built on the existing local hook pipeline; no new IPC surface is added.

This is the first of two roadmap items in the v0.3.0 phase ("Richer session telemetry"); the second item (`TaskCreated` planning affordance) is independent and will be designed separately.

## Lifecycle

The tool indicator follows a strict per-tool-call lifecycle. The session can be busy without an active tool (Claude is generating text or thinking); in that state the path is shown.

| Hook event | Effect on `state/<sid>-tool` |
|---|---|
| `PreToolUse` | Atomic write of a fresh record. |
| `PostToolUse` | Remove the record. |
| `PostToolUseFailure` | Remove the record (covers both Ctrl-C interrupts and non-interrupt failures — the tool call has ended either way). |
| `Stop` | Remove the record. |
| `SessionEnd` | Remove the record (in addition to all other markers already cleared). |

The `-busy` marker keeps its existing semantics; the new `-tool` file is orthogonal. A session can be `busy` with `activeTool == nil` (between tool calls or during pure-text turns), and that's the steady state for "Claude is thinking".

There is no separate "finished, show final duration" state. With the path-as-default lifecycle, a `PostToolUse` simply slides the path back in; the duration is only ever live.

## Hook script changes (`clyde-hook.sh` v17)

Bump `# clyde-hook-version: 17` and `HookInstaller.currentScriptVersion = 17` so existing installs are auto-upgraded by `HookInstaller`.

### New state file: `state/<sid>-tool`

JSON, atomic write via the existing `atomic_write` helper:

```json
{
  "session_id": "<uuid>",
  "pid": 12345,
  "tool_name": "Edit",
  "summary": "SessionRow.swift",
  "started_at": 1714400000
}
```

`started_at` is unix epoch seconds (`$TIMESTAMP`, already computed at the top of the script). `summary` may be the empty string for unsupported tools — Swift handles the fallback display.

### `PreToolUse` case

In addition to the existing `touch -busy`, extract `tool_name` and a tool-specific summary field, then write the `-tool` record. The `extract_field` helper already handles top-level fields; for `tool_input.<field>` we need a small nested helper. Use python3 with a fallback to `grep` consistent with the existing `extract_field` style.

Per-tool extraction whitelist:

| `tool_name` | source field | transform |
|---|---|---|
| `Edit`, `Write`, `Read`, `MultiEdit`, `NotebookEdit` | `tool_input.file_path` | `basename` |
| `Bash` | `tool_input.command` | first line, max 40 chars (truncate with `…` suffix if longer) |
| `Glob`, `Grep` | `tool_input.pattern` | as-is, max 40 chars |
| `Task` | `tool_input.subagent_type` | as-is |
| `WebFetch` | `tool_input.url` | extract host (first `//` to next `/`) |
| `WebSearch` | `tool_input.query` | as-is, max 40 chars |
| anything else (TodoWrite, MCP tools, future tools) | — | `summary = ""` |

The tool name is preserved verbatim; only the summary is shaped. The whitelist is in bash (the script already does light per-event branching), but the *display* is in Swift — see `toolDisplayLabel` below.

### `PostToolUse` / `PostToolUseFailure` cases

`PostToolUse` is currently not handled at all. Add a case that does `rm -f "$STATE_DIR/$KEY-tool"`. The existing `PostToolUseFailure` case (interrupt-only `-busy` cleanup) gains an unconditional `-tool` removal — the tool call has terminated either way.

### `Stop` and `SessionEnd` cases

Add `state/$KEY-tool` to the `rm -f` list in both cases.

### Header documentation

Update the `# Handled events:` block at the top of the script to mention the `-tool` file and its lifecycle. Bump the file count list accordingly.

## Swift model: `Session.activeTool`

New equatable value type and field on `Session`:

```swift
struct ActiveTool: Equatable {
    let toolName: String
    let summary: String      // empty for fallback (whitelist miss)
    let startedAt: Date
}

var activeTool: ActiveTool? = nil
```

Display helper on `Session`:

```swift
var toolDisplayLabel: String? {
    guard let t = activeTool else { return nil }
    return t.summary.isEmpty ? t.toolName : "\(t.toolName) · \(t.summary)"
}
```

`activeTool` is mutated only by `ProcessMonitor`; the rest of the model is unchanged. `Session.init` does not take it as an argument (it stays at the default `nil`).

## ProcessMonitor: `-tool` file ingestion

Mirror the existing `-subagent` plumbing one-for-one — the structure is well established and tests already exercise it.

New private state on `ProcessMonitor`:

```swift
private var hookToolByPID: [pid_t: ActiveTool] = [:]
```

New `refreshHookTools()` method modeled on `refreshHookSubagents()` (~30 LOC). It reads `*-tool` files from `stateDir`, validates JSON shape (`tool_name`, `started_at`, optional `summary`), drops files whose PID is dead, and assigns `hookToolByPID`. Returns `true` when the dictionary changed.

Wiring:

- Call `refreshHookTools()` from both `poll()` (alongside `refreshHookBusyPIDs/Errors/Subagents`) and `pollHookState()`.
- In `pollHookState()`, include `toolChanged` in the `if busyChanged || errorChanged || subagentChanged` guard so the fast-path UI update fires.
- In `applyBusyStateToSessions()`, sync `updated[index].activeTool = hookToolByPID[pid]` exactly the way `subagentType` is synced.
- In `updatedSession(pid:newStatus:)`, set `existing.activeTool = hookToolByPID[pid]` in the live-row branch (mirror of the line that sets `subagentType`).

The FSEvents watcher on `~/.clyde/state/` already triggers on any file change in the directory, so no new watcher is required — `-tool` files are picked up on the next `pollHookState()` tick (≤ ~1 s, usually within a few ms).

## SessionRow: animated path ↔ tool swap and live duration

The current second line is a single `Text(workingDirectory…)`. Replace it with a `ZStack(alignment: .leading)` that contains either the path text or the live tool text. SwiftUI's view-identity-based transitions handle the slide.

Sketch:

```swift
ZStack(alignment: .leading) {
    if let label = session.toolDisplayLabel, let started = session.activeTool?.startedAt {
        TimelineView(.periodic(from: started, by: 1)) { context in
            Text("\(label) · \(formatDuration(from: started, now: context.date))")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color(white: 0.65))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .id("tool")
        .transition(.move(edge: .bottom).combined(with: .opacity))
    } else {
        Text(session.workingDirectory.isEmpty ? "Unknown path" : abbreviatePath(session.workingDirectory))
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(Color(white: 0.4))
            .lineLimit(1)
            .truncationMode(.middle)
            .id("path")
            .transition(.move(edge: .top).combined(with: .opacity))
    }
}
.frame(height: 14, alignment: .leading)
.clipped()
.animation(.spring(response: 0.28, dampingFraction: 0.85), value: session.activeTool != nil)
```

Notes on the choices:

- **`TimelineView(.periodic(from: startedAt, by: 1))`** — re-renders the inner `Text` once per second so the duration label is always current without owning a `Timer`. Pattern is already used elsewhere in `SessionRow` (busy-mascot bounce uses `TimelineView(.animation)`), so it fits the file's existing rhythm.
- **Fixed `frame(height: 14)` + `.clipped()`** — prevents the row from changing height during the slide, which would otherwise visually jiggle the rows below. 14 pt is the natural line height of the existing 10 pt monospaced text.
- **`.animation(value: session.activeTool != nil)`** — animates only on appear/disappear of the tool view, not on every duration tick (the tick is inside `TimelineView`, which is a separate identity).
- **Color** — tool line at `Color(white: 0.65)`, path stays at `Color(white: 0.4)`. Same monospaced 10 pt font in both states; only the foreground brightness changes so the eye knows "this is different from the path".

### Duration formatting

```swift
func formatDuration(from start: Date, now: Date) -> String {
    let s = max(0, Int(now.timeIntervalSince(start)))
    if s < 60 { return "\(s)s" }
    let m = s / 60
    let r = s % 60
    return r == 0 ? "\(m)m" : "\(m)m \(r)s"
}
```

Mirrors the existing `timeAgo` helper at the bottom of `SessionRow.swift`. Could be folded into a single helper later, but for now leaving them separate is fine — `timeAgo` truncates differently and changing it for both uses would expand the diff.

## Testing

### `ProcessMonitor` integration tests (`ProcessMonitorTests`)

Add tests modeled on the existing `-subagent` tests:

1. Writing `state/<sid>-tool` populates `Session.activeTool` on the matching live row.
2. Removing the file clears `Session.activeTool` on the next tick.
3. A `-tool` file whose PID is dead is removed from disk and ignored.
4. A `-tool` file with malformed JSON is removed and ignored.
5. `Session.activeTool` survives a status flip from idle → busy → idle without churning identity.

### `Session` unit tests

If `SessionTests` (or equivalent) exists, add coverage for `toolDisplayLabel`:

- with `activeTool == nil` → returns `nil`
- with non-empty summary → `"<tool> · <summary>"`
- with empty summary → `"<tool>"`

### Hook script — manual smoke test

`ActivityLog` and the hook script have no unit tests today (per CLAUDE.md). Add a manual smoke-test recipe to the existing hook smoke-test doc covering:

- `PreToolUse` payloads for each whitelisted tool → expected `summary` field in `-tool`
- `PostToolUse`, `PostToolUseFailure`, `Stop` clear the file
- An MCP-style tool name with no whitelist match writes `summary: ""`

The existing `Clyde/Resources/clyde-hook.sh` smoke pattern (`HOME=/tmp/... echo '<json>' | bash clyde-hook.sh && cat ~/.clyde/state/...`) is sufficient.

## Out of scope

- **History of recent tools per session.** Roadmap-deferred to `v0.3.0+`.
- **`duration_ms` from `PostToolUse` payload.** With the chosen lifecycle the tool indicator vanishes on `PostToolUse`, so there's no surface to render the final duration on. Field is ignored.
- **`TaskCreated` hook event** — the second `v0.3.0` roadmap item. Tracked separately; will land in its own spec.
- **MCP / TodoWrite-specific summaries.** Whitelist intentionally covers only the built-in Claude Code tools today. Adding MCP-aware extraction would require knowing each MCP tool's input schema; deferred until there's user demand.
- **Tool-specific colour or icon coding** (e.g. red tint for `Bash`, file-icon for `Edit`). Not adopted now — keeps the visual diff small and avoids visual noise on dense panels.

## Migration notes

- Hook auto-upgrade: `HookInstaller` already replaces an installed hook whose `# clyde-hook-version` is older than `currentScriptVersion`. Bumping to v17 is sufficient — no user action required.
- `state/<sid>-tool` files left over from a previous Clyde process (e.g. crash mid-tool) are pruned on next poll because the PID liveness check in `refreshHookTools()` removes them.
