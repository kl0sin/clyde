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

struct ClydeAnimationView: View {
    let state: ClydeState
    let pixelSize: CGFloat

    @State private var animationTick: Int = 0
    @State private var antennaGlow: Bool = false
    @State private var zzzOffset: CGFloat = 0
    @State private var zzzOpacity: Double = 1

    init(state: ClydeState, pixelSize: CGFloat = 3) {
        self.state = state
        self.pixelSize = pixelSize
    }

    private var gridWidth: CGFloat { 16 * pixelSize }
    private var gridHeight: CGFloat { 16 * pixelSize }

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.3)) { timeline in
            Canvas { context, _ in
                // Antenna tip cells whose colour we override per state.
                let tipCols: ClosedRange<Int> = 6...9
                let tipRow = 1

                for cell in ClydeSprite.bodyCells {
                    let row = cell.row
                    let col = cell.col
                    var color = cell.color

                    // State-driven antenna colour. The base sprite stores the
                    // tip in green; for busy/attention we recolour the same
                    // pixels so the antenna pulses in the dominant colour.
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
                            break // keep original green tip + halo
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
        .onAppear { updateAnimations() }
        .onChange(of: state) { _ in
            animationTick = 0
            updateAnimations()
        }
    }

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
