# Accessibility Pass Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add VoiceOver labels, traits, hints, and values to every interactive UI surface in Clyde; mark decorative views (`ClydeAnimationView`, status indicators inside combined rows) `.accessibilityHidden(true)`; thread `@Environment(\.accessibilityReduceMotion)` through every auto-running motion animation so users with reduce-motion enabled see no pulsing, sliding, or sprite playback.

**Architecture:** No new types. Each view that owns an animation reads `@Environment(\.accessibilityReduceMotion)` and gates its `.animation(...)` modifiers via inline ternary (`reduceMotion ? nil : .spring(...)`). Each view that exposes interactive controls or status receives `.accessibilityLabel/Hint/Value` modifiers. The pixel-art `ClydeAnimationView` becomes `.accessibilityHidden(true)` and skips frame advancement when reduce-motion is on.

**Tech Stack:** Swift 5.9, SwiftUI (macOS 13+), AppKit (`setAccessibilityValue` on the menu-bar `NSStatusItem`).

**Source spec:** `docs/superpowers/specs/2026-04-30-accessibility-pass-design.md`

---

## File Structure

**Modify only — no new files.**

- `Clyde/Views/ClydeAnimationView.swift` — `.accessibilityHidden(true)` on body; gate sprite frame advance on reduce-motion.
- `Clyde/Views/WidgetView.swift` — combined element on widget root; reduce-motion on dominant-state crossfade and pulsing block.
- `Clyde/Views/ExpandedRootView.swift` — reduce-motion on error banner slide.
- `Clyde/Views/ExpandedView.swift` — reduce-motion on `HookHealthBanner` appear; combined accessibility label on the banner.
- `Clyde/Views/Components/ExpandedHeader.swift` — combined stats row label; snooze value; reduce-motion on header state color (already color, leave per spec).
- `Clyde/Views/Components/SessionRow.swift` — expanded combined label including tool/plan, edit-mode button labels, reduce-motion on tool/plan slide / state flash / pulse / scale beat.
- `Clyde/Views/Components/SessionListView.swift` — reduce-motion exemption for drag-and-drop animations (per spec, *leave* — no change needed).
- `Clyde/Views/Components/ActivityTimelineView.swift` — expand toggle label/value/hint; per-entry combined labels; reduce-motion on expand animation.
- `Clyde/Views/Components/SummaryBar.swift` — combined label; reduce-motion on status pill pulse.
- `Clyde/Views/Components/EmptyStateView.swift` — combined label.
- `Clyde/Views/OnboardingView.swift` — modal trait; combined feature-card labels.
- `Clyde/Views/SettingsView.swift` — tab button `.isSelected` trait; polling-interval slider value; replay button hint.
- `Clyde/Views/Components/SessionStatusIndicator.swift` — `.accessibilityHidden(true)` (parent `SessionRow` carries the status).
- `Clyde/Views/Components/PlanBadge.swift` — `.accessibilityHidden(true)` (parent `SessionRow` carries the progress).
- `Clyde/Views/TitleBar.swift` — reduce-motion on header state color (already color, leave; *no change*).
- `Clyde/App/AppDelegate.swift` — `setAccessibilityValue` on the menu-bar status item, refreshed on count/state changes.
- `Clyde/Services/NotificationService.swift` — expose a `snoozeRemainingMinutes: Int?` computed property if not already present (used by header snooze value).
- `docs/hook-smoke-test.md` — append "Accessibility scenarios" section.
- `ROADMAP.md` — tick the accessibility item with a one-line summary.
- `CHANGELOG.md` — add an Unreleased bullet.

---

## Task 1: Reduce-motion plumbing (reference impl on `ClydeAnimationView`)

Sets the pattern the remaining tasks follow. Establishes the `@Environment(\.accessibilityReduceMotion)` thread and applies it to one site so the rest is rote.

**Files:**
- Modify: `Clyde/Views/ClydeAnimationView.swift`

- [ ] **Step 1: Add the environment binding.**

In `ClydeAnimationView`, near the top of the struct properties (above `let state: ClydeState`):

```swift
@Environment(\.accessibilityReduceMotion) private var reduceMotion
```

- [ ] **Step 2: Mark the view decorative.**

At the very end of the `body`'s top-level view chain, append:

```swift
.accessibilityHidden(true)
```

It goes outside the `TimelineView` block, on whatever the body returns at top level (likely a `Canvas` or a `ZStack` wrapping it).

- [ ] **Step 3: Gate the frame timer.**

The frame counter is updated inside the `TimelineView(.animation(minimumInterval: 0.3))` closure (around line 121). Guard the per-tick frame advance:

```swift
TimelineView(.animation(minimumInterval: 0.3)) { timeline in
    let frame = reduceMotion ? 0 : computeFrame(at: timeline.date)
    // ...rest of the rendering uses `frame`
}
```

If the timeline's `computeFrame` (or whatever it's named) is implemented as a `private func`, the easier change is at its single call site: replace whatever's already there with the ternary above. The point is: when `reduceMotion` is true, frame is always 0 — the sprite stays on its first pose.

For the `withAnimation { ... }` blocks at lines 370–393 (antenna glow, sleeping "zzz"), wrap each:

