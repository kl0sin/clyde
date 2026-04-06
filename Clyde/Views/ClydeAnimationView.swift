import SwiftUI

struct ClydeSprite {
    // 16x16 grid, each row is an array of optional colors
    // nil = transparent, values = Color
    static let body: [[Color?]] = {
        let e: Color? = nil                                       // empty
        let w: Color? = .white                                    // main body white
        let g: Color? = Color(red: 0.3, green: 1.0, blue: 0.5)    // antenna tip (glow green)
        let h: Color? = Color(white: 0.95)                        // highlight edge
        let d: Color? = Color(white: 0.65)                        // shadow / detail
        let b: Color? = Color(red: 0.08, green: 0.08, blue: 0.1)  // dark (outline/eyes)
        let c: Color? = Color(red: 0.35, green: 0.7, blue: 1.0)   // cyan chest panel
        let y: Color? = Color(red: 1.0, green: 0.85, blue: 0.2)   // yellow bolt
        let f: Color? = Color(white: 0.45)                        // feet (darker)

        return [
            //0  1  2  3  4  5  6  7  8  9 10 11 12 13 14 15
            [e, e, e, e, e, e, e, g, g, e, e, e, e, e, e, e], // 0  antenna tip
            [e, e, e, e, e, e, e, d, d, e, e, e, e, e, e, e], // 1  antenna stem
            [e, e, e, e, e, e, b, d, d, b, e, e, e, e, e, e], // 2  antenna base
            [e, e, e, e, b, b, h, h, h, h, b, b, e, e, e, e], // 3  head top + outline
            [e, e, e, b, h, w, w, w, w, w, w, h, b, e, e, e], // 4  head
            [e, e, e, b, w, b, b, w, w, b, b, w, b, e, e, e], // 5  eyes (outer)
            [e, e, e, b, w, b, b, w, w, b, b, w, b, e, e, e], // 6  eyes (inner)
            [e, e, e, b, w, w, w, w, w, w, w, w, b, e, e, e], // 7  cheeks
            [e, e, e, b, h, w, w, w, w, w, w, h, b, e, e, e], // 8  head bottom
            [e, e, e, e, b, b, b, b, b, b, b, b, e, e, e, e], // 9  neck outline
            [e, e, b, h, w, c, c, c, c, c, c, w, h, b, e, e], // 10 shoulders + chest
            [e, e, b, w, y, c, c, c, c, c, c, y, w, b, e, e], // 11 bolts + chest
            [e, e, b, h, w, c, c, c, c, c, c, w, h, b, e, e], // 12 body
            [e, e, e, b, b, d, d, d, d, d, d, b, b, e, e, e], // 13 waist
            [e, e, e, e, b, f, f, b, b, f, f, b, e, e, e, e], // 14 feet top
            [e, e, e, e, b, b, b, e, e, b, b, b, e, e, e, e], // 15 feet bottom
        ]
    }()

    // Eye blink frame: rows 5-6 with closed eyes
    static let eyesClosed: [[Color?]] = {
        let w: Color? = .white
        let b: Color? = Color(red: 0.1, green: 0.1, blue: 0.1)
        return [
            [w, w, w, w, w, w, w, w], // row 5 - eyes closed (line)
            [w, b, b, w, w, b, b, w], // row 6 - half-open
        ]
    }()

    // Smile mouth (idle): row 7
    static let mouthSmile: [Color?] = {
        let w: Color? = .white
        let g: Color? = Color(red: 0.3, green: 1.0, blue: 0.5)
        return [w, w, g, w, w, g, w, w] // green corners = smile
    }()

    // Animated mouth frames (busy): 3 phases
    static let mouthBusy: [[Color?]] = {
        let w: Color? = .white
        let b: Color? = Color(red: 0.1, green: 0.1, blue: 0.1)
        return [
            [w, w, b, b, b, b, w, w], // open
            [w, w, w, b, b, w, w, w], // half
            [w, w, w, w, w, w, w, w], // closed
        ]
    }()

    // Sleeping eyes: row 5-6
    static let eyesSleeping: [[Color?]] = {
        let w: Color? = .white
        let b: Color? = Color(red: 0.1, green: 0.1, blue: 0.1)
        return [
            [w, b, b, w, w, b, b, w], // row 5 - line eyes
            [w, w, w, w, w, w, w, w], // row 6 - closed
        ]
    }()

