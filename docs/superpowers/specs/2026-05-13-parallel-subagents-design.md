# Parallel Subagents in the Expanded Panel

**Date:** 2026-05-13
**Status:** Approved
**Scope:** `Clyde/Resources/clyde-hook.sh`, `Clyde/Services/HookInstaller.swift`, `Clyde/Services/ProcessMonitor.swift`, `Clyde/Models/Session.swift`, `Clyde/ViewModels/AppViewModel.swift`, `Clyde/Views/Components/SessionRow.swift`, hook + monitor tests.

## Goal

Make it visible at a glance which Task subagents are running in parallel inside a single Claude Code session, and what each one is doing. Today the hook writes a single `state/<sid>-subagent` file that holds only the *last-dispatched* subagent type and is removed on the *first* `SubagentStop` — so when the user fans out 3+ subagents in one turn, the panel only ever shows one (the most recent), and as soon as any one finishes the marker disappears even though others are still working. The session row shows `Agent · general-purpose · 1:42` and nothing more, even when five agents are mid-flight across five worktrees.

This work replaces the single-flag model with a per-agent list, displayed under the session row as a fixed-structure block (two lines per agent), with a click-to-expand affordance when the count exceeds three. Pure local-hook work; no new IPC.

This is a v0.3.x feature, fed by the same parallel-subagent dispatch the user already exercises daily.

## Lifecycle

Each in-flight subagent is one entry. The set of active subagents is the set of `Task` tool calls in the parent session that have a `PreToolUse` but no matching `PostToolUse` / `PostToolUseFailure`.

| Hook event | Effect on `state/<sid>-agents/` |
|---|---|
| `PreToolUse` (tool=`Task`) | Atomic write of `state/<sid>-agents/<tool_use_id>.json`. |
| `PostToolUse` (tool=`Task`) | Remove `state/<sid>-agents/<tool_use_id>.json`. |
| `PostToolUseFailure` (tool=`Task`) | Remove `state/<sid>-agents/<tool_use_id>.json` (interrupt or runtime failure — the call has ended either way). |
| `Stop` | **No-op on the agents directory.** Parent Stop may fire while subagents are still running; we keep displaying them until each one's own `PostToolUse(Task)` arrives. |
| `SessionEnd` | Remove the entire `state/<sid>-agents/` directory. |
| `SubagentStop` (legacy) | Best-effort defensive cleanup only — see "Defensive cleanup" below. Not load-bearing. |

The `-busy` marker keeps its existing semantics; the new agents directory is orthogonal. A session can be busy with zero entries in `state/<sid>-agents/` (parent thinking, or any non-Task tool active). A session can also have one or more entries while `-busy` is set — that's the "fanned-out" steady state this work targets.

The `-tool` marker (parent-side tool indicator from v0.3.0) keeps working as-is. When the parent's current tool is `Task`, the parent's `-tool` payload will reflect that one Task call's summary; the new list view is the richer surface for the parallel case.

## Hook script changes (`clyde-hook.sh` v19)

Bump `# clyde-hook-version: 19` and `HookInstaller.currentScriptVersion = 19`.

### New state directory: `state/<sid>-agents/<tool_use_id>.json`

One file per active subagent. JSON payload:

```json
{
  "session_id": "<uuid>",
  "tool_use_id": "<id-from-payload>",
  "subagent_type": "general-purpose",
  "summary": "research SubagentStart payload",
  "started_at": 1747084812
}
```

Fields:
- `subagent_type` — read from `tool_input.subagent_type`. Falls back to literal `"agent"` if absent.
- `summary` — read from `tool_input.description` (the short label Claude attaches to every Task call), trimmed to the first 80 chars. Falls back to the first 40 chars of `tool_input.prompt` if `description` is empty.
- `started_at` — Unix seconds at write time.
- `tool_use_id` — used as the filename and persisted in the body for diagnostics.

Write is atomic via the existing `atomic_write` helper (write to `.tmp`, `mv`). Directory is created on demand with `mkdir -p`.

### Event handler updates

