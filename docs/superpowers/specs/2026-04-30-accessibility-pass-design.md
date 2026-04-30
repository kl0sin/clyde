# Accessibility Pass — Design Spec

**Date:** 2026-04-30
**Status:** Approved
**Scope:** VoiceOver labels, traits, hints, and values across every interactive UI surface; `.accessibilityHidden(true)` on decorative views; reduce-motion fallbacks for all auto-running animations. Manual VoiceOver smoke test documented in `docs/hook-smoke-test.md`.
**Roadmap item:** `[ ] Accessibility pass — VoiceOver labels on all controls !md #ux` (v0.3.0+).

## Goal

Today Clyde has 13 accessibility-related calls across 3 files (mostly added incidentally during recent feature work). Twelve UI surfaces have zero coverage; the pixel-art mascot is exposed to VoiceOver as an unlabelled image; status changes are color-only; not a single auto-running animation respects the system reduce-motion preference. The pass closes those gaps in one focused sweep.

After this pass, a VoiceOver user can navigate the menu-bar capsule, expanded panel, settings, onboarding, and coachmark tour with every interactive element announcing what it is, its current state where relevant, and what tapping it does. Users with reduce-motion enabled see no auto-running motion in the app — pulses stop, slides become opacity crossfades, and the sprite freezes on its first frame.

## Non-goals

- **Dynamic Type.** Clyde has 142 hardcoded font sizes across `Clyde/Views/`. Migrating to semantic font styles plus the layout work to handle larger sizes is its own multi-day project. Tracked separately on the roadmap.
- **Tab/keyboard focus order beyond what VoiceOver needs.** Custom NSPanel hosting SwiftUI has known focus-management edge cases (focus rings, popover focus theft, tab traversal). VoiceOver's own keyboard navigation (`⌃⌥→` etc.) works without explicit `focusable()`/`focused()` plumbing, so we leave plain Tab traversal alone.
- **Custom keyboard shortcuts within the panel** (e.g. `⌘1`–`⌘N` to jump to a session). Productivity feature, not accessibility.
- **Localization of the new labels.** English-only, matching the existing tour copy.
- **Automated XCTest assertions on the accessibility tree.** macOS XCTest accessibility introspection is not mature enough to make this worth the rig; coverage gap accepted (see Verification §below).

## Surface inventory

The full set of UI surfaces in scope, each with the policy applied to it. Surfaces are listed top-to-bottom of the user's likely path through the app.

### Menu-bar status item — `AppDelegate.swift:364-365`

Already has `setAccessibilityLabel("Clyde")` and `setAccessibilityRole(.button)`. Add `setAccessibilityValue` that renders a one-line summary of the current state — e.g. "2 working, 1 ready, 1 needs attention" — refreshed whenever `clydeState` or counts change. This is the entry point a VoiceOver user lands on; it should answer "what's the state right now" before they decide whether to expand.

### Widget panel (`WidgetView`)

Combine the entire capsule into one VoiceOver element. Label: "Clyde menu bar capsule, [same summary as the status item]". Hint: "Click to expand panel, or use Control-Option-Space to activate". The internal `ClydeAnimationView` and the count badges become decorative — `.accessibilityHidden(true)` on the animation, count semantics folded into the parent label.

### Expanded panel root (`ExpandedRootView`, `ExpandedView`)

Container, no own label. The `.accessibilityElement(children: .contain)` default behavior is correct here.

### Header (`ExpandedHeader`)

- **Mascot tile** — already shows `ClydeAnimationView`. Mark `.accessibilityHidden(true)`.
- **Title "Clyde"** — already has `.accessibilityAddTraits(.isHeader)`. No change.
- **Stats row** ("2 working", "1 ready" pills) — combine into one element with label "Status summary: 2 working, 1 ready". When zero — "No active sessions".
- **Snooze button** — already has dynamic label ("Resume notifications" / "Snooze notifications"). Add `.accessibilityValue` showing remaining snooze duration when active ("Snoozed for 23 minutes").
- **Settings button** — already labelled "Open settings". No change.
- **Collapse button** — already labelled "Collapse to widget". Hint: "Or press Control-Command-C from anywhere".

