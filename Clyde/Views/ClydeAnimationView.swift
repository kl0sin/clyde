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
}

struct ClydeAnimationView: View {
    let state: ClydeState
    let pixelSize: CGFloat

    @State private var animationTick: Int = 0
    @State private var armOffset: CGFloat = 0
    @State private var antennaGlow: Bool = false
    @State private var zzzOffset: CGFloat = 0
    @State private var zzzOpacity: Double = 1
    @State private var bodyOpacity: Double = 1
    @State private var faceOpacity: Double = 0
    @State private var eyeScanOffset: Int = 0 // -1, 0, or +1
    @State private var terminalBuffer: [Character] = Array(repeating: " ", count: 16)

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
        let cycle = [0, 1, 0, -1]
        eyeScanOffset = cycle[(animationTick / 2) % cycle.count]
    }

    private func randomTerminalGlyph() -> Character {
        let roll = Int.random(in: 0..<100)
        if roll < 35 { return "•" }
        if roll < 60 { return "-" }
        return " "
    }

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
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
