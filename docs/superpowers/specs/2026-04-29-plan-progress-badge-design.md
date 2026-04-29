# Plan Progress Badge — TaskCreated / TaskCompleted

**Date:** 2026-04-29
**Status:** Approved
**Scope:** `Clyde/Resources/clyde-hook.sh`, `Clyde/Services/HookInstaller.swift`, `Clyde/Services/ProcessMonitor.swift`, `Clyde/Models/Session.swift`, `Clyde/Views/Components/SessionRow.swift`, `Clyde/ViewModels/AppViewModel.swift`, hook + monitor + model tests.

## Goal

Surface that Claude is in plan-then-execute mode. When Claude calls the `TaskCreate` tool, Clyde shows a small inline `📋 N/M` badge on the affected session row, with a 24×3 px progress bar that fills as `TaskCompleted` events fire. The badge persists across turns (so a long plan that spans multiple `Stop`/prompt cycles keeps tracking) and switches to `✓ N/N` in green when all tasks are done. Clears on `SessionEnd`, dead-PID, or manual "Reset session state".

This is the second of two roadmap items in the v0.3.0 phase ("Richer session telemetry"). The first item — tool + duration in the panel — shipped in commits `1961afa..01917be`. This work reuses the same architectural patterns (state file → `refreshHookXxx` → `Session.xxx` → SwiftUI affordance) so the diff is small.

## Lifecycle

| Hook event | Effect on `state/<sid>-plan` |
|---|---|
| `TaskCreated` | Read existing record (initialize `{taskCount: 0, doneCount: 0}` if absent), `taskCount += 1`, atomic write back. Set `started_at` only on initial write. |
| `TaskCompleted` | Read existing record. If absent, no-op (lost initial event / race). Else `doneCount += 1`, atomic write back. |
| `SessionEnd` | Remove the record (added to the existing `rm -f` list). |
| `Stop`, `UserPromptSubmit`, all other events | Do not touch. Cross-turn persistence is a feature, not an oversight. |

There is no automatic "stale plan" cleanup. Edge cases (user pivots mid-plan, Claude never fires `TaskCompleted` for the remaining tasks, badge wedges at e.g. `2/5`) are handled by:

1. **PID liveness check** in `refreshHookPlans` — covers app crash / session death.
2. **Manual reset** via session row context menu ("Reset session state").

A time-based mtime cleanup is explicitly out of scope and will be reconsidered if real-world use surfaces stale-state friction.

## Hook script changes (`clyde-hook.sh` v18)

Bump `# clyde-hook-version: 18` and `HookInstaller.currentScriptVersion = 18` so existing v0.2.x installs auto-upgrade. Add `TaskCreated` and `TaskCompleted` to `HookInstaller.registeredHookEvents` so Claude Code actually delivers them (the v17 `PostToolUse` registration miss taught us this is required).

### New state file: `state/<sid>-plan`

JSON, atomic write via the existing `atomic_write` helper:

```json
{
  "session_id": "<uuid>",
  "pid": 12345,
  "task_count": 5,
  "done_count": 2,
  "started_at": 1714400000
}
```

`started_at` is unix epoch seconds. It's set on initial creation and never updated by subsequent events.

### `TaskCreated` case

Read the existing `-plan` file (if present) to extract `task_count` and `started_at`. If the file doesn't exist, initialize `task_count = 0`, `started_at = $TIMESTAMP`. Increment `task_count`, preserve `done_count` (or 0 on init), atomic-write the record.

Reading the existing file uses python3 with a simple grep fallback (mirroring the `extract_field` style established in v17). The python path:

```bash
read_plan_field() {
    local key=$1
    if [ ! -f "$STATE_DIR/$KEY-plan" ]; then
        printf '0'
        return
    fi
    python3 -c "
import json, sys
try:
    with open('$STATE_DIR/$KEY-plan') as f:
        d = json.load(f)
    print(d.get('$key', 0))
except Exception:
    print(0)
" 2>/dev/null || printf '0'
}
```

Bash branch:

