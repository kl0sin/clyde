# Coachmarks — First-Run Tour Design

**Date:** 2026-04-29
**Status:** Approved
**Scope:** New `CoachmarkController` service, `CoachmarkPopover` view, `.coachmarkAnchor(_:)` view modifier, wiring inside `ExpandedRootView` / `SessionListView` / `ExpandedHeader`, Settings → General "Replay welcome tour" button.
**Roadmap item:** `[ ] Coachmarks / "how to use" tooltip on first panel expand` (v0.3.0+) and `[ ] Coachmark re-trigger from Settings ("Replay welcome tour")` — bundled.

## Goal

After the existing `OnboardingView` modal hands the user off to the menu-bar app, the panel itself is silent — controls are unlabeled, the live tool indicator and plan badge from v0.3.0 are easy to miss, and the `⌃⌘C` global hotkey is undiscoverable. This spec adds an in-context tour: a sequence of native popovers anchored to real UI elements that fires on first panel expand and walks the user through four anchors.

The tour is one-shot, persistent, dismissable mid-flight, replayable from Settings, and does not re-trigger for users upgrading from a prior version.

## Non-goals

- Replacing or modifying the existing `OnboardingView` modal. Coachmarks are a separate stage that runs *after* onboarding is dismissed.
- Tour-style dimming of the panel or a guided-tour next/back navigation. Each popover is a standalone anchored card; the user advances or skips, never goes backwards.
- Coachmarks tied to specific events ("first time a session goes Needs Input"). The tour is a one-pass first-run experience, not an ambient hint system.
- Localization. Copy is English-only for v0.3.x.
- Accessibility-pass scope. VoiceOver labels for the rest of the app are tracked separately on the roadmap; this spec only ensures the popovers themselves are reachable by VoiceOver (native `.popover` handles this for free).

## User experience

The tour fires the first time the user opens the expanded panel after the onboarding modal has been dismissed. Four anchor points, in order:

1. **Session row.** Title: *Live Claude sessions.* Body: "Each row is a Claude Code session running on your Mac. The pill on the right shows status — Working, Ready, or Needs Input. Click a row to jump to its terminal."
2. **Tool/plan line** (the second line of a session row). Title: *See what Claude is doing.* Body: "When Claude calls a tool, the second line shows it live — `Edit · MyFile.swift · 3s`. If Claude maps out a multi-step plan, a progress badge tracks it across turns."
3. **Snooze button** (header). Title: *Mute alerts on demand.* Body: "Going into a meeting or demo? Snooze pauses sounds and notifications until you toggle it back on."
4. **Collapse button** (header). Title: *Hide and reopen fast.* Body: "Collapse to the floating widget any time. Press `⌃⌘C` from anywhere to open or hide Clyde — no menu-bar click needed."

Each popover footer shows a `1 of 4` counter on the left (with-sessions branch only — see below), a `Skip tour` link and a `Got it ›` primary button on the right. The final popover swaps the primary button to `Done ✓`.

### Empty-state branch

If the user opens the panel before any Claude session has been observed, the session list is empty and steps 1–2 have nothing to anchor to. In that case the tour swaps to a three-step branch:

1. **Empty session list.** Title: *No sessions yet.* Body: "Start a Claude session in your terminal — Clyde will pick it up automatically and show it right here."
2. **Snooze button** — same as step 3 above.
3. **Collapse button** — same as step 4 above.

Empty-state popovers do **not** display a counter — `counterText` is `nil` for that branch — to avoid the awkward "1 of 3" framing for what is effectively a degraded tour. Once the empty-state branch finishes (or is skipped), `coachmarksShown` is set to true. The session-row and tool/plan popovers are not deferred for a later run — the user has already seen the tour and explicitly chose its abbreviated form by opening the panel without sessions running. (Alternative explored and rejected: deferring the tour until the first session appears. Risk of firing days after install with no context outweighs the value.)

### Mid-tour interruptions

If the user closes the panel mid-tour (clicks the menu-bar icon, loses focus, etc.), the in-memory `currentStep` is cleared but `coachmarksShown` is **not** persisted. Next time the panel opens, the tour starts again from step 1. This is intentional: the alternative — resuming on the step the user left off — requires the user to remember "I was on 3 of 4," which most won't.

If the user dismisses via `Skip tour`, the tour ends immediately and `coachmarksShown` is persisted as true. Skipping is identical to completing: never shows again until replayed.

