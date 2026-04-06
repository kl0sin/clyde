# Clyde Busy Face Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** In `.busy` state, show a close-up of Clyde's working face (with a scrolling terminal bar across the bottom) instead of his full-body sprite, crossfading between the two layers.

**Architecture:** Add a new `busyFace` sprite in `ClydeAnimationView.swift`. Render two `Canvas` layers in a `ZStack` — the existing body and a new face — and drive their opacities with `withAnimation(.easeInOut(duration: 0.25))` on state change. Reuse the existing `TimelineView` tick to animate the new layer (eye scan + mouth + antenna + terminal bar buffer).

**Tech Stack:** SwiftUI (`Canvas`, `TimelineView`, `ZStack`), existing `ClydeState` enum, existing `ClydeSprite` struct.

**Reference:** `docs/superpowers/specs/2026-04-06-clyde-busy-face-design.md`

**Out of scope:** Changes to `WidgetView.swift`, widget size, sounds, tying terminal bar to real hook data, changes to `.idle` / `.sleeping` visuals.

---

## File Structure

Only one file changes:

- **Modify:** `Clyde/Views/ClydeAnimationView.swift`
  - Add `ClydeSprite.busyFace: [[Color?]]` — the 16×16 face sprite.
  - Add face palette color (`cold terminal bg`, `terminal glyph`).
  - Split `body` into `bodyLayer` + `faceLayer` computed views, composed via `ZStack`.
  - Add `@State`: `bodyOpacity`, `faceOpacity`, `eyeScanOffset`, `terminalBuffer`.
  - Hook opacity change into `onChange(of: state)` with `withAnimation`.
  - Advance terminal buffer and eye scan in the existing per-tick handler.

No new files. No tests (the project has no test target for Views — verification is manual, per existing project convention).

---

## Task 1: Add the `busyFace` sprite

**Files:**
- Modify: `Clyde/Views/ClydeAnimationView.swift` (extend `ClydeSprite`)

- [ ] **Step 1: Open `Clyde/Views/ClydeAnimationView.swift` and locate the `ClydeSprite` struct (starts around line 3).**

- [ ] **Step 2: Inside `ClydeSprite`, below the existing `eyesSleeping` definition (around line 75, before the closing `}` of the struct), add the `busyFace` static constant.**

```swift
    // Busy-state face sprite: 16x16 close-up of Clyde's head.
    // Rows 14-15 are the terminal bar area (rendered dynamically, not from this sprite).
    static let busyFace: [[Color?]] = {
        let e: Color? = nil
        let w: Color? = .white
        let h: Color? = Color(white: 0.95)
        let d: Color? = Color(white: 0.65)
        let b: Color? = Color(red: 0.08, green: 0.08, blue: 0.1)
        let g: Color? = Color(red: 0.3, green: 1.0, blue: 0.5)
        let r: Color? = Color(red: 1.0, green: 0.6, blue: 0.4) // focus blush

        return [
            //0  1  2  3  4  5  6  7  8  9 10 11 12 13 14 15
            [e, e, e, e, e, e, e, g, g, e, e, e, e, e, e, e], // 0  antenna tip
            [e, e, e, e, e, e, b, d, d, b, e, e, e, e, e, e], // 1  antenna stem
            [e, e, b, b, b, h, h, h, h, h, h, b, b, b, e, e], // 2  head top
            [e, b, h, w, w, w, w, w, w, w, w, w, w, h, b, e], // 3  forehead
            [b, h, w, w, w, w, w, w, w, w, w, w, w, w, h, b], // 4  brow line
            [b, w, w, w, b, b, w, w, w, w, b, b, w, w, w, b], // 5  eyes (sockets)
            [b, w, w, w, b, b, w, w, w, w, b, b, w, w, w, b], // 6  eyes (pupils drawn dynamically)
            [b, w, w, w, w, w, w, w, w, w, w, w, w, w, w, b], // 7  cheeks
            [b, w, w, w, w, b, b, b, b, b, b, w, w, w, w, b], // 8  mouth (dynamic)
            [b, h, w, w, w, r, w, w, w, w, r, w, w, w, h, b], // 9  lower cheeks (focus blush)
            [b, h, w, w, w, w, w, w, w, w, w, w, w, w, h, b], // 10 chin
            [e, b, h, w, w, w, w, w, w, w, w, w, w, h, b, e], // 11 jaw
            [e, e, b, b, h, w, w, w, w, w, w, h, b, b, e, e], // 12 chin bottom
            [e, e, e, e, b, b, b, b, b, b, b, b, e, e, e, e], // 13 neck outline
            [e, e, e, e, e, e, e, e, e, e, e, e, e, e, e, e], // 14 terminal bar (dynamic)
            [e, e, e, e, e, e, e, e, e, e, e, e, e, e, e, e], // 15 terminal bar (dynamic)
        ]
    }()
```

