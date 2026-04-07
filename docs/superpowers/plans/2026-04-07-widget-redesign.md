# Widget Redesign (Option G) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the variable-width status badge in `WidgetView` with a fixed 66pt status block (dominant number + two tick rows) so the collapsed widget never visually jumps when state changes.

**Architecture:** All work happens in the existing `CompactStatusView` private struct inside `WidgetView.swift`. A new `StatusModel` value type pre-computes the dominant state and the two ordered tick states from the live counts so the view body stays declarative and easy to read.

**Tech Stack:** SwiftUI, existing `ProcessMonitor` / `AttentionMonitor` properties.

**Reference:** `docs/superpowers/specs/2026-04-07-widget-redesign-design.md`

**Out of scope:** Panel chrome, expanded view, settings, menu bar, animations beyond the existing `isPulsing` toggle.

---

## File Structure

Only one file is modified:

- **Modify:** `Clyde/Views/WidgetView.swift`
  - Replace `CompactStatusView.Badge` helper and the `badge` computed property with:
    - A new `StatusModel` value type with three associated counts and a `dominant` / `ticks` API.
    - Two new view-builder helpers: `dominantBlock(...)` and `tickRow(...)`.
  - Replace the body of `CompactStatusView` with the fixed-width layout.

No new files. No new tests (per spec — `CompactStatusView` is a pure view driven by counts already covered indirectly by `ProcessMonitor` / `AttentionMonitor` tests; verification is manual).

---

## Task 1: Introduce `StatusModel`

**Files:**
- Modify: `Clyde/Views/WidgetView.swift`

- [ ] **Step 1: Open `Clyde/Views/WidgetView.swift` and locate the existing `private struct CompactStatusView` (around line 75).**

- [ ] **Step 2: Add a `StatusModel` nested type and helper enum directly inside `CompactStatusView`, replacing the existing `Badge` struct.**

Replace this block:

```swift
    private struct Badge {
        let count: Int
        let label: String
        let color: Color
        let pulse: Bool
    }
```

with:

```swift
    /// Visual identity of one of the three tracked states. Holds its
    /// own colour so the view doesn't have to switch on the case.
    private enum StatusKind {
        case attention
        case working
        case ready

        var color: Color {
            switch self {
            case .attention: return .blue
            case .working:   return .orange
            case .ready:     return .green
            }
        }

        /// Whether this state should pulse when shown as the dominant block.
        var pulses: Bool {
            switch self {
            case .attention, .working: return true
            case .ready:               return false
            }
        }
    }

    /// Pre-computed status snapshot. Builds the dominant state (highest
    /// priority with count > 0) and the two non-dominant ticks in stable
    /// priority order. Pure logic — no SwiftUI dependencies.
    private struct StatusModel {
        let attention: Int
        let working: Int
        let ready: Int

        /// Total live sessions across all states. Zero means "no work
        /// at all" and the view renders the empty/dim style.
        var total: Int { attention + working + ready }

        /// The dominant state to render in the big block. Priority:
        /// attention > working > ready. Returns `.ready` with count 0
        /// when there are no sessions at all (caller treats as empty).
        var dominant: (kind: StatusKind, count: Int) {
            if attention > 0 { return (.attention, attention) }
            if working > 0   { return (.working, working) }
            if ready > 0     { return (.ready, ready) }
            return (.ready, 0)
        }

        /// The two states that are NOT the dominant one, in priority
        /// order (attention before working before ready). Each entry
        /// carries its own count, which may be zero (renders dim).
        var ticks: [(kind: StatusKind, count: Int)] {
            let dominantKind = dominant.kind
            let all: [(StatusKind, Int)] = [
                (.attention, attention),
                (.working, working),
                (.ready, ready),
            ]
            return all.filter { $0.0 != dominantKind }
        }
    }
```

- [ ] **Step 3: Replace the existing `badge` computed property with a `model` computed property that builds a `StatusModel` from the live counts.**

Replace this block:

```swift
    private var badge: Badge? {
        // Ghost rows (sessions still visually lingering after exit) don't
        // count toward the dominant-state badge.
        let sessions = viewModel.processMonitor.sessions.filter { !$0.isGhost }
        let attentionPIDs = attentionMonitor.attentionPIDs
        let attention = sessions.filter { attentionPIDs.contains($0.pid) }.count
        let processing = sessions.filter { $0.status == .busy && !attentionPIDs.contains($0.pid) }.count
        let ready = sessions.count - processing - attention

        if attention > 0 {
            return Badge(count: attention, label: "needs input", color: .blue, pulse: true)
        }
        if processing > 0 {
            return Badge(count: processing, label: "working", color: .orange, pulse: true)
        }
        if ready > 0 {
            return Badge(count: ready, label: "ready", color: .green, pulse: false)
        }
        return nil
    }
```

with:

```swift
    private var model: StatusModel {
        // Ghost rows (sessions still visually lingering after exit) don't
        // count toward any of the three states.
        let sessions = viewModel.processMonitor.sessions.filter { !$0.isGhost }
        let attentionPIDs = attentionMonitor.attentionPIDs
        let attention = sessions.filter { attentionPIDs.contains($0.pid) }.count
        let working = sessions.filter { $0.status == .busy && !attentionPIDs.contains($0.pid) }.count
        let ready = sessions.count - working - attention
        return StatusModel(attention: attention, working: working, ready: ready)
    }
```

- [ ] **Step 4: Build the project to make sure the new types compile.**

Run: `swift build 2>&1 | tail -10`
Expected: `Build complete!`