```swift
if reduceMotion {
    /* set the final state directly, no animation */
    antennaGlowOpacity = targetOpacity
} else {
    withAnimation(.easeInOut(duration: 0.6)) {
        antennaGlowOpacity = targetOpacity
    }
}
```

Apply this pattern to each `withAnimation` site in `updateAnimations()` (lines 367–394).

- [ ] **Step 4: Build.**

Run: `swift build`
Expected: succeeds.

- [ ] **Step 5: Commit.**

```bash
git add Clyde/Views/ClydeAnimationView.swift
git commit -m "feat(a11y): reduce-motion gating and hidden flag on ClydeAnimationView"
```

Body: explain that the mascot is purely decorative so it's hidden from VoiceOver, and that reduce-motion freezes the sprite on its first frame plus stops antenna/sleeping micro-animations.

---

## Task 2: Roll out reduce-motion to remaining animation sites

Sixteen remaining `.animation(...)` / `withAnimation { ... }` sites (per audit grep). Each gets `@Environment(\.accessibilityReduceMotion) private var reduceMotion` if the view doesn't already have it, then the inline ternary on each `.animation(...)` modifier.

**Files:**
- Modify: `Clyde/Views/WidgetView.swift`, `Clyde/Views/ExpandedRootView.swift`, `Clyde/Views/Components/ExpandedHeader.swift`, `Clyde/Views/Components/SessionRow.swift`, `Clyde/Views/Components/ActivityTimelineView.swift`, `Clyde/Views/Components/SummaryBar.swift`, `Clyde/Views/ExpandedView.swift`.

Per-site policy (matches the spec table). Each sub-step is "open file, find line, change line, build, commit."

- [ ] **Step 1: WidgetView dominant-state crossfade.**

In `Clyde/Views/WidgetView.swift`, add `@Environment(\.accessibilityReduceMotion) private var reduceMotion` near the top of the struct.

Around line 169:

```swift
.animation(.easeInOut(duration: 0.35), value: viewModel.clydeState)
```

becomes:

```swift
.animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: viewModel.clydeState)
```

Per spec, color crossfades stay (this *is* color) — actually re-checking: this animates `value: viewModel.clydeState` which drives a color/glow change. **Per spec rule of thumb: color-based stays, motion-based goes.** Leave this one ALONE — drop the change. The reduce-motion environment binding still gets added for the next site.

- [ ] **Step 2: WidgetView pulsing block.**

In the same file at line 212, the pulsing uses `TimelineView(.animation)`. Gate the pulse opacity computation on `reduceMotion`:

```swift
TimelineView(.animation) { timeline in
    let pulseOpacity: Double = reduceMotion ? 1.0 : computePulse(at: timeline.date)
    // ...
}
```

When reduce-motion is on, the pulse block stays at full opacity — no oscillation.

- [ ] **Step 3: ExpandedRootView error banner.**

`Clyde/Views/ExpandedRootView.swift`, add the environment binding near the top, then change the existing modifiers around lines 21–24:

```swift
.transition(.move(edge: .top).combined(with: .opacity))
// ...
.animation(.easeOut(duration: 0.2), value: appViewModel.lastError)
```

to:

```swift
.transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
// ...
.animation(reduceMotion ? .none : .easeOut(duration: 0.2), value: appViewModel.lastError)
```

(Note: `.none` for `Animation?` parameter — equivalent to `nil`.)

- [ ] **Step 4: ExpandedView HookHealthBanner.**

In `Clyde/Views/ExpandedView.swift`, add the environment binding to `ExpandedView`. Find the `if let issue = appViewModel.hookHealthIssue` block — its appearance is currently animated by `.transition` somewhere. Replace any motion transition with opacity when `reduceMotion`:

```swift
if let issue = appViewModel.hookHealthIssue {
    HookHealthBanner(...)
        .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
}
```

If no `.transition` currently exists on the banner (only an implicit fade), no change is needed here — verify by reading `ExpandedView.swift:24-34`.

- [ ] **Step 5: ExpandedHeader header state color.**

`Clyde/Views/Components/ExpandedHeader.swift` line 89:

```swift
.animation(.easeInOut(duration: 0.30), value: clydeState)
```

Per spec: this animates a color/glow tint, **leave it alone**. No change. Skip this site.

- [ ] **Step 6: SessionRow tool/plan line slide.**

`Clyde/Views/Components/SessionRow.swift`. Add the environment binding near the top of the struct.

Line 132 (the spec's table refers to line 131; it's the `.animation(.spring(...))` on the tool/plan ZStack):

```swift
.animation(.spring(response: 0.28, dampingFraction: 0.85),
           value: session.activeTool != nil)
```

becomes:

```swift
.animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.85),
           value: session.activeTool != nil)
```

Also, the `transition(.move(...))` on the tool line itself (line 113) and the project-path line (line 123) should swap to opacity transitions when `reduceMotion`:

```swift
.transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
// ...
.transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
```

- [ ] **Step 7: SessionRow stateFlash + status pill pulse + scale beat.**

Several `withAnimation { ... }` blocks plus the `.repeatForever` pulse. Pattern:

For `withAnimation` blocks at lines ~205, 209, 507, 512:

```swift
if reduceMotion {
    stateFlash = false  // or whatever the post-animation state is
} else {
    withAnimation(.easeIn(duration: 0.15)) {
        stateFlash = true
    }
}
```

Apply the same pattern at each `withAnimation` site, using the post-animation target value as the immediate assignment when reduce-motion is on.

For the `.repeatForever()` pill pulse around line 218:

```swift
.animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pillPulse)
```

becomes:

```swift
.animation(reduceMotion ? nil : .easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pillPulse)
```

For the TimelineView scale-beat around line 472, gate the scale computation:

```swift
TimelineView(.animation) { timeline in
    let scale: CGFloat = reduceMotion ? 1.0 : computeBeat(at: timeline.date)
    // ...
}
```

- [ ] **Step 8: SessionListView drag indicator.**

`Clyde/Views/Components/SessionListView.swift` lines 59–60. Per spec: drag-and-drop is user-initiated, **leave alone**. No change.

- [ ] **Step 9: ActivityTimelineView expand toggle.**

`Clyde/Views/Components/ActivityTimelineView.swift`. Add the environment binding. Around line 25:

```swift
withAnimation(.easeInOut(duration: 0.22)) { expanded.toggle() }
```

becomes:

```swift
if reduceMotion {
    expanded.toggle()
} else {
    withAnimation(.easeInOut(duration: 0.22)) { expanded.toggle() }
}
```

- [ ] **Step 10: SummaryBar status pill pulse.**

`Clyde/Views/Components/SummaryBar.swift`. Add the environment binding. Around line 74:

```swift
.animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: pulse)
```

becomes:

```swift
.animation(reduceMotion ? nil : .easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: pulse)
```

- [ ] **Step 11: Build + commit.**

Run: `swift build`
Expected: succeeds.

```bash
git add Clyde/Views/WidgetView.swift Clyde/Views/ExpandedRootView.swift Clyde/Views/ExpandedView.swift Clyde/Views/Components/SessionRow.swift Clyde/Views/Components/ActivityTimelineView.swift Clyde/Views/Components/SummaryBar.swift
git commit -m "feat(a11y): respect reduce-motion across panel animations"
```

Body: list which animations were gated (slide, pulse, scale beat, expand toggle, error banner) and which were intentionally left alone (color crossfades, drag-and-drop).

---

## Task 3: `.accessibilityHidden(true)` on remaining decorative views

`SessionStatusIndicator` and `PlanBadge` carry information that's already in their parent `SessionRow`'s combined label. They should be hidden from VoiceOver to avoid double-announcement.

**Files:**
- Modify: `Clyde/Views/Components/SessionStatusIndicator.swift`
- Modify: `Clyde/Views/Components/PlanBadge.swift`

- [ ] **Step 1: Hide `SessionStatusIndicator`.**

At the end of the body's top-level view chain in `SessionStatusIndicator.swift`:

```swift
.accessibilityHidden(true)
```

- [ ] **Step 2: Hide `PlanBadge`.**

At the end of the body's top-level view chain in `PlanBadge.swift`:

```swift
.accessibilityHidden(true)
```

- [ ] **Step 3: Build + commit.**

Run: `swift build`
Expected: succeeds.

```bash
git add Clyde/Views/Components/SessionStatusIndicator.swift Clyde/Views/Components/PlanBadge.swift
git commit -m "feat(a11y): hide decorative status indicator and plan badge from VoiceOver"
```

Body: explain that both are visual-only signals whose content is already in the parent `SessionRow`'s combined accessibility label, so exposing them as separate VO elements would double-announce.

---

## Task 4: Menu-bar status item value

Make the `NSStatusItem` announce its current state (e.g. "2 working, 1 ready, 1 needs attention") on top of its label and role.

**Files:**
- Modify: `Clyde/App/AppDelegate.swift`

- [ ] **Step 1: Find the status item refresh path.**

Run: `grep -n "setAccessibilityLabel\|setAccessibilityRole\|refreshMenuBar\|statusItem" Clyde/App/AppDelegate.swift | head -20`

The current setup is at lines 364–365:

```swift
button.setAccessibilityLabel("Clyde — Claude Code session monitor")
button.setAccessibilityRole(.button)
```

The status item is refreshed whenever counts/state change via a Combine subscription on `appViewModel.processMonitor.objectWillChange` (around lines 372–378).

- [ ] **Step 2: Add a value-summary helper.**

In `AppDelegate.swift`, near the bottom of the class (or in an extension at the end of the file), add:

```swift
@MainActor
private func currentStatusItemValue() -> String {
    let sessions = appViewModel.processMonitor.sessions.filter { !$0.isGhost }
    if sessions.isEmpty { return "No active sessions" }
    let attention = sessions.filter { $0.needsAttention }.count
    let working = sessions.filter { $0.status == .busy && !$0.needsAttention }.count
    let ready = sessions.count - attention - working
    var parts: [String] = []
    if attention > 0 { parts.append("\(attention) needs attention") }
    if working > 0 { parts.append("\(working) working") }
    if ready > 0 { parts.append("\(ready) ready") }
    return parts.joined(separator: ", ")
}
```

- [ ] **Step 3: Set the accessibility value on every refresh.**

