# Compact mode — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A fourth way to keep Clyde on screen: the session rows at 30 points each, 400 wide, always open, with everything built for a window you read and close taken out.

**Architecture:** A second root view for the existing expanded panel rather than a second window. The panel keeps refusing any size its content asks for; compact computes a height from the rows it is showing and applies it the same way a deliberate resize would. The status dot becomes a four-pixel indicator shared by both modes.

**Tech Stack:** SwiftUI, AppKit (`ExpandedPanel`), Combine, XCTest.

**Spec:** `docs/superpowers/specs/2026-08-31-compact-mode-design.md`

## Global Constraints

- The panel refuses every size except the one it was told to be. Compact's height changes go through one deliberate call — never through content sizing. v0.8.0 shipped a 400×1476 window that way.
- Anything that touches the panel's size has the widget anchor, the show/hide animation and the drag strip in scope. The reverted resize attempt broke all three while its tests watched only the size.
- Motion animates `opacity` and `transform` only, runs on working rows only, stops when the panel is hidden, and is off entirely under `prefers-reduced-motion`.
- Status colours come from `SessionTheme` — `processingColor`, `readyColor`, `attentionColor`. No new colour for a state that already has one.
- `swift test` passes before every commit that touches Swift. No `git add -A`. No Claude attribution anywhere.

## File structure

| File | Responsibility |
|---|---|
| `Clyde/Views/Components/PixelStatusIndicator.swift` | The four-pixel indicator in its three states |
| `Clyde/Views/Components/CompactSessionRow.swift` | One 30-point row |
| `Clyde/Views/CompactRootView.swift` | Grip, rows, footer |
| `Clyde/ViewModels/AppViewModel.swift` | `panelMode`, persistence, the row cap |
| `Clyde/App/AppDelegate.swift` | Swapping the panel's root view and height, widget suppression |
| `Clyde/Views/Components/SessionRow.swift` | The indicator replaces the mascot in the full panel's slot |
| `Clyde/Views/SettingsView.swift` | Row cap setting |
| `scripts/dev/scenarios.sh` | `compact-mode` scenario |

---

### Task 1: The indicator

**Files:** create `Clyde/Views/Components/PixelStatusIndicator.swift`, test `ClydeTests/PixelStatusIndicatorTests.swift`

**Interfaces:** Produces `PixelStatusIndicator(state:)` where state is `.working | .idle | .needsAttention`.

- [ ] **Step 1: Write the failing tests** — the state mapping and the motion rules, which are decisions rather than drawing:

```swift
func testWorkingAnimatesAndTheOthersDoNot() {
    XCTAssertTrue(PixelStatusIndicator.animates(.working))
    XCTAssertFalse(PixelStatusIndicator.animates(.idle))
    XCTAssertFalse(PixelStatusIndicator.animates(.needsAttention),
                   "attention is noticed once, then stays legible — it does not flash until you act")
}

func testEachStateTakesItsColourFromTheTheme() {
    XCTAssertEqual(PixelStatusIndicator.color(for: .working), SessionTheme.processingColor)
    XCTAssertEqual(PixelStatusIndicator.color(for: .idle), SessionTheme.readyColor)
    XCTAssertEqual(PixelStatusIndicator.color(for: .needsAttention), SessionTheme.attentionColor)
}

/// The wave has to hand off from the fourth pixel to the first with no
/// gap, so the cycle is exactly four delay steps.
func testTheWaveLoopsWithoutAPause() {
    XCTAssertEqual(PixelStatusIndicator.cycle,
                   PixelStatusIndicator.delayStep * 4, accuracy: 0.001)
}

/// Shape carries the state when colour cannot.
func testTheStatesDifferByFillNotOnlyColour() {
    XCTAssertNotEqual(PixelStatusIndicator.baseOpacity(.idle),
                      PixelStatusIndicator.baseOpacity(.needsAttention))
}

func testASessionMapsToItsIndicatorState() {
    XCTAssertEqual(PixelStatusIndicator.state(for: busySession()), .working)
    XCTAssertEqual(PixelStatusIndicator.state(for: idleSession()), .idle)
    XCTAssertEqual(PixelStatusIndicator.state(for: attentionSession()), .needsAttention)
}
```