### HookHealthBanner — `ExpandedView.swift:92`

Conditional warning banner. Combine into one element: label = `issue.bannerMessage`, hint = "Click to open Settings", `.accessibilityAddTraits(.isButton)`.

### SessionRow — `Clyde/Views/Components/SessionRow.swift`

Already has `.accessibilityElement(children: .combine)` plus a label, hint, and `.isButton` trait. Expand the label to include `session.activeTool` and `session.activePlan` content when present. Pattern:

> "<displayName> session, <status>, <tool summary if active>, <plan progress if active>"

Examples:
- Idle: "my-project session, ready"
- Busy with tool: "my-project session, working, Edit ContentView.swift, 3 seconds elapsed"
- Plan in progress: "my-project session, working, plan 8 of 16 tasks complete"
- Needs attention: "my-project session, needs your input"

The hint stays "Double tap to focus the terminal".

In edit mode (rename in progress), the inner edit field, checkmark, and X buttons need their own labels: "Session name field", "Save name", "Cancel rename".

`SessionStatusIndicator` (the colored dot) becomes `.accessibilityHidden(true)` because the status is already in the parent's label. `PlanBadge` similarly hidden inside the row — the plan progress is in the parent label. (PlanBadge's standalone-element label is documented below for cases where it's read independently.)

### PlanBadge — `Clyde/Views/Components/PlanBadge.swift`

Currently a purple→green visual progress bar with no a11y. As part of `SessionRow.combine` it inherits the row's label, so `.accessibilityHidden(true)` is the right call. PlanBadge isn't rendered outside SessionRow today; if that changes, the badge will need its own label at that point.

### EmptyStateView — `Clyde/Views/Components/EmptyStateView.swift`

Currently a centered illustration + text. Combine into one element with label "No active Claude sessions. Start one in your terminal to see it here."

### ActivityTimelineView — `Clyde/Views/Components/ActivityTimelineView.swift`

Two layers:

- **Expand toggle** — label "Activity timeline", value "[N] events", hint "Tap to expand" / "Tap to collapse" depending on state, `.isButton` trait.
- **Each timeline entry** — combine its icon/text into one element with a label that fully describes the event. Examples: "User prompt at 14:32: write a failing test", "Permission requested at 14:33", "Session compacted at 14:35", "Tool finished: Edit ContentView.swift, 3 seconds".

### SummaryBar — `Clyde/Views/Components/SummaryBar.swift`

Combine the three status pills into one element. Label "Status summary: 2 working, 1 ready" (skip zero counts).

### OnboardingView — `Clyde/Views/OnboardingView.swift`

- Root window: `.accessibilityAddTraits(.isModal)`.
- Each of the four feature cards: combine into one element with label "[icon name], [title], [description]". Example: "Real-time tracking, Watches every Claude Code session in real time, fed by Claude's native hooks."
- Buttons "Get Started" and "Open Settings" already have native button labels via `Button("...")`. Confirm during smoke test.

### SettingsView — `Clyde/Views/SettingsView.swift`

- **Tab buttons** — already labelled via `Text(tab.title)`. Tab traits applied via SwiftUI's `TabView` semantics if used; this app uses a custom sidebar with conditional `selectedTab` switch. Add `.accessibilityAddTraits(.isButton)` and ensure the *currently selected* tab announces itself with `.isSelected` trait.
- **GeneralSettingsTab** — slider for polling interval needs `.accessibilityValue` showing the current seconds. `Replay welcome tour` button: confirm native label, add hint "Restarts the first-run tour".
- **NotificationsSettingsTab, PushSettingsTab, ClaudeSettingsTab, AdvancedSettingsTab, AboutSettingsTab** — most controls inherit native SwiftUI labels (`Toggle("...")`, `Picker("...")`). Audit each for icon-only buttons or color-only controls and add labels where missing.

### CoachmarkPopover — `Clyde/Views/Components/CoachmarkPopover.swift`

Already has `.accessibilityAddTraits(.isHeader)` on the title and labels on Skip + counter. The advance button gets its label from the visible text ("Got it ›" / "Done ✓") which is fine. No additional changes.

### ClydeAnimationView — `Clyde/Views/ClydeAnimationView.swift`