Find the `refreshMenuBarItem()` (or whatever the existing refresh function is named — search for the function that touches `button.image` or the status-item icon). In its body, add:

```swift
button.setAccessibilityValue(currentStatusItemValue())
```

This ensures the value is updated together with the icon, so VoiceOver always announces the current state.

- [ ] **Step 4: Build + commit.**

Run: `swift build`
Expected: succeeds.

```bash
git add Clyde/App/AppDelegate.swift
git commit -m "feat(a11y): announce live counts via menu-bar accessibility value"
```

Body: VoiceOver users hear "Clyde, 2 working, 1 ready, button" on focus, refreshed on every state change.

---

## Task 5: WidgetView combined label

Treat the menu-bar capsule as one accessible element with a label that summarizes the same information as the menu-bar status item.

**Files:**
- Modify: `Clyde/Views/WidgetView.swift`

- [ ] **Step 1: Add `.accessibilityElement(children: .combine)` and label.**

At the end of `WidgetView.body`'s top-level view chain (the outer `HStack`):

```swift
.accessibilityElement(children: .combine)
.accessibilityLabel(viewModel.widgetAccessibilityLabel)
.accessibilityHint("Click to expand panel")
.accessibilityAddTraits(.isButton)
```

- [ ] **Step 2: Add `widgetAccessibilityLabel` to `AppViewModel`.**

In `Clyde/ViewModels/AppViewModel.swift`, near `hasLiveSessions`:

```swift
/// Plain-language summary of the menu-bar capsule's current state, used as
/// the VoiceOver label on `WidgetView` and (transitively) the status item.
var widgetAccessibilityLabel: String {
    let sessions = processMonitor.sessions.filter { !$0.isGhost }
    if sessions.isEmpty { return "Clyde, no active sessions" }
    let attention = sessions.filter { $0.needsAttention }.count
    let working = sessions.filter { $0.status == .busy && !$0.needsAttention }.count
    let ready = sessions.count - attention - working
    var parts: [String] = ["Clyde"]
    if attention > 0 { parts.append("\(attention) needs attention") }
    if working > 0 { parts.append("\(working) working") }
    if ready > 0 { parts.append("\(ready) ready") }
    return parts.joined(separator: ", ")
}
```

- [ ] **Step 3: Refactor `AppDelegate.currentStatusItemValue()` to share this.**

Replace the body of `currentStatusItemValue()` (added in Task 4) with:

```swift
@MainActor
private func currentStatusItemValue() -> String {
    // Drop the leading "Clyde, " prefix because the status item's own
    // accessibility label already includes "Clyde".
    let label = appViewModel.widgetAccessibilityLabel
    return label.replacingOccurrences(of: "Clyde, ", with: "")
}
```

- [ ] **Step 4: Build + commit.**

Run: `swift build`
Expected: succeeds.

```bash
git add Clyde/Views/WidgetView.swift Clyde/ViewModels/AppViewModel.swift Clyde/App/AppDelegate.swift
git commit -m "feat(a11y): combined accessibility label on widget panel"
```

Body: explain that internal counts/animations were exposed as separate VO elements before; now the whole capsule reads as one element backed by a shared `AppViewModel.widgetAccessibilityLabel`.

---

## Task 6: ExpandedHeader stats summary + snooze value

The header's stats row currently exposes individual count pills as separate VO elements. Combine them. Add a remaining-time value to the snooze button so VoiceOver announces "Snoozed for 23 minutes" when active.

**Files:**
- Modify: `Clyde/Views/Components/ExpandedHeader.swift`
- Modify: `Clyde/Services/NotificationService.swift`

- [ ] **Step 1: Expose snooze remaining minutes from `NotificationService`.**

In `Clyde/Services/NotificationService.swift`, add (near the existing snooze-related code):

```swift
/// Remaining snooze duration in minutes, rounded up so a partial minute
/// still announces as "1 minute". Returns nil when not snoozed.
var snoozeRemainingMinutes: Int? {
    guard let until = snoozeUntil else { return nil }
    let interval = until.timeIntervalSince(Date())
    guard interval > 0 else { return nil }
    return max(1, Int(ceil(interval / 60)))
}
```

- [ ] **Step 2: Combine the stats row in `ExpandedHeader`.**

Find the `private var statsRow` computed view (around line 95). Wrap the returned view with a combined element label:

```swift
@ViewBuilder
private var statsRow: some View {
    let entries = visibleStats
    Group {
        if entries.isEmpty {
            HStack(spacing: 5) {
                Circle().fill(Color(white: 0.4)).frame(width: 5, height: 5)
                Text("No active sessions")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color(white: 0.5))
            }
        } else {
            HStack(spacing: 10) {
                ForEach(entries, id: \.label) { entry in
                    HStack(spacing: 5) {
                        Circle().fill(entry.color).frame(width: 5, height: 5)
                        Text("\(entry.count) \(entry.label)")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color(white: 0.65))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
            }
        }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(statsAccessibilityLabel)
}

private var statsAccessibilityLabel: String {
    let entries = visibleStats
    if entries.isEmpty { return "No active sessions" }
    let parts = entries.map { "\($0.count) \($0.label)" }
    return "Status summary: " + parts.joined(separator: ", ")
}
```

