# Widget Redesign — Fixed Footprint Status Display

**Date:** 2026-04-07
**Status:** Approved
**Scope:** `Clyde/Views/WidgetView.swift`

## Goal

Eliminate horizontal "jumping" in the collapsed Clyde widget. Today the
status badge text changes width with state (`"4 ready"` → `"2 working"` →
`"1 needs input"`), so the centered content shifts inside the panel. Replace
the variable badge with a fixed-footprint status block that shows full
information (counts for all three states) in a stable layout.

Chosen concept: **G — Big number + tick bars**.

## Visual Specification

The widget keeps its existing 186 × 40 collapsed dimensions. The internal
layout becomes:

```
┌────────────────────────────────────────────────────┐
│  [🤖]  Clyde  │   [N]   ▬▬ N                       │
│                          ▬▬ N                       │
└────────────────────────────────────────────────────┘
   mascot  name  sep  dominant  ticks (2 rows)
```

### Components (left → right)

1. **Mascot** — existing `ClydeAnimationView` at 22 × 22, `pixelSize: 1.4`. Unchanged.
2. **Name** — `"Clyde"`, system rounded 12pt semibold, white. Unchanged.
3. **Separator** — existing 1pt vertical rule, white @ 12% opacity. Unchanged.
4. **Dominant block** — fixed 30 × 30 rounded rectangle (radius 8). Background tint = state color @ 20% opacity. Foreground digit = state color, system rounded 14pt heavy.
5. **Tick column** — fixed 32pt wide vertical stack with two rows. Each row has a 14 × 2 horizontal bar followed by a digit. Bar color and digit color match the state. Inactive (count 0) rows render the bar at `#2a2a2f` and digit at `#4a4a50`.

### Total status block width

The status block (dominant + 4pt gap + tick column) is exactly **66pt**.
This width is fixed regardless of state, so the centered content never
shifts inside the panel.

### Color tokens

| State | Color |
|---|---|
| Attention | `#4aa3ff` (system blue) |
| Working | `#ff9500` (system orange) |
| Ready | `#34c759` (system green) |
| Dim (count 0) bar | `#2a2a2f` |
| Dim (count 0) digit | `#4a4a50` |

## Behavior

### Choosing the dominant state

Priority order: **attention > working > ready**. The first state with
`count > 0` wins and becomes the big number on the left.

### Tick row ordering

The two ticks show the **other two states**, ordered by the same priority
(top to bottom: attention, working, ready) — skipping whichever state is
the dominant. Examples:

| Dominant | Top tick | Bottom tick |
|---|---|---|
| attention | working | ready |
| working | attention | ready |
| ready | attention | working |

This means the order is **stable** by state identity (always priority order,
just with the dominant removed), not reordered by count. Predictable.

### Empty state

When no sessions exist at all (all three counts = 0), render the dominant
block as the dimmed style (background `#2a2a2f`, digit `#4a4a50`,
showing `0`) and both ticks as dim. No text label like `"idle"` is
needed — the all-grey block is the empty signal.

### Pulsing

The dominant block pulses softly (existing `isPulsing` 0.4 ↔ 1.0 opacity)
when the dominant state is `attention` or `working`. No pulse for `ready`
or empty.

## Architecture

### Files touched

Only `Clyde/Views/WidgetView.swift`.

- Replace `CompactStatusView`'s body and `Badge` helper with the new
  three-zone layout.
- Add a private `StatusModel` struct that pre-computes the dominant state
  + the two ordered tick states from `(attention, working, ready)`. This
  isolates the priority logic from the view code so it's easy to read.
- The outer `HStack` in `WidgetView.body` doesn't need to change — only
  the trailing `CompactStatusView` is rebuilt.

### Files NOT touched

- `WidgetView`'s outer chrome (background, hover, context menu) stays.
- `Session`, `ProcessMonitor`, `AttentionMonitor`, `AppViewModel` —
  unchanged. The status model is built from existing properties:
  `processMonitor.sessions` and `attentionMonitor.attentionPIDs`.
- `AppDelegate.collapsedSize` (186 × 40) is unchanged.

## Out of scope

- Changing the panel size or position.
- Editing the expanded view, settings, or menu bar item.
- Animating transitions between states (current snap-in is fine).
- Persisting any new state.

## Testing

Manual: toggle session states (busy/ready/attention) via real Claude
sessions and verify (a) the widget never visually shifts horizontally,
(b) the dominant block always reflects the priority correctly, (c) the
ticks always show the two non-dominant counts in the order
attention → working → ready, (d) empty state renders all-dim.

No new automated tests needed — `CompactStatusView` is a pure view
driven by counts already covered by ProcessMonitor / AttentionMonitor
tests.