### Replay from Settings

Settings → General gains a `Replay welcome tour` button (placed below the existing keyboard-shortcut help, above the polling-interval row). Clicking it clears `coachmarksShown`. The Settings view then dispatches based on panel visibility: if `appViewModel.isCollapsed == false`, it calls `coachmarks.maybeStart(hasSessions: ...)` immediately and the popover appears in the open panel; if the panel is collapsed, no further action — the existing `ExpandedRootView.onAppear` handler will pick it up on the next expand. In the collapsed case, a subtle inline confirmation label ("Tour will replay next time you open the panel.") appears under the button and clears when the panel is next opened (or when the user re-opens Settings later, whichever comes first).

## Architecture

Coachmarks are a thin state layer over view modifiers, not a new long-lived service in the app's bootstrap. State lives in two UserDefaults flags and one in-memory `@Published` step counter. No timers, no background work, no IPC.

### Components

| Component | Role | File |
|---|---|---|
| `CoachmarkController` | Owns `@Published var currentStep: CoachmarkStep?`, decides when the tour starts, advances steps, persists the "shown" flag. | `Clyde/Services/CoachmarkController.swift` (new) |
| `CoachmarkStep` | Enum with associated content (title, body, counter, isFinal). One source of truth for tour copy. | Same file. |
| `CoachmarkPopover` | Pure SwiftUI view rendering a step's content. Title + body + footer (counter / skip / advance). No logic. | `Clyde/Views/Components/CoachmarkPopover.swift` (new) |
| `.coachmarkAnchor(_:identity:)` | View modifier that attaches a native `.popover` whose `isPresented` binding tracks `controller.currentStep == step && controller.shouldAnchor(step, identity:)`. | Same file as the popover view. |

The controller is constructed once and stored on `AppViewModel` (mirroring `NotificationService`). It is injected via `.environmentObject(...)` on the root of the expanded panel and on the Settings window host.

### State

Two UserDefaults keys, namespaced via `private enum Keys` inside `CoachmarkController` (the dominant pattern in newer Clyde services — `NotificationService`, `PushService`):

- `coachmarksShown: Bool` — global one-shot flag. `true` blocks future runs until cleared by `replay()`.
- `coachmarksMigrated: Bool` — sentinel for the existing-user migration. Set true after the first run of `runMigrationIfNeeded()`, regardless of outcome.

In-memory only:
- `currentStep: CoachmarkStep?` — drives all popovers.
- `claimedAnchorID: AnyHashable?` — set when a step's first anchor wins; cleared on advance/skip/reset.

## Data flow

### Launch

```
AppDelegate.applicationDidFinishLaunching
  → appViewModel.coachmarks.runMigrationIfNeeded()
      // idempotent. If !coachmarksMigrated:
      //   if onboardingShown → coachmarksShown = true   (existing user, suppress)
      //   coachmarksMigrated = true
```

The migration runs synchronously, before any window is shown. It exists to ensure that users upgrading from a Clyde version without coachmarks (so `coachmarksShown` defaults to false on first read) are not subjected to a tour they don't need. New installs have `onboardingShown == false` at this point, so the migration writes only the sentinel and leaves `coachmarksShown == false`.

### First panel expand

```
user clicks menu-bar icon → expandedPanel becomes visible
  → ExpandedRootView.onAppear
      coachmarks.maybeStart(hasSessions: !appViewModel.sessions.isEmpty)
          guard !coachmarksShown, onboardingShown else: return
          currentStep = hasSessions ? .sessionRow : .emptyState
```

### Step transitions

```
.sessionRow ──advance──▶ .toolPlan ──advance──▶ .snooze ──advance──▶ .collapse ──advance──▶ done
.emptyState ─────────────advance──▶ .snooze ──advance──▶ .collapse ──advance──▶ done

done: currentStep = nil; coachmarksShown = true   (persisted)
skip: same as done
reset: currentStep = nil; coachmarksShown unchanged   (panel closed mid-tour)
```

### Anchor claim

Multiple session rows share the same `CoachmarkStep.sessionRow` anchor. The controller exposes:

```swift
func shouldAnchor(_ step: CoachmarkStep, identity: AnyHashable) -> Bool
```

The first call for a given step claims `claimedAnchorID = identity` and returns true; subsequent calls for the same step return true only if the identity matches the claim. On `advance()` / `skip()` / `reset()` the claim is cleared. SwiftUI re-render that drops the claimed row simply makes the popover disappear; the next render picks a new first-anchor.

