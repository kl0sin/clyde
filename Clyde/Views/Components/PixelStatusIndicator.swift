import SwiftUI

/// A four-by-four grid of pixels with light travelling across it on the
/// diagonal, while a session works.
///
/// The shape a column of rows is scanned by. Six drafts came before it:
/// a 2x2 grid (the Windows 8 logo), a ring of dots (every loader on the
/// web, and round where this app is square), the mascot's own antenna
/// lifted out of the sprite, three rising bars, no mark at all, and the
/// mascot itself — which is the app's face and was saying "Clyde" on a
/// row that is already a Clyde session.
///
/// What settled it was not the shape but the motion. Every earlier
/// draft moved in steps: a bar handing over to the next bar, a lit row
/// handing over to the row below. A diagonal wave has no handover and
/// no lap — brightness is a continuous function of position and time,
/// so there is no frame where something jumps, and no moment where the
/// animation visibly starts again.
struct PixelStatusIndicator: View {

    enum State: Equatable {
        case working
        case idle
        case needsAttention
    }

    let state: State
    /// The slot the mark is drawn inside. Every other dimension comes
    /// from it.
    let slot: CGFloat

    /// The grid is square, and four is the smallest width where a
    /// diagonal reads as a diagonal rather than as a corner.
    static let columns = 4

    /// The wave's period. Slower than the 1.2s the bars ran at: this
    /// window is meant to stay open beside the work, and the mockup's
    /// speed control made the case that the calmer end of the range is
    /// the one you can live with all day.
    static let cycle: Double = 1.6

    /// How many cells the wave spans end to end. The grid's longest
    /// diagonal is seven cells (row + column runs 0…6), so at eight the
    /// wave is always mid-travel: the leading edge has not yet reached
    /// the far corner when the next crest enters at the near one.
    static let wavelength: Double = 8

    /// How often the wave is redrawn. 30fps rather than 60: the motion
    /// is a slow fade in opacity, not something travelling across
    /// pixels, and this window is meant to stay open all day. The test
    /// that guards against stepped motion measures at exactly this
    /// rate — asserting smoothness at a frame rate we never render
    /// would be asserting nothing.
    static let frameInterval: Double = 1.0 / 30.0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // MARK: - The decisions, testable without a view

    /// Attention outranks work: a session waiting on an answer is not
    /// merely busy, and in compact mode the row is the only place that
    /// says so.
    static func state(for session: Session) -> State {
        if session.needsAttention { return .needsAttention }
        return session.isWorking ? .working : .idle
    }

    /// Only work animates continuously. Attention is meant to be
    /// noticed once and then stay legible while it is dealt with — an
    /// indicator that flashes until you act is the pattern everybody
    /// mutes.
    static func animates(_ state: State) -> Bool {
        state == .working
    }

    static func color(for state: State) -> Color {
        switch state {
        case .working: return SessionTheme.processingColor
        case .idle: return SessionTheme.readyColor
        case .needsAttention: return SessionTheme.attentionColor
        }
    }

    /// What a pixel looks like at the trough. Filled for attention, dim
    /// for idle, dimmer still for a working pixel the wave has left —
    /// so the three read apart in a screenshot, or for someone who
    /// cannot tell the colours apart.
    static func restingOpacity(_ state: State) -> Double {
        switch state {
        case .needsAttention: return 1.0
        case .idle: return 0.7
        // Low enough that the crest is unmistakable, high enough that
        // the grid never stops being a grid: the wave should read as
        // light crossing an object, not as cells switching on in a void.
        case .working: return 0.24
        }
    }

    /// The slot the mark sits in, in both modes. These lived as
    /// separate hand-tuned numbers per mode until a side-by-side
    /// capture showed the full panel's frame reading a third brighter
    /// than compact's — the mark was one thing and its frame was two.
    static let slotFillOpacity: Double = 0.16
    static let slotStrokeOpacity: Double = 0.45

    /// The quiet slot — the one holding a session number. Both modes
    /// take the full panel's greys: compact's were lighter to sit on
    /// its card, but a session's slot should not change weight with the
    /// window it is in.
    static let quietSlotFill = Color(white: 0.11)
    static let quietSlotStroke = Color(white: 0.18)

    // MARK: - The attention pulse

    /// How long one breath of the attention badge takes, in and out.
    static let attentionPulseCycle: Double = 1.4

    /// The pulse's position, 0…1, at a given moment.
    ///
    /// A function of the clock for the same reason the wave is: the
    /// pulse used to be a `.repeatForever` animation started in
    /// `onAppear`, which fires when the row appears and never again. A
    /// session that is already on screen when the question arrives —
    /// which is the ordinary case — got a badge that never moved.
    static func attentionPulse(at time: Double) -> Double {
        (1 - cos(time / attentionPulseCycle * 2 * .pi)) / 2
    }

    /// The badge breathes between these two.
    static func attentionScale(at pulse: Double) -> CGFloat {
        0.92 + 0.18 * pulse
    }

    /// And the slot's border brightens with it, so the whole mark is
    /// one movement rather than a disc moving beside a static frame.
    static func attentionStrokeOpacity(at pulse: Double) -> Double {
        slotStrokeOpacity + 0.2 * pulse
    }

    /// How thick that border is, also derived from the slot. The two
    /// modes had 1.5 and 1.0 — which happen to be nearly proportional,
    /// so the difference never showed, but only by luck: nothing tied
    /// them together and either could have been changed alone.
    static func slotStrokeWidth(slot: CGFloat) -> CGFloat { slot * 0.044 }

    // MARK: - Geometry