    // Pip v2: head-only character, fills 16x16, cyan accents.
    static let busyFace: [[Color?]] = {
        let e: Color? = nil
        let w: Color? = .white
        let h: Color? = Color(white: 0.91)
        let b: Color? = Color(red: 0.08, green: 0.08, blue: 0.1)
        let c: Color? = Color(red: 0.36, green: 0.88, blue: 1.0)
        let C: Color? = Color(red: 0.66, green: 0.94, blue: 1.0)
        let D: Color? = Color(red: 0.16, green: 0.56, blue: 0.70)
        let p: Color? = Color(red: 1.0, green: 0.70, blue: 0.78)
        let y: Color? = Color(red: 1.0, green: 0.87, blue: 0.33)

        return [
            //0  1  2  3  4  5  6  7  8  9 10 11 12 13 14 15
            [e, e, e, e, e, e, y, b, e, e, e, e, e, e, e, e], // 0  cowlick tip
            [e, e, e, e, e, e, y, b, e, e, e, e, e, e, e, e], // 1  cowlick base
            [e, e, e, b, b, b, b, b, b, b, b, b, b, e, e, e], // 2  head top
            [e, e, b, h, h, h, h, h, h, h, h, h, h, b, e, e], // 3  head top fill
            [e, b, h, w, w, w, w, w, w, w, w, w, w, h, b, e], // 4  forehead
            [b, h, w, w, w, w, w, w, w, w, w, w, w, w, h, b], // 5  brow line (overdrawn in busy)
            [b, h, w, D, D, D, D, h, h, D, D, D, D, w, h, b], // 6  eye frames top
            [b, h, w, D, c, c, D, h, h, D, c, c, D, w, h, b], // 7  eye whites top
            [b, h, w, D, c, C, D, h, h, D, c, C, D, w, h, b], // 8  eye highlight
            [b, h, w, D, c, c, D, h, h, D, c, c, D, w, h, b], // 9  eye whites bot
            [b, h, w, D, D, D, D, h, h, D, D, D, D, w, h, b], // 10 eye frames bot
            [b, h, w, p, h, h, h, h, h, h, h, h, p, w, h, b], // 11 blush
            [b, h, w, w, w, w, w, b, b, w, w, w, w, w, h, b], // 12 mouth (small 'o')
            [e, b, h, w, w, w, w, w, w, w, w, w, w, h, b, e], // 13 chin
            [e, e, b, c, c, c, c, c, c, c, c, c, c, b, e, e], // 14 cyan jaw accent
            [e, e, e, b, b, b, b, b, b, b, b, b, b, e, e, e], // 15 bottom outline
        ]
    }()
}

struct ClydeAnimationView: View {
    let state: ClydeState
    let pixelSize: CGFloat

    @State private var animationTick: Int = 0
    @State private var antennaGlow: Bool = false
    @State private var zzzOffset: CGFloat = 0
    @State private var zzzOpacity: Double = 1
    @State private var bodyOpacity: Double = 1
    @State private var faceOpacity: Double = 0
    @State private var eyeScanOffset: Int = 0 // -1, 0, or +1

    init(state: ClydeState, pixelSize: CGFloat = 3) {
        self.state = state
        self.pixelSize = pixelSize
    }