- `PreToolUse` (new branch for `tool_name == "Task"`): build the JSON payload, write to `state/<sid>-agents/<tool_use_id>.json`. The existing `-tool` write for the parent stays as-is.
- `PostToolUse` (new branch for `tool_name == "Task"`): `rm -f state/<sid>-agents/<tool_use_id>.json`. The existing `-tool` clear stays.
- `PostToolUseFailure` (same): identical removal.
- `SessionEnd`: clear list extended — `rm -rf state/<sid>-agents`. Also drop the legacy `state/<sid>-subagent` file (forward-compat with users mid-upgrade).
- `Stop`: **no change** to the agents directory. Keep the existing legacy `-subagent` cleanup so we don't leave a stale single-flag file behind.
- `SubagentStart`: keep the legacy single-flag write **only when** the hook does not receive a `tool_use_id` we have on file (i.e. as a defensive backup; in practice the Task PreToolUse fires first and this branch is dead code on current Claude builds). No-op otherwise.
- `SubagentStop`: defensive cleanup — if the payload carries a `tool_use_id`, remove that file; else no-op. Always rm the legacy `-subagent` file.

### Reset session state (manual escape hatch)

`ProcessMonitor.resetSessionState` already clears `-info`/`-busy`/`-error`/`-subagent`/`-tool`/`-plan`. Extend it to also `rm -rf state/<sid>-agents`. The legacy single-flag removal stays so this remains a true "reset everything".

## Monitor changes (`ProcessMonitor`)

### New state on `Session`

Add an array of structs:

```swift
struct ActiveSubagent: Equatable, Identifiable {
  let id: String          // tool_use_id
  let type: String        // subagent_type
  let summary: String     // trimmed description
  let startedAt: Date
}

// On Session:
var activeSubagents: [ActiveSubagent] = []
```

Sorted by `startedAt` ascending (oldest first) at read time — the oldest one is usually the one the user cares about most because it's closest to finishing.

### New reader: `refreshHookAgents(_ sid: String) -> [ActiveSubagent]`

Mirrors the existing `refreshHookTool` / `refreshHookSubagent` plumbing one-for-one:

1. List entries in `state/<sid>-agents/` (skip dotfiles, only `*.json`).
2. For each file: read, parse, build `ActiveSubagent`. Skip files that fail to parse (log once via `Clyde.log`).
3. Sort by `startedAt` ascending.
4. Defensive GC: drop entries older than 30 minutes from the returned list (UI only — file is left in place, single line logged). Prevents a crashed parent from leaving zombie rows; a real GC of the file itself happens at `SessionEnd` or via manual reset.

Called from the same reconcile pass that already refreshes `-tool` / `-plan` / `-subagent`.

### Backwards-compat: reading the legacy `-subagent` file

For one release we still surface the legacy single-flag marker if a session has it AND has an empty `state/<sid>-agents/` directory (i.e. the user upgraded Clyde but the running `claude` session is still on the older hook script). In that case the panel falls back to today's behavior: tool row shows `Agent · <type> · <dur>`, no expanded list. Users restart `claude` to get the new behavior; the marker style auto-flips at the next SessionStart because `HookInstaller` reinstalls the bundled hook on v19 bump.

### Fingerprint

Fold `activeSubagents` into the existing reconcile fingerprint so a parent that goes `0 → 3 → 5 → 2 → 0` subagents triggers re-emits at each transition. Hash of `(id, type, summary)` tuples in sort order is enough — duration ticks come from `TimelineView`, not from the fingerprint.

## UI changes (`SessionRow`)

The two-lines-per-agent variant (selected during brainstorming) renders as a fixed-structure block under the existing second line (tool / project path). Cases:

- **0 subagents**: row unchanged. Today's second-line behavior is preserved.
- **1 subagent**: row unchanged. The parent's `-tool` line already shows `Task · <summary> · <dur>` from v0.3.0; we don't render the expanded block for a single agent (avoids redundant noise).
- **2–3 subagents**: second line becomes `<N> agents · <dur-of-oldest>`. Below it, a left-bordered block (2px, purple `#7C5CFF` at 55% opacity) lists each agent as two lines:
  - Line 1 (12pt): `<type>` on the left, `<duration>` on the right (`HStack` with `Spacer`). Type styled `.medium` weight, tinted to match the border.
  - Line 2 (11.5pt, .secondary): trimmed summary. Single-line, `.lineLimit(1)`, `.truncationMode(.tail)`.