    /// Every dimension of the mark, in whole points.
    ///
    /// Whole points matter more than exact proportions here. The first
    /// version derived fractional sizes from the slot — 2.11pt cells
    /// with 1.32pt gaps — and on a display that draws one point as one
    /// pixel the rasteriser rounded each cell differently: compact came
    /// out with a cross through it and the full panel with one row
    /// twice the weight of the others. Same numbers, two different
    /// shapes, neither of them a grid.
    struct Metrics: Equatable {
        /// One pixel of the sprite.
        let cell: CGFloat
        /// Between the two cells of a block.
        let innerGap: CGFloat
        /// Between the blocks. One cell wide in both sizes — this is
        /// what makes the mark read as four 2x2 blocks rather than as
        /// sixteen evenly spaced dots.
        let blockGap: CGFloat

        var span: CGFloat { cell * 4 + innerGap * 2 + blockGap }

        /// Where a row or column starts, from the mark's own corner.
        func offset(_ index: Int) -> CGFloat {
            switch index {
            case 0: return 0
            case 1: return cell + innerGap
            case 2: return cell * 2 + innerGap + blockGap
            default: return cell * 3 + innerGap * 2 + blockGap
            }
        }
    }

    /// One mark at two sizes rather than two marks. The compact slot is
    /// 24 points and the full panel's is 34; both round to whole points
    /// from the same rule, so the structure is identical and only the
    /// scale changes.
    ///
    /// The block gap is a cell wide, trimmed to an even number of
    /// points. That trim is what makes the mark centre exactly: both
    /// slots are an even number of points, so a mark of even width
    /// leaves equal whole-point margins either side. The first version
    /// rounded the margin down instead and left the full panel's grid
    /// half a point off centre, on the theory that half a point is
    /// invisible. It was not.
    static func metrics(slot: CGFloat) -> Metrics {
        let cell = max(2, (slot * 0.125).rounded())
        let blockGap = cell.truncatingRemainder(dividingBy: 2) == 0 ? cell : cell - 1
        return Metrics(cell: cell, innerGap: 1, blockGap: blockGap)
    }

    /// Where the mark sits inside its slot — exactly half of what is
    /// left over, and a whole number of points by construction.
    static func origin(slot: CGFloat) -> CGFloat {
        (slot - metrics(slot: slot).span) / 2
    }

    // MARK: - The wave

    /// Where a cell sits along the wave's travel, at a given moment.
    ///
    /// Light moves on the diagonal, so a cell's place in the queue is
    /// `row + column`: the top-left corner leads, the bottom-right one
    /// trails, and the cells between them light in a band rather than a
    /// row.
    static func phase(row: Int, col: Int, at time: Double) -> Double {
        time / cycle - Double(row + col) / wavelength
    }

    /// How lit a cell is at a given moment, 0…1.
    ///
    /// The wave is a function of the clock rather than a
    /// `.repeatForever` animation started in `onAppear`.
    /// `SessionStatusIndicator` carries a note that the latter proved
    /// unreliable for rows that have just appeared — which is every row
    /// in a panel the user opened a moment ago — and it is driven by a
    /// `TimelineView` for exactly this reason.
    ///
    /// A raised cosine has no corners anywhere in its period, which is
    /// the whole point: the earlier drafts were rejected for looking
    /// stepped, and a stepped look comes from the easing, not from the
    /// shape being animated.
    static func brightness(row: Int, col: Int, at time: Double) -> Double {
        (1 - cos(phase(row: row, col: col, at: time) * 2 * .pi)) / 2
    }

    /// The moment the wave is frozen at when it cannot move — under
    /// reduced motion, or in a screenshot.
    ///
    /// Chosen so the crest sits across the middle of the grid: the mark
    /// then still reads as light crossing it diagonally. Resting every
    /// cell at the same brightness instead, which is what this did at
    /// first, leaves a working session drawing the identical uniform
    /// block that attention draws — the two states separated by nothing
    /// but hue, which is exactly what the mark exists to avoid.
    static let stillFrame: Double = cycle * 0.875

    static func opacity(row: Int, col: Int, at time: Double, state: State) -> Double {
        let resting = restingOpacity(state)
        guard animates(state) else { return resting }
        return resting + (1 - resting) * brightness(row: row, col: col, at: time)
    }

    var body: some View {
        let colour = Self.color(for: state)
        let moving = Self.animates(state) && !reduceMotion

        Group {
            if moving {
                TimelineView(.animation(minimumInterval: Self.frameInterval)) { context in
                    grid(colour: colour,
                         time: context.date.timeIntervalSinceReferenceDate)
                }
            } else {
                // Still, and legible: the state survives the motion
                // being gone — under reduced motion, in a screenshot,
                // or for anyone who cannot tell the colours apart.
                grid(colour: colour, time: nil)
            }
        }
        .accessibilityHidden(true)
    }

    private func grid(colour: Color, time: Double?) -> some View {
        let metrics = Self.metrics(slot: slot)
        let origin = Self.origin(slot: slot)
        let at = time ?? Self.stillFrame

        // Drawn rather than laid out: a stack rounds each cell's frame
        // on its own and the grid comes apart. Here every rectangle is
        // placed on a whole point by construction.
        return Canvas { context, _ in
            for row in 0..<Self.columns {
                for col in 0..<Self.columns {
                    let rect = CGRect(x: origin + metrics.offset(col),
                                      y: origin + metrics.offset(row),
                                      width: metrics.cell,
                                      height: metrics.cell)
                    context.fill(
                        Path(rect),
                        with: .color(colour.opacity(
                            Self.opacity(row: row, col: col, at: at, state: state)))
                    )
                }
            }
        }
        .frame(width: slot, height: slot)
    }

}