- [ ] **Step 3: Build the project to make sure the sprite compiles.**

Run: `xcodebuild -scheme Clyde -configuration Debug build 2>&1 | tail -20`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Commit.**

```bash
git add Clyde/Views/ClydeAnimationView.swift
git commit -m "feat(clyde): add busyFace sprite"
```

---

## Task 2: Split body/face into layered Canvases with crossfade

**Files:**
- Modify: `Clyde/Views/ClydeAnimationView.swift` (`ClydeAnimationView` struct)

- [ ] **Step 1: At the top of `ClydeAnimationView` (around line 81, after the existing `@State` declarations), add the new state.**

```swift
    @State private var bodyOpacity: Double = 1
    @State private var faceOpacity: Double = 0
    @State private var eyeScanOffset: Int = 0 // -1, 0, or +1
    @State private var terminalBuffer: [Character] = Array(repeating: " ", count: 16)
```

- [ ] **Step 2: Replace the `body` computed property with a `ZStack` composing a body layer and a face layer.**

Find the existing `var body: some View { ... }` (starts around line 95) and replace its contents with:

```swift
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.2)) { timeline in
            ZStack {
                bodyCanvas
                    .opacity(bodyOpacity)
                faceCanvas
                    .opacity(faceOpacity)
            }
            .frame(width: gridWidth, height: gridHeight)
            .onChange(of: timeline.date) { _ in
                animationTick += 1
                advanceTerminalBuffer()
                advanceEyeScan()
                updateAnimations()
            }
        }
        .onAppear {
            seedTerminalBuffer()
            applyStateOpacity(animated: false)
            updateAnimations()
        }
        .onChange(of: state) { _ in
            animationTick = 0
            applyStateOpacity(animated: true)
            updateAnimations()
        }
    }
```

- [ ] **Step 3: Extract the existing per-frame drawing into a `bodyCanvas` computed property.**

Below `var body`, add:

```swift
    private var bodyCanvas: some View {
        Canvas { context, _ in
            let sprite = ClydeSprite.body

            for row in 0..<16 {
                for col in 0..<16 {
                    guard var color = sprite[row][col] else { continue }

                    // Eye animation (idle/sleeping only — busy uses faceCanvas)
                    if (row == 5 || row == 6) && col >= 4 && col < 12 {
                        let localCol = col - 4
                        switch state {
                        case .idle:
                            let blinkPhase = (animationTick / 13) % 13
                            if blinkPhase == 0, let override = ClydeSprite.eyesClosed[row - 5][safe: localCol] {
                                color = override ?? color
                            }
                        case .sleeping:
                            if let override = ClydeSprite.eyesSleeping[row - 5][safe: localCol] {
                                color = override ?? color
                            }
                        case .busy:
                            break
                        }
                    }

                    // Mouth (row 7) — smile for idle/sleeping
                    if row == 7 && col >= 4 && col < 12 {
                        let localCol = col - 4
                        if state != .busy, let override = ClydeSprite.mouthSmile[safe: localCol] {
                            color = override ?? color
                        }
                    }

                    let rect = CGRect(
                        x: CGFloat(col) * pixelSize,
                        y: CGFloat(row) * pixelSize,
                        width: pixelSize,
                        height: pixelSize
                    )
                    context.fill(Path(rect), with: .color(color))
                }
            }

            // Zzz for sleeping state
            if state == .sleeping {
                let zFont = Font.system(size: pixelSize * 3, weight: .bold, design: .monospaced)
                let text = Text("zzz").font(zFont).foregroundColor(.gray)
                let resolvedText = context.resolve(text)
                let textPoint = CGPoint(
                    x: 13 * pixelSize,
                    y: 1 * pixelSize - zzzOffset
                )
                context.opacity = zzzOpacity
                context.draw(resolvedText, at: textPoint, anchor: .leading)
                context.opacity = 1
            }
        }
    }
```

Note: arm trembling and antenna glow are removed from the body canvas — in `.busy` the body is invisible anyway (opacity 0), so we don't need to animate it.

- [ ] **Step 4: Add a stub `faceCanvas` that renders `ClydeSprite.busyFace` without any dynamic overrides yet.**

Below `bodyCanvas`, add:

```swift
    private var faceCanvas: some View {
        Canvas { context, _ in
            let sprite = ClydeSprite.busyFace

            for row in 0..<16 {
                for col in 0..<16 {
                    guard let color = sprite[row][col] else { continue }
                    let rect = CGRect(
                        x: CGFloat(col) * pixelSize,
                        y: CGFloat(row) * pixelSize,
                        width: pixelSize,
                        height: pixelSize
                    )
                    context.fill(Path(rect), with: .color(color))
                }
            }
        }
    }
```