Always `.accessibilityHidden(true)`. Pixel-art mascot, purely decorative regardless of where it's hosted (header, widget, settings about pane). The animation timer also gates on reduce-motion (see §Reduce-motion strategy below).

## Labeling policy

Three rules applied uniformly across the surfaces above.

### 1. Combine elements that are one logical thing

`SessionRow` is one session, not a stack of independent controls. VoiceOver reads it as one element: "my-project, working, Edit ContentView, 3 seconds, plan 8 of 16. Double tap to focus the terminal." Reachable sub-elements only when they have independent semantics and an action — e.g. inline rename mode exposes the text field, save, and cancel as separate elements.

The same applies to `StatusPill`, `PlanBadge`, header stats, summary bar, timeline entries — combine into the parent's label.

Anti-pattern to avoid: decomposing every `Text` and `Image` into a separate VO node. The VO cursor would then walk through individual words ("my", "project", "working", "3", "seconds") instead of meaningful chunks.

### 2. Label = what + state, hint = what tap does

Pattern: `label = "<what it is>, <current state if relevant>"`, `hint = "<what happens on tap>"`, `value = <dynamic value if a continuous parameter>`.

- Snooze button (active): label "Snooze notifications", value "Snoozed for 23 minutes", hint "Double tap to resume".
- Polling-interval slider: label "Polling interval", value "[N] seconds", hint "Drag to adjust".
- Plan badge inside a row: no separate label — folded into the row's combined label.

### 3. Decorative views use `.accessibilityHidden(true)`, never empty labels

