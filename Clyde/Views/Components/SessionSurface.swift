import SwiftUI

/// The surface a session's row is drawn on, in both panels.
///
/// It began as the compact card's background and stayed there while the
/// full panel kept a flat tint — so the same state was a textured,
/// swept, softly lit card in one window and a block of colour in the
/// other. The texture was the better half of that pair and the colour
/// was the louder half, so the texture moved and the colour came down.
///
/// The state is the surface: a wash falling off from the leading edge
/// rather than a coloured outline, so a busy session reads as warm
/// instead of ringed. A rail down the left edge said the same thing a
/// third time, in the way every generated card on the web currently
/// says it, and was dropped.
struct SessionSurface: View {
    let state: PixelStatusIndicator.State
    let accent: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How strong the wash is.
    ///
    /// Compact ran these at 0.20 and 0.22 and read as tinted rather
    /// than lit — a card the colour of the state instead of a card the
    /// state is happening on. The full panel's flat 0.07 was the other
    /// extreme. These sit between, and both windows use them.
    static func washOpacity(for state: PixelStatusIndicator.State) -> Double {
        switch state {
        case .idle: return 0
        case .working: return 0.12
        case .needsAttention: return 0.14
        }
    }

    /// How strong the hatching is.
    ///
    /// Raised from 0.075 when the wash came down: the hatching itself
    /// never changed, but a lighter ground under it made the same
    /// contrast read as less texture. Measured along one line of a row,
    /// this is the swing between a hatched point and the one beside it
    /// — a few units out of 255, which is where it belongs. It is meant
    /// to be felt rather than seen.
    static let ditherOpacity: Double = 0.10

    static func borderColour(state: PixelStatusIndicator.State, accent: Color) -> Color {
        state == .idle ? .white.opacity(0.05) : accent.opacity(0.18)
    }

    var body: some View {
        ZStack {
            if state != .idle {
                RadialGradient(
                    colors: [accent.opacity(Self.washOpacity(for: state)), .clear],
                    center: .leading,
                    startRadius: 0,
                    endRadius: 260
                )
                // The mascot is pixel art; this is that world at the
                // scale of a surface. Fades out across the row so it
                // stays at the threshold of visible.
                DitherField()
                    .mask(
                        LinearGradient(colors: [.black.opacity(0.85), .clear],
                                       startPoint: .leading, endPoint: .trailing)
                    )
            }
        }
        .overlay(alignment: .top) {
            // One hairline gradient is the whole difference between a
            // rectangle and something raised.
            if state != .idle {
                LinearGradient(colors: [.clear, .white.opacity(0.14), .clear],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(height: 1)
            }
        }
        .overlay(alignment: .bottom) {
            // The sweep belongs to work, not to waiting. Held still for
            // an attention row it stopped being light crossing the
            // surface and became a coloured bottom border — and the
            // whole point of that state is that it does not move.
            if state == .working {
                SweepLine(color: accent, animates: !reduceMotion)
            }
        }
        .allowsHitTesting(false)
    }
}

/// One-pixel diagonal hatching. Drawn rather than tiled from an asset so
/// it stays exactly one pixel at any scale factor.
struct DitherField: View {
    var body: some View {
        Canvas { context, size in
            // Wider apart and a touch stronger than the mockup's CSS:
            // one CSS pixel is half a point on this display, so the
            // literal port came out invisible.
            let spacing: CGFloat = 4
            var offset = -size.height
            let colour = GraphicsContext.Shading.color(.white.opacity(SessionSurface.ditherOpacity))
            while offset < size.width {
                var line = Path()
                line.move(to: CGPoint(x: offset, y: size.height))
                line.addLine(to: CGPoint(x: offset + size.height, y: 0))
                context.stroke(line, with: colour, lineWidth: 1)
                offset += spacing
            }
        }
        .allowsHitTesting(false)
    }
}

/// A lit segment crossing the bottom edge of an active card — the
/// wave's cousin at the scale of the card. Clock-driven for the same
/// reason the wave is: `.repeatForever` started in `onAppear` is
/// unreliable for rows that have just appeared.
struct SweepLine: View {
    let color: Color
    let animates: Bool

    private let period: Double = 2.4

    var body: some View {
        GeometryReader { proxy in
            if animates {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    let phase = (t.truncatingRemainder(dividingBy: period)) / period
                    segment(width: proxy.size.width, phase: phase)
                }
            } else {
                Rectangle()
                    .fill(color.opacity(0.28))
                    .frame(height: 1)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
        .frame(height: 1)
        .allowsHitTesting(false)
    }

    private func segment(width: CGFloat, phase: Double) -> some View {
        let segmentWidth = width * 0.28
        let travel = width + segmentWidth
        // At full strength this read as a coloured bottom border rather
        // than as light crossing the card — the eye takes a saturated
        // hairline as structure.
        return LinearGradient(colors: [.clear, color.opacity(0.38), .clear],
                              startPoint: .leading, endPoint: .trailing)
            .frame(width: segmentWidth, height: 1)
            .offset(x: -segmentWidth + travel * phase)
            .frame(width: width, alignment: .leading)
            .clipped()
    }
}

/// One pixel beside a running duration, blinking once a second.