## Component interfaces

### CoachmarkController

```swift
@MainActor
final class CoachmarkController: ObservableObject {
    @Published private(set) var currentStep: CoachmarkStep?

    init(defaults: UserDefaults = .standard, onboardingShown: @escaping () -> Bool)

    func runMigrationIfNeeded()
    func maybeStart(hasSessions: Bool)
    func advance()
    func skip()
    func reset()
    func replay()                            // clears `coachmarksShown`; caller decides whether to call `maybeStart` based on panel state

    func shouldAnchor(_ step: CoachmarkStep, identity: AnyHashable) -> Bool

    private enum Keys {
        static let shown = "coachmarksShown"
        static let migrated = "coachmarksMigrated"
    }
}

enum CoachmarkStep: String, CaseIterable {
    case sessionRow, toolPlan, snooze, collapse, emptyState

    var title: String        { ... }
    var body: String         { ... }
    var counterText: String? { ... }   // "1 of 4"; nil for empty-state branch
    var isFinal: Bool        { ... }   // → "Done ✓" instead of "Got it ›"
}
```

### CoachmarkPopover

Pure View. Inputs: `step: CoachmarkStep`, `onAdvance: () -> Void`, `onSkip: () -> Void`. Renders a fixed-width (~240pt) card matching system popover content conventions: title in `.headline`, body in `.callout` with `.secondary` foreground, footer HStack with counter on the left and skip + advance on the right.

### .coachmarkAnchor(_:identity:)

```swift
extension View {
    func coachmarkAnchor(
        _ step: CoachmarkStep,
        identity: AnyHashable = AnyHashable(UUID())
    ) -> some View
}
```

Reads `CoachmarkController` from the environment. Internally attaches `.popover(isPresented: binding)` where the binding's `get` is `controller.currentStep == step && controller.shouldAnchor(step, identity:)` and the `set` advances on dismiss. Default identity is a per-call `UUID()` for single-anchor steps (snooze, collapse, empty-state); session-row and tool-plan callsites pass `row.id` to enable first-claim-wins.

## Wiring

| File | Change |
|---|---|
| `Clyde/ViewModels/AppViewModel.swift` | Add `let coachmarks: CoachmarkController` initialized with `onboardingShown: { UserDefaults.standard.bool(forKey: AppDelegate.onboardingShownKey) }`. |
| `Clyde/App/AppDelegate.swift` | Call `appViewModel.coachmarks.runMigrationIfNeeded()` once during `applicationDidFinishLaunching`, after the `onboardingShown` flag has been read. Inject `appViewModel.coachmarks` as `.environmentObject` on the hosts of `ExpandedRootView` and `SettingsView`. |
| `Clyde/Views/ExpandedRootView.swift` | `.onAppear { coachmarks.maybeStart(hasSessions: !sessions.isEmpty) }` and `.onDisappear { coachmarks.reset() }`. |
| `Clyde/Views/SessionListView.swift` (or wherever each `SessionRow` is rendered) | Apply `.coachmarkAnchor(.sessionRow, identity: row.id)` to the row body and `.coachmarkAnchor(.toolPlan, identity: row.id)` to the tool/plan line subview. |
| Empty-state placeholder in the session list | `.coachmarkAnchor(.emptyState)`. |
| `ExpandedHeader` snooze button | `.coachmarkAnchor(.snooze)`. |
| `ExpandedHeader` collapse button | `.coachmarkAnchor(.collapse)`. |
| `Clyde/Views/SettingsView.swift` (General tab) | Add a "Replay welcome tour" button. On click: `coachmarks.replay()`, then if `!appViewModel.isCollapsed` also `coachmarks.maybeStart(hasSessions: !appViewModel.sessions.isEmpty)`. Render an inline confirmation label when `appViewModel.isCollapsed == true`. |

No changes to `AppDelegate`'s window management, `ProcessMonitor`, hooks, or the activity timeline.

## Error handling

Coachmarks are eye-candy. No failure mode in this code path can block the panel, the session list, or the rest of the app. All failure surfaces degrade to "tour didn't show" or "tour showed once too many" — never to a crash, a stuck UI, or a corrupted state file.

