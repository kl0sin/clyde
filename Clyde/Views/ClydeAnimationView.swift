import SwiftUI

/// Precomputed coordinates of every non-transparent cell in the sprite
/// body. Used by the Canvas draw loop instead of iterating the full 16×16
/// grid (256 cells, ~226 of them transparent) on every animation tick.
struct SpriteCell {
    let row: Int
    let col: Int
    let color: Color
}

struct ClydeSprite {
    // 16x16 grid, each row is an array of optional colors.
    // nil = transparent, values = Color.
    //
    // Redesigned Clyde — minimal "robot face" silhouette: squircle head,
    // single-pixel antenna with green tip + glow halo, 2x2 eyes with a
    // top-left sparkle pixel, a 2-pixel closed grin, a forehead shine
    // highlight, and an inset right-side shadow that gives the head
    // dimensional weight without breaking the bounding box.
    static let body: [[Color?]] = {
        let e: Color? = nil
        let w: Color? = .white
        let h: Color? = Color(red: 0.910, green: 0.910, blue: 0.940) // forehead highlight
        let s: Color? = Color(red: 0.565, green: 0.565, blue: 0.627) // right-side shadow
        let b: Color? = Color(red: 0.100, green: 0.100, blue: 0.140) // outline / eyes / mouth
        let g: Color? = Color(red: 0.369, green: 0.910, blue: 0.518) // antenna tip
        let G: Color? = Color(red: 0.659, green: 1.000, blue: 0.769) // antenna glow halo
        let d: Color? = Color(red: 0.353, green: 0.353, blue: 0.416) // antenna stem (dim)

        return [
            //0  1  2  3  4  5  6  7  8  9 10 11 12 13 14 15
            [e, e, e, e, e, e, e, e, e, e, e, e, e, e, e, e], // 0
            [e, e, e, e, e, e, e, e, e, e, e, e, e, e, e, e], // 1
            [e, e, e, e, e, e, G, g, g, G, e, e, e, e, e, e], // 2  antenna tip + halo
            [e, e, e, e, e, e, e, d, d, e, e, e, e, e, e, e], // 3  stem
            [e, e, e, e, b, b, b, b, b, b, b, b, e, e, e, e], // 4  top border
            [e, e, e, b, w, h, h, h, h, h, h, w, s, b, e, e], // 5  forehead shine
            [e, e, b, w, w, w, w, w, w, w, w, w, w, s, b, e], // 6
            [e, e, b, w, w, w, b, w, w, w, b, w, w, s, b, e], // 7  eye top + sparkle
            [e, e, b, w, w, b, b, w, w, b, b, w, w, s, b, e], // 8  eye bottom
            [e, e, b, w, w, w, w, w, w, w, w, w, w, s, b, e], // 9
            [e, e, b, w, w, w, w, w, w, w, w, w, w, s, b, e], // 10
            [e, e, b, w, w, w, w, b, b, w, w, w, w, s, b, e], // 11 closed grin
            [e, e, b, w, w, w, w, w, w, w, w, w, w, s, b, e], // 12
            [e, e, e, b, w, w, w, w, w, w, w, w, s, b, e, e], // 13
            [e, e, e, e, b, b, b, b, b, b, b, b, e, e, e, e], // 14 bottom border
            [e, e, e, e, e, e, e, e, e, e, e, e, e, e, e, e], // 15
        ]
    }()

    /// Cached non-nil cells of `body`. Iterating this is ~50 entries
    /// instead of 256, eliminating ~80% of the per-tick work in the
    /// Canvas draw loop.
    static let bodyCells: [SpriteCell] = {
        var cells: [SpriteCell] = []
        cells.reserveCapacity(64)
        for row in 0..<16 {
            for col in 0..<16 {
                if let color = body[row][col] {
                    cells.append(SpriteCell(row: row, col: col, color: color))
                }
            }
        }
        return cells
    }()
}