`ClydeAnimationView`, `SessionStatusIndicator` (status is in the parent's label), pixel-art accents, gradient overlays, dividers — all `.accessibilityHidden(true)`. Never leave an element label-less but visible to VoiceOver. VO falls back to the widget type ("button", "image") with no context, which is worse than skipping entirely.

### Special cases

- **Status pills in SummaryBar** — color-only signal is insufficient. Label must include the semantic state ("2 sessions working").
- **PlanBadge purple→green transition** — the parent label already says "complete" in the finished state, so the color is redundant for VO. No additional handling needed.
- **Animations** (spring/pulse/slide) are not an accessibility issue per se as long as the final state has a label. Reduce-motion handling is separate (next section).

## Reduce-motion strategy

Twelve animation call sites in the app. The pattern applied uniformly:

```swift
@Environment(\.accessibilityReduceMotion) private var reduceMotion

.animation(reduceMotion ? .none : .spring(response: 0.28, dampingFraction: 0.85), value: ...)
```

For repeated reuse, a small extension:

```swift
extension Animation {
    static func clyde(_ base: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : base
    }
}
```

Used wherever `.animation(...)` currently lives. The view reads `@Environment(\.accessibilityReduceMotion)` once and threads it.

### Per-animation policy

| Site | File:concept | Reduce-motion behavior |
|---|---|---|
| Tool/plan line slide | `SessionRow.swift` ZStack `value: session.activeTool != nil` | Replace spring with opacity crossfade — keeps the "something changed" signal without motion. |
| Status pill pulse (`pillPulse`, busy/attention) | `SessionRow.swift` `.repeatForever` | Disable. The status is already in the label and color; pulse adds nothing for reduce-motion users. |
| `stateFlash` on status change | `SessionRow.swift` | Replace spring with an opacity step, no spring. |
| Drop indicator + drag scale | `SessionListView.swift:59-60` | Leave. Drag-and-drop is user-initiated motion, exempt from reduce-motion per Apple HIG. |
| `ClydeAnimationView` sprite frames | `ClydeAnimationView.swift` | Disable. Sprite freezes on its first frame. The view is decorative either way, but pulse/idle animations should stop. |
| Widget capsule color transition | `WidgetView.swift` | Leave. Color crossfade isn't motion. |
| Error banner slide-in | `ExpandedRootView.swift:24` `.move(edge: .top)` | Replace `.move` with opacity. |
| Timeline expand/collapse | `ActivityTimelineView.swift` | Replace with instant, no animation. |
| HookHealthBanner appear | `ExpandedView.swift:24` | Replace with opacity. |
| Header stats `easeInOut` on `clydeState` | `ExpandedHeader.swift:89` | Leave. Color/glow shift, not motion. |
| Coachmark popover appear | system `.popover` | System-managed, automatically respects reduce-motion. No code change. |
| Header animation values | `ExpandedHeader.swift` | Leave. Color crossfades. |

**Rule of thumb:** disable or swap to opacity when the animation is **motion-based** (slide / spring / scale / pulse). Leave **color-based** transitions alone — reduce-motion does not apply to them per Apple guidelines.

No global `transaction.disablesAnimations` — granular per-site control keeps legitimate visual feedback (drag-and-drop, color transitions) working.

## Verification plan

Manual VoiceOver smoke test, documented in `docs/hook-smoke-test.md` as a new top-level section "Accessibility scenarios". The doc is the source of truth — the spec just defines what scenarios to add.

### Pre-test setup

Settings → Accessibility → VoiceOver → speech rate medium, verbosity medium. `⌘F5` toggles VO. For the reduce-motion scenario: Settings → Accessibility → Display → Reduce motion ON.

### Scenarios

**A — Menu bar + widget**

VO cursor lands on the status item. Hear: "Clyde, [stats summary], button. Click to expand panel". Stats summary is dynamic. Activate with `⌃⌥space` or click — panel expands.

**B — Expanded panel**

Navigate with `⌃⌥→` through: header (title heading → stats summary → snooze → settings → collapse), then session rows top-to-bottom (each combined element with full label), then activity timeline (expand toggle → entries when expanded), then summary bar.

Verify: no element is unlabelled. Mascot is skipped. Focus order matches visual order. Each session row's label includes status, tool/plan when active.

**C — Settings + onboarding + coachmark tour**

`⌘,` → Settings. Tab buttons reachable, currently-selected tab announces selected. Each control has a label and (sliders/values) a value. Defaults reset → onboarding → modal trait announced, four feature cards as combined elements, buttons reachable. Replay welcome tour → four popovers with title-as-heading + body + counter + Skip + Got it.

**D — Reduce-motion ON**

Tool line transitions are crossfades, not slides. Status pill does not pulse on busy. Mascot freezes on its first frame. Timeline expand is instant. Drag-and-drop animation still works. Color transitions (header tint on status change) still work.

### Acceptance criteria

- Every interactive element has a sensible VoiceOver label.
- Decorative views are skipped via `.accessibilityHidden(true)`.
- Status changes are semantically readable in VO, not only color-encoded.
- Reduce-motion disables every auto-running motion animation (pulse, sprite, slide, easing) while leaving user-initiated motion (drag) and color crossfades alone.

### No automated tests

`CLAUDE.md` precedent: `ActivityLog` ships with zero unit tests, and the established pattern is "manual smoke for things that don't have a sensible XCTest rig". macOS XCTest accessibility introspection is too immature for the cost-benefit. Coverage gap accepted: a regression that removes a label won't be caught automatically. Mitigation: code review on PRs touching `Clyde/Views/` checks for missing or malformed accessibility modifiers.

## Implementation order

The plan that follows this spec should ship in roughly this sequence (each its own commit):

1. Reduce-motion `Environment` plumbing + `Animation.clyde(...)` helper, applied to one site as a reference impl.
2. Reduce-motion fallbacks rolled out across the remaining 11 animation sites.
3. `.accessibilityHidden(true)` on `ClydeAnimationView`, `SessionStatusIndicator`, decorative pixels.
4. Menu-bar status item value updates.
5. WidgetView combined label.
6. ExpandedHeader stats + snooze value.
7. SessionRow expanded label (tool/plan inclusion) + edit-mode buttons.
8. EmptyStateView, HookHealthBanner labels.
9. ActivityTimelineView expand toggle + entries.
10. SummaryBar combined label.
11. OnboardingView modal + cards.
12. SettingsView audit pass: tabs trait, sliders, custom controls.
13. CoachmarkPopover confirmation (already covered, smoke-only).
14. Smoke test doc append (`docs/hook-smoke-test.md`).
15. ROADMAP tick + CHANGELOG entry.

The plan can collapse adjacent steps where convenient — that's a writing-plans concern.