- **UserDefaults read on a missing key** returns `false` for `Bool` per `UserDefaults` contract. Default behavior is correct: missing `coachmarksShown` → tour eligible; missing `coachmarksMigrated` → migration runs once.
- **Migration races** are impossible because `runMigrationIfNeeded` runs on `@MainActor` in `applicationDidFinishLaunching`, before any window can call `maybeStart`.
- **Panel teardown mid-popover** is handled by SwiftUI's `.popover` lifecycle. `reset()` in `.onDisappear` clears `currentStep`; the popover closes naturally.
- **Session list mutation mid-tour** is handled by the first-claim-wins anchor: if the claimed row disappears, the popover unmounts. Acceptable degradation.
- **Replay with the panel collapsed** clears `coachmarksShown` and posts a confirmation label. The next `onAppear` triggers the tour.

Anything unusual (e.g. UserDefaults write failure, which `set(_:forKey:)` doesn't surface) is opaque to this code path. No `Logger` calls are required for this layer.

## Testing

Targets the controller's pure logic. SwiftUI views and modifiers are not unit-tested — same precedent as `ActivityLog`. Test file: `Tests/ClydeTests/CoachmarkControllerTests.swift`.

Pattern: real `CoachmarkController` with an injected `UserDefaults(suiteName:)` (per-test temp suite, removed in `tearDown`) and an injected `onboardingShown: () -> Bool` closure. No mocks. Mirrors `ProcessMonitorTests` style.

| Test | Setup | Assertion |
|---|---|---|
| `migration_marksExistingUsersAsShown` | `onboardingShown=true`, `coachmarksMigrated=false`, `coachmarksShown=false` | `runMigrationIfNeeded()` → `coachmarksShown=true`, `coachmarksMigrated=true` |
| `migration_skipsFreshInstall` | empty suite | `coachmarksShown=false`, `coachmarksMigrated=true` |
| `migration_isIdempotent` | run, mutate flags, run again | second run no-op |
| `maybeStart_blockedIfShown` | `coachmarksShown=true` | `currentStep == nil` |
| `maybeStart_blockedIfOnboardingNotShown` | `onboardingShown=false` | `currentStep == nil` |
| `maybeStart_picksSessionRow_whenSessionsExist` | clean, `hasSessions=true` | `currentStep == .sessionRow` |
| `maybeStart_picksEmptyState_whenNoSessions` | clean, `hasSessions=false` | `currentStep == .emptyState` |
| `advance_walksFullTour_withSessions` | start at `.sessionRow` | `.toolPlan → .snooze → .collapse`, fourth advance: `nil` + `coachmarksShown=true` |
| `advance_walksEmptyStateBranch` | start at `.emptyState` | `.snooze → .collapse → nil`, `coachmarksShown=true` |
| `skip_marksAsShownAndClears` | mid-tour | `currentStep=nil`, `coachmarksShown=true` |
| `reset_clearsStepWithoutPersisting` | mid-tour | `currentStep=nil`, `coachmarksShown=false` |
| `replay_clearsFlagWithoutStarting` | `coachmarksShown=true` | after `replay()`: flag cleared, `currentStep == nil` (caller is responsible for starting) |
| `replay_thenMaybeStart_restartsTour` | `coachmarksShown=true` | `replay()` then `maybeStart(hasSessions: true)`: `currentStep == .sessionRow` |
| `shouldAnchor_firstClaimWins` | step active | first call → true; second with different identity → false; after `advance()`: claim cleared |

~14 synchronous tests, milliseconds each. Fits into the existing `swift test` run.

### Manual smoke (add to `docs/hook-smoke-test.md` as a new top-level section, "Coachmark scenarios")

1. **Fresh install.** `defaults delete com.kl0sin.Clyde`, launch, dismiss onboarding, open panel → tour fires from `.sessionRow` (or `.emptyState` if no sessions running).
2. **Existing user upgrade path.** `defaults write com.kl0sin.Clyde onboardingShown -bool true`, `defaults delete com.kl0sin.Clyde coachmarksShown coachmarksMigrated`, launch → tour does **not** fire; after launch, `defaults read` shows `coachmarksMigrated = 1`, `coachmarksShown = 1`.
3. **Replay.** Settings → General → "Replay welcome tour" with panel open → tour fires immediately. With panel collapsed → confirmation label appears, tour fires on next expand.
4. **Mid-tour close.** Open panel, advance to step 2, click menu-bar icon to close, reopen → tour starts again from step 1.
5. **Skip.** Open panel, click `Skip tour` on any step → tour closes, `coachmarksShown == 1`. Reopen panel → no tour.