- **4+ subagents**: same block, first 3 rendered as above. Below them, an interactive label `+ <N-3> more agents` in the same purple. Tapping toggles a per-session expanded flag held in `AppViewModel.expandedSubagentSessions: Set<UUID>` (in-memory; resets on app relaunch). When expanded, all entries render and the label flips to `▴ Show less`. When the active count drops back to ≤3, the session is removed from the set automatically (auto-collapse).

Duration on each line uses the same `TimelineView(.periodic)` ticker as the parent's tool duration (1s cadence) and renders `m:ss` via the existing `Duration.format(_:)`.

### Accessibility

- Each subagent row gets a combined `.accessibilityElement(children: .combine)` with label `"<type>, <summary>, running <duration>"` and trait `.updatesFrequently` (consistent with the v0.3.1 a11y pass).
- The expand label has label `"<N> more agents"` / `"Show less"`, hint `"Double-tap to expand the subagent list"` / `"…to collapse"`, and trait `.isButton`.
- Block container is announced as `"<N> agents running"`.

### Motion

- Without reduce-motion: the block uses the same `.spring(response: 0.28, dampingFraction: 0.85)` insertion/removal as the existing rolling tool line. Expand/collapse toggles height with the same spring.
- With reduce-motion: opacity crossfade only (no height animation on appear, no rubberband on expand). Consistent with the v0.3.1 reduce-motion behavior.

### Mascot

No change. Mascot continues to reflect parent-session busy state. We do not introduce a "supervising subagents" sprite variant in this scope.

## Tests

- **Hook (smoke)**: extend the existing hook smoke script with a payload that fires `PreToolUse(Task)` twice (different `tool_use_id`), `PostToolUse(Task)` once, `SessionEnd`. Verify `state/<sid>-agents/` contains exactly one file after Post, and is gone after SessionEnd. Also verify the legacy `-subagent` file is removed on SessionEnd.
- **`ProcessMonitor` integration tests**: extend the temp-`stateDir` style used in `ProcessMonitorTests`. Drive `-info` for a session, then write 1, 3, then 5 fake `-agents/*.json` files, assert `session.activeSubagents` reflects each state, ordered by `started_at`.
- **GC**: write an `-agents/*.json` with `started_at` 31 minutes ago, assert the entry is dropped from `session.activeSubagents` but file remains on disk.
- **Backwards-compat**: write only the legacy `state/<sid>-subagent` file (no `-agents/` dir) — assert `activeSubagents` stays empty and the existing single-flag UI path is taken.
- **UI**: no unit tests planned (per CLAUDE.md, `ActivityLog`/UI follow the established no-coverage pattern). Manual scenarios added to the a11y / panel smoke checklist:
  - Fan-out 5 Task calls, verify list grows to 3 + `+2 more`, expand and collapse it, observe auto-collapse when count drops.
  - Reduce-motion on: verify no height animation on expand.
  - Mid-upgrade scenario: install v19 hook, leave an old `claude` session running with the legacy single-flag marker; verify the row falls back to the v0.2 behavior until next SessionStart.

## Hook script version + installer

- `# clyde-hook-version: 19`
- `HookInstaller.currentScriptVersion = 19`
- Header comment block updated to describe `state/<sid>-agents/` (sibling to `-tool`, `-plan`).
- `SessionEnd` clear-list comment updated.

## Out of scope

- No new event types (`SubagentStart`/`Stop` payloads are unchanged from the user's side; we just stop relying on them for the list).
- No timeline events for subagent start/stop (`ActivityLog` stays as-is — fan-out is too noisy to log per-agent).
- No sprite/mascot variant for "supervising".
- No persistence of expand state across app relaunch.
- No Cleat / containerized session support (separate roadmap item).

## File touch list

- `Clyde/Resources/clyde-hook.sh`
- `Clyde/Services/HookInstaller.swift`
- `Clyde/Services/ProcessMonitor.swift`
- `Clyde/Models/Session.swift`
- `Clyde/ViewModels/AppViewModel.swift`
- `Clyde/Views/Components/SessionRow.swift`
- `Tests/ClydeTests/ProcessMonitorTests.swift` (new cases)
- `docs/hook-smoke.md` (extend with parallel-Task scenario)
- `ROADMAP.md` (add the v0.3.x item, tick when shipped)
- `CHANGELOG.md` (add to `## [Unreleased]`)
