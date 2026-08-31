import SwiftUI

/// Four pixels standing in for a session's state, in the mascot's own
/// visual world.
///
/// It replaces the coloured dot, which said which state a session was
/// in and nothing about whether anything was happening. Across a
/// column of rows — which is all compact mode is — motion is what
/// separates working from waiting.
///
/// One object in three states rather than three drawings: the same
/// square travelling, at rest, or filled. That is what keeps a column
/// scannable, and it means the state survives the colour being taken
/// away.
struct PixelStatusIndicator: View {

    enum State: Equatable {
        case working
        case idle
        case needsAttention
    }

    let state: State
    var size: CGFloat = 4
    var spacing: CGFloat = 1.5

    /// The wave's full period. Exactly four delay steps, so the fourth
    /// pixel hands off to the first: any longer and the wave rests
    /// between laps, which reads as a stutter rather than a cycle.
    static let cycle: Double = 1.6
    static let delayStep: Double = cycle / 4

    /// Attention pulses this many times when it arrives, then holds.
    static let arrivalPulses = 3

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

    /// What a pixel looks like when nothing is animating it. Filled for
    /// attention, dim for idle, dimmer still for a working pixel
    /// waiting its turn — so the three read apart in a screenshot, or
    /// for someone who cannot tell the colours apart.
    static func restingOpacity(_ state: State) -> Double {
        switch state {
        case .needsAttention: return 1.0
        case .idle: return 0.7
        // A waiting pixel at 0.28 vanished inside a 24-point slot: the
        // wave read as one cell lighting in an empty square rather than
        // as light travelling a grid that is always there.
        case .working: return 0.45
        }
    }

    /// Clockwise: top-left, top-right, bottom-right, bottom-left.
    static func delay(forPixel index: Int) -> Double {
        Double(index) * delayStep
    }

    /// Grid order for the clockwise sequence above — the third pixel
    /// drawn is the bottom-right one, which is the fourth to light.
    private static let clockwise = [0, 1, 3, 2]

    /// How lit a pixel is at a given moment, 0…1.
    ///
    /// The wave is a function of the clock rather than a
    /// `.repeatForever` animation started in `onAppear`.
    /// `SessionStatusIndicator` carries a note that the latter proved
    /// unreliable for rows that have just appeared — which is every row
    /// in a panel the user opened a moment ago — and it is driven by a
    /// `TimelineView` for exactly this reason.
    ///
    /// A raised cosine gives one smooth peak per cycle with no corners,
    /// so neighbouring pixels overlap rather than hand over abruptly.
    static func brightness(pixel index: Int, at time: Double) -> Double {
        let step = clockwise.firstIndex(of: index) ?? index
        let phase = ((time - delay(forPixel: step)) / cycle).truncatingRemainder(dividingBy: 1)
        let wrapped = phase < 0 ? phase + 1 : phase
        return (cos(wrapped * 2 * .pi) + 1) / 2
    }

    static func opacity(pixel index: Int, at time: Double, state: State) -> Double {
        let resting = restingOpacity(state)
        guard animates(state) else { return resting }
        return resting + (1 - resting) * brightness(pixel: index, at: time)
    }

    static func scale(pixel index: Int, at time: Double, state: State) -> Double {
        guard animates(state) else { return state == .needsAttention ? 1 : 0.9 }
        return 0.88 + 0.12 * brightness(pixel: index, at: time)
    }

    var body: some View {
        let colour = Self.color(for: state)
        let moving = Self.animates(state) && !reduceMotion

        Group {
            if moving {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                    grid(colour: colour,
                         time: context.date.timeIntervalSinceReferenceDate)
                }
            } else {
                // Still, and legible: the shape carries the state when
                // the motion is gone — under reduced motion, in a
                // screenshot, or for anyone who cannot tell the colours
                // apart.
                grid(colour: colour, time: nil)
            }
        }
        .accessibilityHidden(true)
    }

    private func grid(colour: Color, time: Double?) -> some View {
        VStack(spacing: spacing) {
            ForEach(0..<2, id: \.self) { row in
                HStack(spacing: spacing) {
                    ForEach(0..<2, id: \.self) { column in
                        let index = row * 2 + column
                        RoundedRectangle(cornerRadius: 1, style: .continuous)
                            .fill(colour)
                            .frame(width: size, height: size)
                            .opacity(time.map { Self.opacity(pixel: index, at: $0, state: state) }
                                     ?? Self.restingOpacity(state))
                            .scaleEffect(time.map { Self.scale(pixel: index, at: $0, state: state) }
                                         ?? (state == .needsAttention ? 1 : 0.9))
                    }
                }
            }
        }
    }
}