- [ ] **Step 3: Add snooze value to the snooze header button.**

In `ExpandedHeader.swift`, the snooze button is constructed via `headerButton()` (lines 49–54). The current call site already passes `.accessibilityLabel`. Update the surrounding code so that when `isSnoozed`, the button picks up an `.accessibilityValue` describing remaining minutes.

Change `ExpandedHeader`'s callers to pass a `snoozeRemainingMinutes: Int?` input (from `appViewModel.notificationService.snoozeRemainingMinutes`). Add it to the struct:

```swift
let snoozeRemainingMinutes: Int?
```

In the snooze headerButton call, add the `.accessibilityValue` modifier:

```swift
headerButton(
    icon: isSnoozed ? "moon.zzz.fill" : "moon.zzz",
    action: onSnooze,
    accessibilityLabel: isSnoozed ? "Resume notifications" : "Snooze notifications"
)
.coachmarkAnchor(.snooze)
.accessibilityValue(snoozeAccessibilityValue)
```

…and add the computed value:

```swift
private var snoozeAccessibilityValue: String {
    guard isSnoozed, let minutes = snoozeRemainingMinutes else { return "" }
    return minutes == 1 ? "Snoozed for 1 minute" : "Snoozed for \(minutes) minutes"
}
```

- [ ] **Step 4: Update the `ExpandedHeader` call site.**

`Clyde/Views/ExpandedView.swift` (around line 12) — the `ExpandedHeader(...)` instantiation. Add the new parameter:

```swift
ExpandedHeader(
    clydeState: appViewModel.clydeState,
    attentionCount: sessionViewModel.attentionCount,
    workingCount: sessionViewModel.busyCount,
    readyCount: sessionViewModel.idleCount,
    isSnoozed: appViewModel.notificationService.isSnoozed,
    snoozeRemainingMinutes: appViewModel.notificationService.snoozeRemainingMinutes,
    onSnooze: {
        if appViewModel.notificationService.isSnoozed {
            appViewModel.notificationService.clearSnooze()
        } else {
            appViewModel.notificationService.snooze(minutes: 30)
        }
    },
    onSettings: { NotificationCenter.default.post(name: .clydeOpenSettings, object: nil) },
    onCollapse: { appViewModel.toggleExpanded() }
)
```

- [ ] **Step 5: Add a hint to the collapse button.**

In `ExpandedHeader.swift`, the collapse button currently has:

```swift
headerButton(
    icon: "minus",
    action: onCollapse,
    accessibilityLabel: "Collapse to widget"
)
.coachmarkAnchor(.collapse)
```

Add a hint after `.coachmarkAnchor(.collapse)`:

```swift
.accessibilityHint("Or press Control-Command-C from anywhere")
```

- [ ] **Step 6: Build + commit.**

Run: `swift build`
Expected: succeeds.

```bash
git add Clyde/Services/NotificationService.swift Clyde/Views/Components/ExpandedHeader.swift Clyde/Views/ExpandedView.swift
git commit -m "feat(a11y): combined stats label, snooze value, collapse hint"
```

Body: explain that the stats row was three separate VO elements before; combine into one summary string. Snooze button now carries remaining duration as a `.accessibilityValue` (e.g. "Snoozed for 23 minutes") so users know when notifications resume.

---

## Task 7: SessionRow expanded label + edit-mode buttons

The current `SessionRow` already has a combined element with a basic label ("[name], [status]") plus a hint and `.isButton` trait. Extend the label to include the active tool and plan progress so the user gets the full picture without drilling in.

**Files:**
- Modify: `Clyde/Views/Components/SessionRow.swift`

- [ ] **Step 1: Compute an extended label.**

Add a private computed property to `SessionRow`:

```swift
private var rowAccessibilityLabel: String {
    var parts: [String] = ["\(session.displayName) session"]
    parts.append(accessibilityStatusDescription)

    if let tool = session.activeTool, let label = session.toolDisplayLabel {
        let elapsed = Int(Date().timeIntervalSince(tool.startedAt))
        let elapsedText = elapsed == 1 ? "1 second elapsed" : "\(elapsed) seconds elapsed"
        parts.append("\(label), \(elapsedText)")
    }

    if let plan = session.activePlan {
        if plan.taskCount > 0, plan.doneCount == plan.taskCount {
            parts.append("plan complete, \(plan.doneCount) of \(plan.taskCount) tasks")
        } else if plan.taskCount > 0 {
            parts.append("plan \(plan.doneCount) of \(plan.taskCount) tasks complete")
        }
    }

    return parts.joined(separator: ", ")
}
```

- [ ] **Step 2: Use the extended label.**

Find the existing `.accessibilityLabel(...)` (around line 161) and change it from:

```swift
.accessibilityLabel("\(session.displayName), \(accessibilityStatusDescription)")
```

to:

```swift
.accessibilityLabel(rowAccessibilityLabel)
```

- [ ] **Step 3: Label edit-mode controls.**

The inline rename mode is rendered at lines 36–69 (TextField + checkmark + X). Add labels:

The `TextField`:

```swift
TextField("Session name", text: $editName, onCommit: { /* existing */ })
    // existing modifiers...
    .accessibilityLabel("Session name")
```