The view's `body` will fail to compile here because it still references `badge` — that's expected. Task 2 fixes it.

- [ ] **Step 5: Don't commit yet — Task 2 finishes the change in the same logical unit.**

---

## Task 2: New view body with fixed-width layout

**Files:**
- Modify: `Clyde/Views/WidgetView.swift`

- [ ] **Step 1: Replace the entire `var body: some View { ... }` of `CompactStatusView` with the new layout.**

Replace this block:

```swift
    var body: some View {
        Group {
            if let badge {
                HStack(spacing: 5) {
                    Circle()
                        .fill(badge.color)
                        .frame(width: 6, height: 6)
                        .opacity(badge.pulse && isPulsing ? 0.4 : 1.0)
                    Text("\(badge.count) \(badge.label)")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(badge.color)
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(badge.color.opacity(0.15))
                .clipShape(Capsule())
            } else {
                Text("idle")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundColor(Color(white: 0.5))
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                isPulsing = true
            }
        }
    }
```

with:

```swift
    var body: some View {
        let snapshot = model
        let dom = snapshot.dominant
        let isEmpty = snapshot.total == 0

        HStack(spacing: 4) {
            dominantBlock(kind: dom.kind, count: dom.count, isEmpty: isEmpty)
            tickColumn(snapshot: snapshot, isEmpty: isEmpty)
        }
        .frame(width: 66, alignment: .leading)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                isPulsing = true
            }
        }
    }

    /// Big number block on the left. 30 × 30 with the state's tinted
    /// background. Pulses softly when the state is attention or working.
    private func dominantBlock(kind: StatusKind, count: Int, isEmpty: Bool) -> some View {
        let bg: Color = isEmpty ? Color(white: 0.16) : kind.color.opacity(0.20)
        let fg: Color = isEmpty ? Color(white: 0.30) : kind.color
        let shouldPulse = !isEmpty && kind.pulses
        return Text("\(count)")
            .font(.system(size: 14, weight: .heavy, design: .rounded))
            .monospacedDigit()
            .foregroundColor(fg)
            .frame(width: 30, height: 30)
            .background(bg)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .opacity(shouldPulse && isPulsing ? 0.55 : 1.0)
    }

    /// Two stacked tick rows on the right showing the non-dominant counts
    /// in stable priority order (attention, working, ready, minus dominant).
    private func tickColumn(snapshot: StatusModel, isEmpty: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(snapshot.ticks.enumerated()), id: \.offset) { _, tick in
                tickRow(kind: tick.kind, count: tick.count, isEmpty: isEmpty)
            }
        }
        .frame(width: 32, alignment: .leading)
    }

    /// Single tick row: a 14 × 2 coloured bar followed by a digit.
    /// Renders dim grey when count is 0 or the whole widget is empty.
    private func tickRow(kind: StatusKind, count: Int, isEmpty: Bool) -> some View {
        let active = !isEmpty && count > 0
        let barColor: Color = active ? kind.color : Color(white: 0.16)
        let textColor: Color = active ? kind.color : Color(white: 0.30)
        return HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 1)
                .fill(barColor)
                .frame(width: 14, height: 2)
            Text("\(count)")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundColor(textColor)
        }
    }
```

- [ ] **Step 2: Build the project.**

Run: `swift build 2>&1 | tail -10`
Expected: `Build complete!`

- [ ] **Step 3: Run the existing test suite to make sure nothing regressed.**

Run: `swift test 2>&1 | grep "All tests" | tail -2`
Expected: `Test Suite 'All tests' passed`

- [ ] **Step 4: Commit the full redesign as one logical unit.**

```bash
git add Clyde/Views/WidgetView.swift
git commit -m "feat(widget): fixed-width status block (dominant + ticks)"
```

---

## Task 3: Manual verification

**Files:** none — runtime check only.

- [ ] **Step 1: Launch Clyde with the new build.**

Run: `swift run Clyde &`
Expected: panel appears in the top-right corner of the screen.

- [ ] **Step 2: Verify the four visual states.**

Open at least one Claude session in a terminal and run through the
following states. After each, confirm (a) the widget's outer rectangle
does not move horizontally, (b) the dominant block colour matches the
expected state, (c) the two tick rows show the other two counts in
attention → working → ready order minus the dominant.

| State | How to trigger | Expected |
|---|---|---|
| Empty | Quit all `claude` processes | All-grey 30 × 30 block, both ticks dim |
| Ready | One claude session, idle | Green block with `1`, two grey ticks |
| Working | Send a long prompt to a session | Orange block with `1`, ticks show attention/ready counts |
| Attention | Trigger a permission prompt | Blue block with `1`, ticks show working/ready counts |

- [ ] **Step 3: Verify the widget never shifts horizontally between transitions.**

Watch the widget while flipping between Working → Ready → Working in a
real session. The rounded panel rectangle should stay perfectly fixed;
only the colours and digits inside the dominant block should change.

- [ ] **Step 4: Quit the dev process.**

Run: `pkill Clyde`

---

## Self-Review Checklist (run after implementation)

- [ ] Widget is exactly 186 pt wide in the collapsed state (unchanged from before).
- [ ] Status block is exactly 66 pt wide regardless of state.
- [ ] Dominant block always reflects priority `attention > working > ready`.
- [ ] Tick rows are always in stable priority order (with the dominant removed).
- [ ] Empty state renders all dim with no text label.
- [ ] Pulse animation runs only for attention/working dominant states.
- [ ] No leftover references to the old `Badge` type or `badge` property.
- [ ] `swift build` and `swift test` both pass.