/// Identifier for a single (row, col) cell of the 16×16 sprite, used by
/// the ambient idle animation system to override individual pixels for
/// brief moments (blink, smirk) without rebuilding the whole sprite.
private struct CellKey: Hashable {
    let row: Int
    let col: Int
}

struct ClydeAnimationView: View {
    let state: ClydeState
    let pixelSize: CGFloat
    /// When false, the ambient animation (blink + glance) is
    /// suppressed entirely. Mini sprites in the session list pass false
    /// here so the row indicators stay perfectly still — only the
    /// header / widget mascots breathe.
    ///
    /// (Historical name kept for source-compat. The animation runs in
    /// every non-sleeping state, not only `.idle`, so the user sees
    /// Clyde "alive" while sessions are working or waiting on
    /// permission too.)
    let ambientIdleEnabled: Bool

    @State private var animationTick: Int = 0
    @State private var antennaGlow: Bool = false
    @State private var zzzOffset: CGFloat = 0
    @State private var zzzOpacity: Double = 1

    /// Per-cell colour overrides applied for the duration of an ambient
    /// idle action (blink, smirk). Empty in the steady state. When
    /// non-empty, the Canvas falls off the cached `bodyCells` fast path
    /// and walks the full 16×16 grid so it can apply per-cell mutations.
    @State private var idleOverrides: [CellKey: Color] = [:]

    /// Long-running Task that drives the ambient idle loop. Cancelled
    /// whenever `state` leaves `.idle` or the view disappears.
    @State private var ambientTask: Task<Void, Never>?

    /// Outline / mouth colour, hoisted out of `ClydeSprite.body` so the
    /// ambient overrides can reuse the exact same dark tone for new
    /// mouth pixels.
    private static let outlineColor = Color(red: 0.100, green: 0.100, blue: 0.140)

    init(state: ClydeState, pixelSize: CGFloat = 3, ambientIdleEnabled: Bool = true) {
        self.state = state
        self.pixelSize = pixelSize
        self.ambientIdleEnabled = ambientIdleEnabled
    }