```bash
TaskCreated)
    PLAN_TASK_COUNT=$(read_plan_field task_count)
    PLAN_DONE_COUNT=$(read_plan_field done_count)
    PLAN_STARTED_AT=$(read_plan_field started_at)
    [ "$PLAN_STARTED_AT" -eq 0 ] 2>/dev/null && PLAN_STARTED_AT=$TIMESTAMP
    PLAN_TASK_COUNT=$((PLAN_TASK_COUNT + 1))
    atomic_write "$STATE_DIR/$KEY-plan" \
        "{\"session_id\": \"$ESC_SID\", \"pid\": $CLAUDE_PID, \"task_count\": $PLAN_TASK_COUNT, \"done_count\": $PLAN_DONE_COUNT, \"started_at\": $PLAN_STARTED_AT}"
    ;;
```

### `TaskCompleted` case

Same read pattern. If `-plan` doesn't exist on disk, skip the write entirely (this means TaskCompleted fired without a prior TaskCreated, which shouldn't happen but we don't want to fabricate a `0/-1` record):

```bash
TaskCompleted)
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

### `SessionEnd` extension

Append `state/$KEY-plan` to the existing `rm -f` list. No other event clears the file.

### Header documentation

Update the `# Handled events:` block to document the two new events and the `-plan` lifecycle. Keep entries terse (one line each) consistent with the existing block.

## Swift model: `Session.activePlan`

New equatable value type and field on `Session`:

```swift
struct ActivePlan: Equatable {
    let taskCount: Int
    let doneCount: Int
    let startedAt: Date

    var isComplete: Bool { taskCount > 0 && doneCount >= taskCount }
    var progress: Double {
        taskCount > 0 ? Double(min(doneCount, taskCount)) / Double(taskCount) : 0
    }
}

var activePlan: ActivePlan? = nil
```

`progress` clamps `doneCount` to `taskCount` so a runaway TaskCompleted (e.g. Claude fires TaskCompleted twice for one task by accident) can't overflow the bar past 100%. `isComplete` triggers the green ✓ rendering.

`Session.init` does not take `activePlan` as an argument (defaults to `nil`).

## ProcessMonitor: `-plan` file ingestion

Mirror `refreshHookTools` one-for-one — same structure, same dead-PID / malformed pruning, same FSEvents-driven fast-path.

New private state on `ProcessMonitor`:

```swift
private var hookPlanByPID: [pid_t: ActivePlan] = [:]
```

New `refreshHookPlans()` method (~30 LOC, mirror of `refreshHookTools()`). Validates required fields (`pid: Int`, `task_count: Int`, `done_count: Int`, `started_at: Int`); rejects malformed; PID-prunes dead processes by removing the file from disk.

Wiring:

- Call `refreshHookPlans()` in both `poll()` and `pollHookState()`.
- In `pollHookState()`, include `planChanged` in the `if … applyBusyStateToSessions()` and `if … Task { await self.poll() }` guards (now 5 boolean OR'd flags — still readable per the v17 review).
- In `applyBusyStateToSessions()`, sync `updated[index].activePlan = hookPlanByPID[pid]` after the `activeTool` block.
- In `updatedSession(pid:newStatus:)`, set `existing.activePlan = hookPlanByPID[pid]` in all three branches (live row / revival / brand-new) — same pattern the v17 implementation extended for `activeTool`.

## SessionRow: inline plan badge

Add a small `PlanBadge` view (private, in the same file) and place it inside the existing `HStack(spacing: 6)` next to `Text(session.displayName)`:

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

    if isHovered { /* existing pencil button */ }
}
```

`PlanBadge` (private struct in the same file):

```swift
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
    }

    private var accent: Color {
        plan.isComplete
            ? Color(red: 0.47, green: 0.78, blue: 0.55)   // soft green
            : Color(red: 0.71, green: 0.55, blue: 0.86)   // soft purple
    }
}
```

Notes:

- **Inline, not a separate row.** Sits in the existing name HStack so the badge moves with the session row's drag/reorder and shares its hover state. No new layout primitive.
- **Color choice.** Purple accent `(0.71, 0.55, 0.86)` is distinct from busy-blue, attention-orange, error-red, and the new tool-line gray-65 used in v17. Green `(0.47, 0.78, 0.55)` matches the existing `SessionTheme.processingColor` aesthetic (saturated but not harsh).
- **Animation scope.** `.animation(value: plan.doneCount)` triggers only on `TaskCompleted`. The bar fills smoothly; the "📋 → ✓" emoji swap and the color shift happen in the same animation when `doneCount` reaches `taskCount`.
- **Width.** Total badge width ~52–58 pt depending on digit count. The session name has `lineLimit(1)` and will truncate before the badge clips, which is the right priority (badge is the thing carrying the new information).

## Reset session integration

`AppViewModel.resetSession(_:)` (line ~396) clears `-busy`, `-error`, `-subagent`, `-tool`. Append `-plan` to the same list so the context-menu "Reset session state" action is the manual escape hatch for stale plan state.

## Testing

### `SessionTests` (unit)

Add coverage for `ActivePlan`:

- `isComplete` is `false` for `0/0`, `0/5`, `2/5` (default cases).
- `isComplete` is `true` for `5/5`, `6/5` (overflow case).
- `progress` is `0.0` for `0/5`, `0.4` for `2/5`, `1.0` for `5/5` and `6/5` (clamped).
- `Session.activePlan` defaults to `nil`.

### `ProcessMonitorTests` (integration)

Five tests modeled on the v17 `-tool` tests:

1. Writing a `state/<sid>-plan` file populates `Session.activePlan` on the matching live row.
2. Removing the file clears `activePlan` on the next tick.
3. A `-plan` file whose PID is dead is removed from disk and ignored.
4. A `-plan` file with malformed JSON is removed and ignored.
5. Re-writing the file with an incremented `done_count` updates the in-memory `activePlan` (covers the increment-via-rewrite lifecycle the hook uses).

Add a `writeToolFile`-style helper at the top of the test class (`writePlanFile(in:sessionId:taskCount:doneCount:startedAt:pid:)`).

### Hook script smoke test

Add to the existing manual smoke recipe (no automated test layer for the hook):

- `TaskCreated` x N → `task_count` increments to N, `done_count` stays 0.
- `TaskCompleted` x M (M ≤ N) → `done_count` increments, `task_count` unchanged.
- `TaskCompleted` without prior `TaskCreated` → no `-plan` file created.
- `SessionEnd` → `-plan` file removed.
- Verify the JSON is parseable by `python3 -c "import json; json.load(open(...))"` after each write.

Use the same `exec -a claude bash …` wrapper from the v17 smoke test so `find_claude_pid` succeeds.

### Reset session test

If `AppViewModelTests` (or equivalent) covers `resetSession`, add an assertion that `state/<sid>-plan` is removed alongside the other state files. If no test exists, add one — `resetSession` is the user-facing escape hatch and we want a regression net around it.

## Out of scope

- **Time-based stale cleanup** (e.g. `mtime > 30 min` → prune). Deferred until real-world use shows it's needed.
- **Plan list / task content surface.** Payload schema for `TaskCreated` is undocumented and the value of showing task titles isn't worth the complexity of empirically reverse-engineering them.
- **`TaskUpdated` event handling.** Not mentioned in the Claude Code docs we reviewed; ignored.
- **Cross-session plan correlation** (e.g. parent + subagent both running tasks). Per-PID is the unit of tracking; subagent task creation rolls up to the parent session's `-plan` file via the existing `find_claude_pid` walk.
- **Notifications / sound on plan completion.** Existing `NotificationService` "ready" sound covers Stop; plan completion doesn't get its own audio.

## Migration notes

- Hook auto-upgrade: `HookInstaller` reinstalls when `installed_version < currentScriptVersion`. Bumping to v18 + appending `TaskCreated`/`TaskCompleted` to `registeredHookEvents` is sufficient — `~/.claude/settings.json` will be rewritten on the user's next Clyde launch.
- Existing `-plan` files from a hypothetical previous Clyde process don't exist (this is the first version that writes them), so no migration needed.