The save (checkmark) button:

```swift
Button(action: { /* existing */ }) {
    Image(systemName: "checkmark")
        // existing
}
.buttonStyle(.plain)
.accessibilityLabel("Save name")
```

The cancel (X) button:

```swift
Button(action: { isEditing = false }) {
    Image(systemName: "xmark")
        // existing
}
.buttonStyle(.plain)
.accessibilityLabel("Cancel rename")
```

Note: the row's outer `.accessibilityElement(children: .combine)` will normally hide these sub-elements. SwiftUI's `.accessibilityElement(children: .contain)` exposes children when the row enters edit mode — but that requires conditional logic. The cleaner solution: when `isEditing == true`, drop the combined element, expose the natural sub-elements, and re-combine when not editing.

Replace the existing `.accessibilityElement(children: .combine)` line (~160) with:

```swift
.accessibilityElement(children: isEditing ? .contain : .combine)
```

- [ ] **Step 4: Build + commit.**

Run: `swift build && swift test --filter CoachmarkControllerTests`
Expected: succeeds, 19 tests pass.

```bash
git add Clyde/Views/Components/SessionRow.swift
git commit -m "feat(a11y): expand session row label with tool and plan, label edit controls"
```

Body: VoiceOver users now hear "my-project session, working, Edit ContentView.swift, 3 seconds elapsed, plan 8 of 16 tasks complete" instead of just "my-project, working". Edit mode (rename) decomposes the combined element so the field and Save/Cancel controls are individually reachable.

---

## Task 8: EmptyStateView + HookHealthBanner labels

Two small surfaces that each need one combined label.

**Files:**
- Modify: `Clyde/Views/Components/EmptyStateView.swift`
- Modify: `Clyde/Views/ExpandedView.swift`

- [ ] **Step 1: EmptyStateView combined label.**

In `Clyde/Views/Components/EmptyStateView.swift`, append to the body's outer `VStack`:

```swift
.accessibilityElement(children: .combine)
.accessibilityLabel("No active Claude sessions. Start one in your terminal to see it here.")
```

The existing `.coachmarkAnchor(.emptyState)` modifier stays.

- [ ] **Step 2: HookHealthBanner combined label.**

In `Clyde/Views/ExpandedView.swift`, the private `HookHealthBanner` struct is defined around line 92. Its body is a `Button` containing an `HStack`. Append to the `Button`:

```swift
.accessibilityElement(children: .combine)
.accessibilityLabel(issue.bannerMessage)
.accessibilityHint("Click to open Settings")
.accessibilityAddTraits(.isButton)
```

- [ ] **Step 3: Build + commit.**

Run: `swift build`
Expected: succeeds.

```bash
git add Clyde/Views/Components/EmptyStateView.swift Clyde/Views/ExpandedView.swift
git commit -m "feat(a11y): combined labels on empty state and hook health banner"
```

---

## Task 9: ActivityTimelineView toggle + entries

The expand toggle and each entry need labels.

**Files:**
- Modify: `Clyde/Views/Components/ActivityTimelineView.swift`

- [ ] **Step 1: Label the expand toggle.**

Find the `Button(action: { ... })` at lines 23–52. Append:

```swift
.accessibilityLabel("Activity timeline")
.accessibilityValue(timelineAccessibilityValue)
.accessibilityHint(expanded ? "Tap to collapse" : "Tap to expand")
.accessibilityAddTraits(.isButton)
```

Add the helper:

```swift
private var timelineAccessibilityValue: String {
    let count = log.events.count
    if count == 0 { return "No events" }
    return count == 1 ? "1 event" : "\(count) events"
}
```

- [ ] **Step 2: Label each timeline entry.**

The `ForEach(log.events) { event in row(for: event) }` lives around lines 80–82. Inside `row(for:)` (find it — likely around line 90+), wrap the returned view with:

```swift
.accessibilityElement(children: .combine)
.accessibilityLabel(eventAccessibilityLabel(event))
```

Add the helper, covering the 11 `ActivityEvent.Kind` cases:

```swift
private func eventAccessibilityLabel(_ event: ActivityEvent) -> String {
    let timeText = event.timestamp.formatted(date: .omitted, time: .shortened)
    switch event.kind {
    case .sessionStarted:
        return "Session started at \(timeText)"
    case .sessionResumed:
        return "Session resumed at \(timeText)"
    case .sessionCompacted:
        return "Session compacted at \(timeText)"
    case .promptSubmitted:
        return "Prompt submitted at \(timeText): \(event.detail ?? "")"
    case .permissionRequested:
        return "Permission requested at \(timeText)"
    case .permissionResolved:
        return "Permission resolved at \(timeText)"
    case .errorOccurred:
        return "Error at \(timeText): \(event.detail ?? "")"
    case .subagentStarted:
        return "Subagent started at \(timeText)"
    case .subagentStopped:
        return "Subagent stopped at \(timeText)"
    case .sessionReady:
        return "Session ready at \(timeText)"
    case .sessionEnded:
        return "Session ended at \(timeText)"
    }
}
```

If `ActivityEvent` exposes `detail` under a different name (`payload`, `summary`, etc.), substitute the actual field name. Read `Clyde/Services/ActivityLog.swift` to confirm.