- [ ] **Step 5: Add the opacity/state helpers at the bottom of the struct (before the closing `}`).**

```swift
    private func applyStateOpacity(animated: Bool) {
        let targetBody: Double = (state == .busy) ? 0 : 1
        let targetFace: Double = (state == .busy) ? 1 : 0
        if animated {
            withAnimation(.easeInOut(duration: 0.25)) {
                bodyOpacity = targetBody
                faceOpacity = targetFace
            }
        } else {
            bodyOpacity = targetBody
            faceOpacity = targetFace
        }
    }

    private func seedTerminalBuffer() {
        terminalBuffer = (0..<16).map { _ in randomTerminalGlyph() }
    }

    private func advanceTerminalBuffer() {
        guard state == .busy else { return }
        terminalBuffer.removeFirst()
        terminalBuffer.append(randomTerminalGlyph())
    }

    private func advanceEyeScan() {
        guard state == .busy else { return }
        // Cycle: 0, +1, 0, -1, ...
        let cycle = [0, 1, 0, -1]
        eyeScanOffset = cycle[(animationTick / 2) % cycle.count]
    }

    private func randomTerminalGlyph() -> Character {
        let roll = Int.random(in: 0..<100)
        if roll < 35 { return "•" }
        if roll < 60 { return "-" }
        return " "
    }
```

- [ ] **Step 6: Update `updateAnimations()` so the busy-specific tweaks still run.**

Replace the body of `updateAnimations()` with:

```swift
    private func updateAnimations() {
        switch state {
        case .busy:
            withAnimation(.easeInOut(duration: 0.15)) {
                antennaGlow.toggle()
            }
            armOffset = 0
            zzzOffset = 0
            zzzOpacity = 1
        case .idle:
            armOffset = 0
            antennaGlow = false
            zzzOffset = 0
            zzzOpacity = 1
        case .sleeping:
            armOffset = 0
            antennaGlow = false
            withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) {
                zzzOffset = pixelSize * 3
                zzzOpacity = 0.3
            }
        }
    }
```

- [ ] **Step 7: Build.**

Run: `xcodebuild -scheme Clyde -configuration Debug build 2>&1 | tail -20`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 8: Manual verification.**

Run the app. Toggle into `.busy` (start a Claude session or use the dev toggle). Expected: body fades out over ~250 ms and a static face fades in. No jump, no flicker. In `.idle` the existing body sprite is back, smile + blink intact.

- [ ] **Step 9: Commit.**

```bash
git add Clyde/Views/ClydeAnimationView.swift
git commit -m "feat(clyde): crossfade body and busy face layers"
```

---

## Task 3: Animate the face — eye scan, mouth, antenna glow

**Files:**
- Modify: `Clyde/Views/ClydeAnimationView.swift` (`faceCanvas`)

- [ ] **Step 1: Replace `faceCanvas` with an animated version that overlays pupils, mouth frames, and a pulsing antenna tip.**

```swift
    private var faceCanvas: some View {
        Canvas { context, _ in
            var sprite = ClydeSprite.busyFace

            // Antenna tip glow pulse (row 0, cols 7-8)
            if antennaGlow {
                let glow = Color(red: 0.5, green: 1.0, blue: 0.6)
                sprite[0][7] = glow
                sprite[0][8] = glow
            }

            // Draw base sprite
            for row in 0..<14 { // rows 14-15 handled separately as terminal bar
                for col in 0..<16 {
                    guard let color = sprite[row][col] else { continue }
                    let rect = CGRect(
                        x: CGFloat(col) * pixelSize,
                        y: CGFloat(row) * pixelSize,
                        width: pixelSize,
                        height: pixelSize
                    )
                    context.fill(Path(rect), with: .color(color))
                }
            }

            // Pupils: two 1x1 dots that shift by eyeScanOffset.
            // Socket whites are at cols 4-5 (left eye) and 10-11 (right eye) on rows 5-6.
            let pupilColor = Color(red: 0.08, green: 0.08, blue: 0.1)
            let blink = ((animationTick / 30) % 30) == 0 // blink once per ~6s
            if !blink {
                let leftBase = 4
                let rightBase = 10
                let offset = eyeScanOffset
                let leftX = CGFloat(leftBase + max(0, min(1, 0 + offset))) * pixelSize
                let rightX = CGFloat(rightBase + max(0, min(1, 0 + offset))) * pixelSize
                let y = CGFloat(5) * pixelSize
                context.fill(Path(CGRect(x: leftX, y: y, width: pixelSize, height: pixelSize * 2)), with: .color(pupilColor))
                context.fill(Path(CGRect(x: rightX, y: y, width: pixelSize, height: pixelSize * 2)), with: .color(pupilColor))
            }

            // Mouth row (row 8, cols 4..11) using mouthBusy frames.
            let mouthRow = 8
            let mouthPhase = animationTick % 3
            for localCol in 0..<8 {
                if let override = ClydeSprite.mouthBusy[mouthPhase][safe: localCol], let color = override {
                    let rect = CGRect(
                        x: CGFloat(mouthRow == mouthRow ? (4 + localCol) : 0) * pixelSize,
                        y: CGFloat(mouthRow) * pixelSize,
                        width: pixelSize,
                        height: pixelSize
                    )
                    context.fill(Path(rect), with: .color(color))
                }
            }

            // Terminal bar (rows 14-15) rendered in Task 4.
            drawTerminalBar(context: context)
        }
    }

    // Placeholder so the build succeeds; real implementation in Task 4.
    private func drawTerminalBar(context: GraphicsContext) {
        // Filled in Task 4.
    }
```