- [ ] **Step 2: Run them — they fail, the type does not exist**
- [ ] **Step 3: Build the indicator.** Four cells in a 2×2 grid, clockwise delays of `cycle / 4`, easing up and back down; idle holds every cell at rest; attention fills every cell and pulses three times on appear. Read `accessibilityReduceMotion` and drop to the static shape.
- [ ] **Step 4: Tests pass**
- [ ] **Step 5: Look at it** — `./scripts/build-app.sh debug`, drop the indicator into the full panel's slot behind a debug flag, and watch a working row for a minute. The question is whether the motion is ignorable, and no test answers it.
- [ ] **Step 6: Commit**

---

### Task 2: The compact row

**Files:** create `Clyde/Views/Components/CompactSessionRow.swift`, test `ClydeTests/CompactSessionRowTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
func testTheRowIsThirtyPoints() {
    XCTAssertEqual(CompactSessionRow.height, 30)
}

/// The worst case the row has to survive: a worktree badge and an
/// agent count on the same line as the name and the elapsed time.
func testAWorktreeAndAgentsFitTogether() {
    let row = CompactSessionRow.content(for: sessionInWorktree(agents: 4))
    XCTAssertEqual(row.name, "work-hub")
    XCTAssertEqual(row.badge, "external-wait")
    XCTAssertEqual(row.agentCount, 4)
    XCTAssertNotNil(row.elapsed)
}

/// The project keeps its name inside a worktree — the fix that shipped
/// alongside this.
func testTheNameIsTheProjectNotTheWorktree() {
    XCTAssertEqual(CompactSessionRow.content(for: sessionInWorktree()).name, "work-hub")
}

func testASessionWithNoAgentsShowsNoCount() {
    XCTAssertNil(CompactSessionRow.content(for: idleSession()).agentCount)
}
```

- [ ] **Step 2: Run them — red**
- [ ] **Step 3: Build the row** — indicator, name, worktree badge, agent count with its mark, elapsed time. One line, no truncation of the name before the badge.
- [ ] **Step 4: Tests pass**
- [ ] **Step 5: Commit**

---

### Task 3: The compact root, and its height

**Files:** create `Clyde/Views/CompactRootView.swift`, modify `Clyde/ViewModels/AppViewModel.swift`, test `ClydeTests/CompactModeTests.swift`

**Interfaces:** Produces `AppViewModel.panelMode` (`.full | .compact`), `CompactRootView.height(for:cap:)`.

- [ ] **Step 1: Write the failing tests**

```swift
func testHeightFollowsTheRowCount() {
    XCTAssertEqual(CompactRootView.height(rows: 2, cap: 4), 14 + 60 + 26)
    XCTAssertEqual(CompactRootView.height(rows: 4, cap: 4), 14 + 120 + 26)
}

func testTheCapBoundsIt() {
    XCTAssertEqual(CompactRootView.height(rows: 9, cap: 4),
                   CompactRootView.height(rows: 4, cap: 4))
}

/// Over the cap, the quiet sessions are the ones that go.
func testWorkingSessionsSurviveTheCap() {
    let shown = CompactRootView.visible(sessions: [idleA, workingB, idleC, workingD, idleE], cap: 3)
    XCTAssertTrue(shown.contains(workingB))
    XCTAssertTrue(shown.contains(workingD))
    XCTAssertEqual(shown.count, 3)
}

func testAttentionOutranksIdleButNotWork() {
    let order = CompactRootView.visible(sessions: [idleA, attentionB, workingC], cap: 3)
    XCTAssertEqual(order.map(\.pid), [workingC.pid, attentionB.pid, idleA.pid])
}

func testTheModePersists() {
    let vm = makeViewModel()
    vm.panelMode = .compact
    XCTAssertEqual(makeViewModel().panelMode, .compact)
}
```

- [ ] **Step 2: Run them — red**
- [ ] **Step 3: Build it.** Grip, rows, footer with the counts and *Expand*. `panelMode` persisted in `UserDefaults`.
- [ ] **Step 4: Tests pass**
- [ ] **Step 5: Commit**

---

### Task 4: Swapping the panel over

**Files:** modify `Clyde/App/AppDelegate.swift`, test `ClydeTests/ExpandedPanelTests.swift`

This is the task that broke things last time. Its tests cover the three things the resize attempt took down.