- [ ] **Step 3: Build + commit.**

Run: `swift build`
Expected: succeeds.

```bash
git add Clyde/Views/Components/ActivityTimelineView.swift
git commit -m "feat(a11y): label timeline toggle and per-event entries"
```

---

## Task 10: SummaryBar combined label

Three status pills + a session count → one VO element.

**Files:**
- Modify: `Clyde/Views/Components/SummaryBar.swift`

- [ ] **Step 1: Add combined label.**

At the end of the outer `HStack` body (after `.padding`/etc.):

```swift
.accessibilityElement(children: .combine)
.accessibilityLabel(summaryAccessibilityLabel)
```

Add the helper:

```swift
private var summaryAccessibilityLabel: String {
    if sessionCount == 0 { return "Waiting for sessions" }
    var parts: [String] = []
    if busyCount > 0 { parts.append("\(busyCount) working") }
    if idleCount > 0 { parts.append("\(idleCount) ready") }
    let summary = "Status summary: " + parts.joined(separator: ", ")
    let total = sessionCount == 1 ? "1 session" : "\(sessionCount) sessions"
    return "\(summary). \(total) total."
}
```

- [ ] **Step 2: Hide the inner mascot from VoiceOver.**

The inner `ClydeAnimationView` already gets `.accessibilityHidden(true)` from Task 1 (the modifier sits on the view itself, not the call site), so no change here.

- [ ] **Step 3: Build + commit.**

Run: `swift build`
Expected: succeeds.

```bash
git add Clyde/Views/Components/SummaryBar.swift
git commit -m "feat(a11y): combined accessibility label on summary bar"
```

---

## Task 11: OnboardingView modal + cards

The onboarding modal needs the `.isModal` trait, and each of the four feature cards combines into one VO element.

**Files:**
- Modify: `Clyde/Views/OnboardingView.swift`

- [ ] **Step 1: Mark the root modal.**

In `OnboardingView.swift`, at the end of the body's outermost view:

```swift
.accessibilityAddTraits(.isModal)
```

- [ ] **Step 2: Combine each feature card.**

Find the private `featureRow(...)` helper (around lines 119–137). Append at the end of its returned `HStack`:

```swift
.accessibilityElement(children: .combine)
.accessibilityLabel("\(title). \(description)")
```

The icon's symbol name is internal context; the visible text (title + description) is what VO should announce.

- [ ] **Step 3: Build + commit.**

Run: `swift build`
Expected: succeeds.

```bash
git add Clyde/Views/OnboardingView.swift
git commit -m "feat(a11y): mark onboarding modal and combine feature cards"
```

---

## Task 12: SettingsView audit pass

Tab buttons gain `.isSelected` trait when active; the polling-interval slider gets a value; the replay-tour button gets a hint.

**Files:**
- Modify: `Clyde/Views/SettingsView.swift`

- [ ] **Step 1: Tab button traits.**

In the tab sidebar `ForEach` (around lines 79–105), append to the `Button`:

```swift
.accessibilityAddTraits(.isButton)
.accessibilityAddTraits(isSelected ? [.isSelected] : [])
```

(The `isSelected` local was already computed inside the loop.)

- [ ] **Step 2: Polling-interval slider value.**

Around line 180, the slider:

```swift
Slider(value: $pollingInterval, in: 1...10, step: 1, onEditingChanged: { editing in
    if !editing {
        appViewModel.updatePollingInterval(pollingInterval)
    }
})
```

Append:

```swift
.accessibilityLabel("Polling interval")
.accessibilityValue("\(Int(pollingInterval)) seconds")
.accessibilityHint("Drag to adjust how often Clyde polls for session changes")
```

- [ ] **Step 3: Replay-tour button hint.**