- [ ] **Step 2: Build.**

Run: `xcodebuild -scheme Clyde -configuration Debug build 2>&1 | tail -20`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Manual verification.**

Run the app, enter `.busy`. Expected: pupils scan slightly left/right, mouth animates open/half/closed, antenna tip pulses green. Bottom 2 rows remain empty (filled in Task 4).

- [ ] **Step 4: Commit.**

```bash
git add Clyde/Views/ClydeAnimationView.swift
git commit -m "feat(clyde): animate busy face (eyes, mouth, antenna)"
```

---

## Task 4: Draw the scrolling terminal bar

**Files:**
- Modify: `Clyde/Views/ClydeAnimationView.swift` (`drawTerminalBar`)

- [ ] **Step 1: Replace the placeholder `drawTerminalBar` with the real implementation.**

```swift
    private func drawTerminalBar(context: GraphicsContext) {
        let bgColor = Color(red: 0.05, green: 0.125, blue: 0.188) // #0d2030
        let glyphColor = Color(red: 0.349, green: 1.0, blue: 0.702).opacity(0.4) // #59ffb3 @ 40%

        // Fill the 16x2 background strip (rows 14 and 15).
        let bgRect = CGRect(
            x: 0,
            y: CGFloat(14) * pixelSize,
            width: CGFloat(16) * pixelSize,
            height: CGFloat(2) * pixelSize
        )
        context.fill(Path(bgRect), with: .color(bgColor))

        // Draw one glyph per cell (row 14 only; row 15 stays as background padding).
        for col in 0..<16 {
            let ch = terminalBuffer[col]
            switch ch {
            case "•":
                // A single filled pixel, vertically centered in the 2-row strip.
                let rect = CGRect(
                    x: CGFloat(col) * pixelSize,
                    y: CGFloat(14) * pixelSize + pixelSize * 0.25,
                    width: pixelSize,
                    height: pixelSize * 0.5
                )
                context.fill(Path(rect), with: .color(glyphColor))
            case "-":
                // A wider dash drawn as a thin horizontal line across the cell.
                let rect = CGRect(
                    x: CGFloat(col) * pixelSize + pixelSize * 0.1,
                    y: CGFloat(14) * pixelSize + pixelSize * 0.4,
                    width: pixelSize * 0.8,
                    height: pixelSize * 0.2
                )
                context.fill(Path(rect), with: .color(glyphColor))
            default:
                break // empty cell
            }
        }
    }
```

- [ ] **Step 2: Build.**

Run: `xcodebuild -scheme Clyde -configuration Debug build 2>&1 | tail -20`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Manual verification.**

Run the app, enter `.busy`. Expected: bottom strip shows a scrolling pattern of dots and dashes on a dark cyan-tinted background, shifting left roughly 5 times per second. Glyphs are visible but clearly subordinate to the eyes. Leave in `.busy` for 30 s — animation doesn't stall, no visible seam when the buffer wraps. Toggle to `.idle` — body fades back in, no terminal bar leaks through.

- [ ] **Step 4: Commit.**

```bash
git add Clyde/Views/ClydeAnimationView.swift
git commit -m "feat(clyde): add scrolling terminal bar to busy face"
```

---

## Self-Review Checklist (run after implementation)

- [ ] Widget in `WidgetView.swift` still renders at the same 22×22 frame — no layout jump.
- [ ] `.idle` → `.busy` → `.idle` round-trip is smooth (crossfade, no flicker, no state leaks).
- [ ] `.sleeping` visuals unchanged (Zzz still animating).
- [ ] Face canvas is not drawn when `faceOpacity == 0` visually (cheap, acceptable).
- [ ] Pupils readable at `pixelSize = 1.4` (the `WidgetView` value).