- [ ] **Step 1: Write the failing tests**

```swift
/// The invariant that survives from v0.8.1: content never sizes the
/// window, in either mode.
func testContentStillCannotResizeThePanelInCompact() {
    let panel = makePanel()
    panel.applyMode(.compact, height: 160)

    panel.setFrame(NSRect(x: 100, y: 100, width: 400, height: 1476), display: false)

    XCTAssertEqual(panel.frame.height, 160)
}

func testSwitchingModesKeepsTheTopEdgeStill() {
    let panel = makePanel()
    let topBefore = panel.frame.maxY

    panel.applyMode(.compact, height: 160)

    XCTAssertEqual(panel.frame.maxY, topBefore, accuracy: 0.5,
                   "growing and shrinking happen downward")
}

func testTheWidthNeverChanges() {
    let panel = makePanel()
    panel.applyMode(.compact, height: 160)
    XCTAssertEqual(panel.frame.width, 400)
}

/// The widget and compact are two always-on-top surfaces saying the
/// same thing.
func testCompactSuppressesTheWidgetAndFullBringsItBack() { … }
```

- [ ] **Step 2: Run them — red**
- [ ] **Step 3: Implement `applyMode(_:height:)`** on `ExpandedPanel` as the single door for a size change, and swap the hosting view's root between `ExpandedRootView` and `CompactRootView`.
- [ ] **Step 4: Tests pass**
- [ ] **Step 5: Check the three things tests cannot** — switch modes ten times and watch the panel stay anchored to the widget; open and close it in both modes and watch the slide animation; drag it by the grip and by the header. Any of these breaking is the same failure as the reverted attempt.
- [ ] **Step 6: Commit**

---

### Task 5: Requests inside compact

**Files:** modify `Clyde/Views/CompactRootView.swift`, `Clyde/Views/Components/PermissionRequestRow.swift`, test `ClydeTests/CompactModeTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
func testARequestExpandsItsRowAndTheHeightFollows() {
    let base = CompactRootView.height(rows: 3, cap: 4)
    XCTAssertGreaterThan(CompactRootView.height(rows: 3, cap: 4, expandedRequest: aRequest), base)
}

/// One at a time, newest first: two expanded requests is most of the
/// screen.
func testOnlyTheNewestRequestIsExpanded() {
    XCTAssertEqual(CompactRootView.expandedRequest(from: [older, newer])?.id, newer.id)
}

func testTheRowCollapsesWhenTheRequestIsAnswered() {
    XCTAssertNil(CompactRootView.expandedRequest(from: []))
}

/// The command is never shortened to make it fit — same rule as the
/// full panel.
func testTheCommandIsNotAbbreviatedInCompact() {
    let long = String(repeating: "x", count: 400)
    XCTAssertEqual(PermissionRequestRow.displayedSummary(for: request(command: long)), long)
}
```

- [ ] **Step 2: Run them — red**
- [ ] **Step 3: Implement it**, reusing `PermissionRequestRow` rather than drawing a second one.
- [ ] **Step 4: Tests pass**
- [ ] **Step 5: Commit**

---

### Task 6: The way in, the way back, and the live check

**Files:** modify `Clyde/Views/Components/ExpandedHeader.swift`, `Clyde/Views/SettingsView.swift`, `scripts/dev/scenarios.sh`, `CHANGELOG.md`, `ROADMAP.md`

- [ ] **Step 1: Add the header button and the footer's *Expand***, and make ⌃⌘C toggle whichever mode was last used.
- [ ] **Step 2: Add the row-cap setting**, default 4.
- [ ] **Step 3: Add a `compact-mode` scenario** that launches the dev build in compact with seeded sessions and prints what to look at.
- [ ] **Step 4: Run it for an hour of real work.** Compact open beside a terminal, sessions starting and finishing, at least one permission request. The questions no test answers: is the motion ignorable after twenty minutes, does the height changing under you feel like the window jumping, and is the mode still the one you would leave open tomorrow.
- [ ] **Step 5: Write the CHANGELOG entry, tick the ROADMAP, commit.**

---

## Not in this plan

The rail — one line per session at 268 wide — is drawn in the mockup and rejected for now. If compact turns out to be what gets left open all day, the rail becomes a second layout on top of a mode that already works, which is a much cheaper bet than building both.