    private var gridWidth: CGFloat { 16 * pixelSize }
    private var gridHeight: CGFloat { 16 * pixelSize }

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
                advanceEyeScan()
                updateAnimations()
            }
        }
        .onAppear {
            applyStateOpacity(animated: false)
            updateAnimations()
        }
        .onChange(of: state) { _ in
            animationTick = 0
            applyStateOpacity(animated: true)
            updateAnimations()
        }
    }

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

    private var faceCanvas: some View {
        Canvas { context, _ in
            var sprite = ClydeSprite.busyFace

            // --- Cowlick twitch: shift cowlick column left/right every ~4 ticks ---
            let cowlickShift = [0, 1, 0, -1][(animationTick / 4) % 4]
            // Clear original cowlick cols (6,7)
            sprite[0][6] = nil; sprite[0][7] = nil
            sprite[1][6] = nil; sprite[1][7] = nil
            let baseCol = 6 + cowlickShift
            if baseCol >= 0 && baseCol + 1 < 16 {
                sprite[0][baseCol] = Color(red: 1.0, green: 0.87, blue: 0.33) // y
                sprite[0][baseCol + 1] = Color(red: 0.08, green: 0.08, blue: 0.1) // b
                sprite[1][baseCol] = Color(red: 1.0, green: 0.87, blue: 0.33)
                sprite[1][baseCol + 1] = Color(red: 0.08, green: 0.08, blue: 0.1)
            }

            // --- Pulsing cyan jaw (row 14): swap between c and C based on antennaGlow ---
            if antennaGlow {
                let bright = Color(red: 0.66, green: 0.94, blue: 1.0)
                for col in 3...12 {
                    sprite[14][col] = bright
                }
            }

            // --- Determined mouth in busy: override row 12 cols 5..10 with dark ---
            let darkColor = Color(red: 0.08, green: 0.08, blue: 0.1)
            for col in 5...10 {
                sprite[12][col] = darkColor
            }

            // --- Blink every ~3s (every 15 ticks at 0.2s interval): close eyes ---
            let blinking = (animationTick % 15) == 0
            if blinking {
                // Replace eye rows 6-10 interiors (cols 3..6 and 9..12) with a single dark line on row 8
                // First, repaint eye areas as skin
                for row in 6...10 {
                    for col in 3...6 { sprite[row][col] = sprite[row][2] } // use 'w' skin from col 2
                    for col in 9...12 { sprite[row][col] = sprite[row][2] }
                }
                // Draw closed eye line on row 8
                for col in 3...6 { sprite[8][col] = darkColor }
                for col in 9...12 { sprite[8][col] = darkColor }
            } else {
                // --- Scanning squinted eyes (busy focus look) ---
                // Repaint eye interiors as light, then draw a horizontal dark squint line + one pupil dot per eye
                let skin = Color(white: 0.95)
                for row in 7...9 {
                    for col in 4...5 { sprite[row][col] = skin }
                    for col in 10...11 { sprite[row][col] = skin }
                }
                // Horizontal dark squint line on row 8
                for col in 4...5 { sprite[8][col] = darkColor }
                for col in 10...11 { sprite[8][col] = darkColor }
                // Pupil dot shifts by eyeScanOffset (-1, 0, +1)
                let leftPupilCol = 4 + max(0, min(1, eyeScanOffset + 1)) // 4, 5, or 5
                let rightPupilCol = 10 + max(0, min(1, eyeScanOffset + 1))
                sprite[8][leftPupilCol] = darkColor
                sprite[8][rightPupilCol] = darkColor
            }

            // --- Draw the whole sprite (all 16 rows, including jaw) ---
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

            // --- Sparks: 1-2 small cyan dots at random positions around the head, refreshed every ~2 ticks ---
            let sparkColor = Color(red: 0.66, green: 0.94, blue: 1.0).opacity(0.85)
            let sparkSeed = animationTick / 2
            var rng = SeededRandom(seed: UInt64(sparkSeed))
            let sparkCount = Int.random(in: 1...2, using: &rng)
            for _ in 0..<sparkCount {
                // Pick a position in the outer ring (rows 0..1 or 14..15 or cols 0..1 or 14..15)
                let side = Int.random(in: 0..<4, using: &rng)
                var sparkRow = 0
                var sparkCol = 0
                switch side {
                case 0: // top
                    sparkRow = Int.random(in: 0...1, using: &rng)
                    sparkCol = Int.random(in: 0...15, using: &rng)
                case 1: // bottom
                    sparkRow = Int.random(in: 14...15, using: &rng)
                    sparkCol = Int.random(in: 0...15, using: &rng)
                case 2: // left
                    sparkRow = Int.random(in: 2...13, using: &rng)
                    sparkCol = Int.random(in: 0...1, using: &rng)
                default: // right
                    sparkRow = Int.random(in: 2...13, using: &rng)
                    sparkCol = Int.random(in: 14...15, using: &rng)
                }
                let rect = CGRect(
                    x: CGFloat(sparkCol) * pixelSize + pixelSize * 0.25,
                    y: CGFloat(sparkRow) * pixelSize + pixelSize * 0.25,
                    width: pixelSize * 0.5,
                    height: pixelSize * 0.5
                )
                context.fill(Path(rect), with: .color(sparkColor))
            }
        }
    }

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

    private func advanceEyeScan() {
        guard state == .busy else { return }
        let cycle = [0, 1, 0, -1]
        eyeScanOffset = cycle[(animationTick / 2) % cycle.count]
    }

    private func updateAnimations() {
        switch state {
        case .busy:
            withAnimation(.easeInOut(duration: 0.15)) {
                antennaGlow.toggle()
            }
            zzzOffset = 0
            zzzOpacity = 1
        case .idle:
            antennaGlow = false
            zzzOffset = 0
            zzzOpacity = 1
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

struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}