Find the "Replay welcome tour" `Button` (in `GeneralSettingsTab`'s "Welcome Tour" section). Append:

```swift
.accessibilityHint("Restarts the first-run tour")
```

- [ ] **Step 4: Build + commit.**

Run: `swift build`
Expected: succeeds.

```bash
git add Clyde/Views/SettingsView.swift
git commit -m "feat(a11y): tab selection trait, slider value, replay hint"
```

---

## Task 13: Smoke test doc + ROADMAP + CHANGELOG

Document the manual verification scenarios and tick the roadmap item.

**Files:**
- Modify: `docs/hook-smoke-test.md` — append "Accessibility scenarios" section.
- Modify: `ROADMAP.md` — tick the open item.
- Modify: `CHANGELOG.md` — add an Unreleased bullet.

- [ ] **Step 1: Append the smoke-test scenarios.**

In `docs/hook-smoke-test.md`, append a new top-level `## Accessibility scenarios` section. The exact content (single-line per paragraph per repo convention):

```markdown
## Accessibility scenarios

### Pre-test setup

System Settings → Accessibility → VoiceOver → speech rate medium, verbosity medium. `⌘F5` toggles VoiceOver. For reduce-motion: System Settings → Accessibility → Display → Reduce motion ON.

### A — Menu bar + widget

VO cursor lands on the menu-bar status item. Hear: "Clyde, [stats summary], button. Click to expand panel". Stats line is dynamic (e.g. "2 working, 1 ready"). Activate with `⌃⌥space` — panel expands. Verify the widget panel itself is one combined VO element with the same label, no separate sub-elements for the mascot or count badges.

### B — Expanded panel

Navigate `⌃⌥→` through: header (title heading → stats summary as one element → snooze button → settings button → collapse button). Each has a label; snooze announces value when active ("Snoozed for 23 minutes"); collapse has hint "Or press Control-Command-C from anywhere". Then session rows top-to-bottom (each combined, label includes name + status + active tool + plan progress when present). Then activity timeline (expand toggle with value "[N] events", per-entry combined labels when expanded). Then summary bar (combined "Status summary: X working, Y ready. Z sessions total."). Verify the mascot in the header is skipped, no element is unlabelled.

### C — Settings + onboarding + coachmark tour

`⌘,` → Settings. Tab buttons reachable, the currently-selected tab announces itself as selected. General tab: polling-interval slider has label "Polling interval", value "[N] seconds", hint about adjusting; "Replay welcome tour" button has hint "Restarts the first-run tour". Defaults reset → onboarding → modal trait announced, four feature cards as combined VO elements with `title. description` content, "Get Started" / "Open Settings" buttons reachable. Replay welcome tour → four popovers, each with title-as-heading + body + counter + Skip + Got it.

### D — Reduce-motion ON

Tool/plan line transitions are crossfades, not slides. Status pill does not pulse on busy. Mascot freezes on its first frame (the antenna and sleeping micro-animations also stop). Activity timeline expand is instant. Error banner appears with opacity fade, not slide. Drag-and-drop animation still works. Color crossfades on header tint when status changes still work.
```

- [ ] **Step 2: Tick the ROADMAP item.**

In `ROADMAP.md`, find:

```
- [ ] Accessibility pass — VoiceOver labels on all controls !md #ux
```

Replace with:

```
- [x] Accessibility pass — every interactive surface has a VoiceOver label, traits, hints, and (where relevant) values; the pixel-art mascot and inner indicators are marked decorative; reduce-motion freezes the sprite, disables auto-running pulses, and swaps slide transitions for opacity crossfades while leaving drag-and-drop and color crossfades alone !md #ux
```

- [ ] **Step 3: Add the CHANGELOG bullet.**

Under the existing `## [Unreleased]` heading in `CHANGELOG.md`, append:

```
- **Accessibility pass.** Every interactive control in Clyde now announces itself meaningfully under VoiceOver — session rows speak their name, status, current tool and plan progress as one breath, the menu-bar capsule reads its live count, and tooltips, snooze remaining time, and onboarding cards all carry semantic labels. With Reduce Motion enabled in System Settings, Clyde stops every auto-running animation: the mascot freezes on its first frame, status pills no longer pulse, and slide transitions become opacity crossfades. Drag-and-drop and color transitions stay intact.
```

- [ ] **Step 4: Run the full Swift test suite.**

Run: `swift test`
Expected: all ~100 tests pass. Existing CoachmarkControllerTests still pass; this batch adds no new tests (audit task; no behavior covered by XCTest infra).

- [ ] **Step 5: Build the app for manual smoke.**

Run: `swift build -c debug`
Expected: succeeds.

Then build via Xcode (or wherever the dev binary is produced — `swift build` produces a `.bundle` but the runnable app comes from the Xcode project per repo conventions). Launch, run scenarios A–D from the smoke doc, confirm acceptance criteria.

- [ ] **Step 6: Commit.**

```bash
git add docs/hook-smoke-test.md ROADMAP.md CHANGELOG.md
git commit -m "docs(a11y): smoke scenarios, roadmap tick, changelog entry"
```

Body: explain that the manual smoke is the verification gate; ticking the roadmap matches the project's "summarize what shipped" convention; CHANGELOG primes the next release.

---

## Self-review

**1. Spec coverage.** Each spec section maps:
- Surface inventory (15 surfaces) → Tasks 1, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12. CoachmarkPopover already covered (no task needed; smoke verifies).
- Labeling policy (3 rules) → applied across Tasks 5–12.
- Reduce-motion strategy (per-site policy) → Tasks 1, 2.
- Verification plan → Task 13.
- No-tests acceptance → captured in Task 13 step 4.

**2. Placeholders.** None. The `ActivityEvent.detail` field name is conditionally swapped if the actual repo uses a different field — Task 9 includes the file to read for confirmation. The `currentStatusItemValue` / `widgetAccessibilityLabel` share rationale is a conscious mid-task refactor in Tasks 4–5, not an unresolved placeholder.

**3. Type consistency.** `widgetAccessibilityLabel`, `snoozeRemainingMinutes`, `rowAccessibilityLabel`, `statsAccessibilityLabel`, `summaryAccessibilityLabel`, `eventAccessibilityLabel(_:)`, `timelineAccessibilityValue` — all used consistently across tasks.

**4. Site count.** Spec said ~12 reduce-motion sites; the audit identified ~18. Task 2 enumerates each. The Task 1 reference impl plus the per-site list in Task 2 covers them all.

---

**Implementation order is the task order. Each task is self-contained and ships a separate commit. After Task 13, push to `main`.**