    private var gridWidth: CGFloat { 16 * pixelSize }
    private var gridHeight: CGFloat { 16 * pixelSize }

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.3)) { timeline in
            Canvas { context, _ in
                // Antenna tip cells whose colour we override per state.
                let tipCols: ClosedRange<Int> = 6...9
                let tipRow = 1

                /// Resolve the colour for a single cell, applying the
                /// state-driven antenna recolour and the ambient idle
                /// overrides. Pulled out so both the fast path
                /// (cached `bodyCells`) and the slow path (full 16×16
                /// grid, used while ambient overrides are active) can
                /// share the exact same logic.
                func resolvedColor(row: Int, col: Int, base: Color) -> Color {
                    var color = base
                    if row == tipRow && tipCols.contains(col) {
                        switch state {
                        case .busy:
                            color = antennaGlow
                                ? Color(red: 0.85, green: 0.55, blue: 1.0)
                                : Color(red: 0.749, green: 0.353, blue: 0.949)
                        case .attention:
                            color = antennaGlow
                                ? Color(red: 0.55, green: 0.80, blue: 1.0)
                                : Color(red: 0.30, green: 0.60, blue: 1.0)
                        case .sleeping:
                            color = Color(white: 0.35)
                        case .idle:
                            break
                        }
                    }
                    return color
                }

                func drawCell(row: Int, col: Int, color: Color) {
                    let rect = CGRect(
                        x: CGFloat(col) * pixelSize,
                        y: CGFloat(row) * pixelSize,
                        width: pixelSize,
                        height: pixelSize
                    )
                    context.fill(Path(rect), with: .color(color))
                }

                if idleOverrides.isEmpty {
                    // Fast path — iterate the cached non-transparent cells.
                    // ~50 entries instead of 256.
                    for cell in ClydeSprite.bodyCells {
                        let color = resolvedColor(row: cell.row, col: cell.col, base: cell.color)
                        drawCell(row: cell.row, col: cell.col, color: color)
                    }
                } else {
                    // Slow path — walk the full 16×16 grid so we can apply
                    // per-cell overrides (including pixels that are
                    // transparent in the base sprite, e.g. the smirk's
                    // extra mouth pixel). Only runs during the ~150–700 ms
                    // window of an active ambient action, so the cost is
                    // negligible.
                    for row in 0..<16 {
                        for col in 0..<16 {
                            let key = CellKey(row: row, col: col)
                            let base: Color?
                            if let override = idleOverrides[key] {
                                base = override
                            } else {
                                base = ClydeSprite.body[row][col]
                            }
                            guard let baseColor = base else { continue }
                            let color = resolvedColor(row: row, col: col, base: baseColor)
                            drawCell(row: row, col: col, color: color)
                        }
                    }
                }

                // "!" mark above head for attention state — bobs gently.
                if state == .attention {
                    let exclamFont = Font.system(size: pixelSize * 4, weight: .heavy, design: .rounded)
                    let text = Text("!").font(exclamFont).foregroundColor(Color(red: 1.0, green: 0.85, blue: 0.2))
                    let resolved = context.resolve(text)
                    let point = CGPoint(
                        x: 13 * pixelSize,
                        y: 0 * pixelSize - zzzOffset
                    )
                    context.opacity = zzzOpacity
                    context.draw(resolved, at: point, anchor: .leading)
                    context.opacity = 1
                }

                // "zzz" for sleeping — drifts upward as it fades.
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
            .frame(width: gridWidth, height: gridHeight)
            .onChange(of: timeline.date) { _ in
                animationTick += 1
                updateAnimations()
            }
        }
        .onAppear {
            updateAnimations()
            if ambientIdleEnabled && state != .sleeping {
                startAmbientLoop()
            }
        }
        .onDisappear {
            stopAmbientLoop()
        }
        .onChange(of: state) { newState in
            animationTick = 0
            updateAnimations()
            // Run the ambient blink/glance loop in every non-sleeping
            // state. Earlier versions gated it strictly on `.idle`,
            // which left the busy and attention mascots visually
            // frozen — users reported it as "Clyde isn't animated
            // anymore". Sleeping is still excluded because the snore
            // animation owns the sprite then.
            if ambientIdleEnabled && newState != .sleeping {
                startAmbientLoop()
            } else {
                stopAmbientLoop()
            }
        }
    }

    // MARK: - Ambient idle animation
    //
    // While the mascot is in `.idle`, a long-running Task alternates
    // between two micro-actions to make the sprite feel alive without
    // ever being distracting:
    //
    //   • Blink  — both eyes briefly squeeze shut for ~140 ms
    //   • Glance — pupils slide one column to one side and back
    //
    // Actions strictly alternate (blink → glance → blink → glance …) and
    // are spaced by a randomised 5–7 s gap so the rhythm doesn't read
    // as a metronome. The first action is offset by 0.8–2.4 s so the
    // expanded-header mascot and the widget mascot don't fire in
    // perfect sync. The Task is cancelled the moment `state` leaves
    // `.idle` (working / attention have their own, louder animations
    // that would clash) and on `.onDisappear`.

    private func startAmbientLoop() {
        ambientTask?.cancel()
        ambientTask = Task { @MainActor in
            // Initial desync so multiple ClydeAnimationViews on screen
            // don't blink in lockstep.
            try? await Task.sleep(for: .milliseconds(Int.random(in: 800...2400)))
            if Task.isCancelled { return }

            var nextIsBlink = Bool.random()
            while !Task.isCancelled {
                if nextIsBlink {
                    await playBlink()
                } else {
                    await playGlance()
                }
                if Task.isCancelled { break }
                nextIsBlink.toggle()

                let wait = Double.random(in: 5.0...7.0)
                try? await Task.sleep(for: .seconds(wait))
            }
        }
    }

    private func stopAmbientLoop() {
        ambientTask?.cancel()
        ambientTask = nil
        if !idleOverrides.isEmpty {
            idleOverrides = [:]
        }
    }

    /// Both eyes squeeze closed for ~140 ms by whitening the top
    /// dark pupil pixels (rows 7 col 6 / col 10). The bottom row of
    /// the pupil stays dark, which reads as a thin closed-eye line at
    /// every render size from the 24 px session indicator up to the
    /// 56 px expanded header.
    private func playBlink() async {
        idleOverrides = [
            CellKey(row: 7, col: 6):  .white,
            CellKey(row: 7, col: 10): .white,
        ]
        try? await Task.sleep(for: .milliseconds(140))
        if Task.isCancelled { return }
        idleOverrides = [:]
    }

    /// Both pupils slide one column to one side, hold for ~480 ms, and
    /// return to centre. Direction is randomised per invocation so the
    /// animation reads as a casual glance rather than a fixed tic.
    ///
    /// The base sprite encodes each pupil as an L-shape:
    ///   left  pupil = {(7,6), (8,5), (8,6)}  with a sparkle at (7,5)
    ///   right pupil = {(7,10), (8,9), (8,10)} with a sparkle at (7,11)
    ///
    /// Shifting the L-shape by ±1 column requires darkening the new
    /// position cells and whitening the cells the pupil left behind.
    private func playGlance() async {
        idleOverrides = Bool.random() ? Self.lookLeftOverrides : Self.lookRightOverrides
        try? await Task.sleep(for: .milliseconds(480))
        if Task.isCancelled { return }

        idleOverrides = [:]
    }

    /// Override map that shifts both pupils one column to the left.
    /// Cached as a static so each invocation skips re-allocation.
    private static let lookLeftOverrides: [CellKey: Color] = [
        // LEFT eye: pupil L-shape {(7,6),(8,5),(8,6)} → {(7,5),(8,4),(8,5)}
        CellKey(row: 7, col: 5):  outlineColor, // new pupil top
        CellKey(row: 8, col: 4):  outlineColor, // new pupil bottom-left
        CellKey(row: 7, col: 6):  .white,       // old pupil top → blank
        CellKey(row: 8, col: 6):  .white,       // old pupil bottom-right → blank

        // RIGHT eye: pupil L-shape {(7,10),(8,9),(8,10)} → {(7,9),(8,8),(8,9)}
        CellKey(row: 7, col: 9):  outlineColor,
        CellKey(row: 8, col: 8):  outlineColor,
        CellKey(row: 7, col: 10): .white,
        CellKey(row: 8, col: 10): .white,
    ]

    /// Override map that shifts both pupils one column to the right.
    private static let lookRightOverrides: [CellKey: Color] = [
        // LEFT eye: pupil L-shape {(7,6),(8,5),(8,6)} → {(7,7),(8,6),(8,7)}
        CellKey(row: 7, col: 7):  outlineColor,
        CellKey(row: 8, col: 7):  outlineColor,
        CellKey(row: 7, col: 6):  .white,
        CellKey(row: 8, col: 5):  .white,

        // RIGHT eye: pupil L-shape {(7,10),(8,9),(8,10)} → {(7,11),(8,10),(8,11)}
        CellKey(row: 7, col: 11): outlineColor,
        CellKey(row: 8, col: 11): outlineColor,
        CellKey(row: 7, col: 10): .white,
        CellKey(row: 8, col: 9):  .white,
    ]

    private func updateAnimations() {
        switch state {
        case .busy:
            withAnimation(.easeInOut(duration: 0.4)) {
                antennaGlow.toggle()
            }
            zzzOffset = 0
            zzzOpacity = 1
        case .idle:
            antennaGlow = false
            zzzOffset = 0
            zzzOpacity = 1
        case .attention:
            withAnimation(.easeInOut(duration: 0.3)) {
                antennaGlow.toggle()
            }
            withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
                zzzOffset = pixelSize * 0.6
                zzzOpacity = 0.5
            }
        case .sleeping:
            antennaGlow = false
            withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) {
                zzzOffset = pixelSize * 3
                zzzOpacity = 0.3
            }
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
