import SwiftUI

/// One session, as a card.
///
/// The card language is the full panel's own, which is what keeps
/// compact recognisably this app rather than a list that could belong
/// to any of them. What it adds is what a window kept open all day can
/// afford: the state written into the surface, so a glance from across
/// the desk lands before a word is read.
///
/// Quiet cards carry every device the active ones do, switched off —
/// same shape, same slot, same corners, no wash, no texture, no sweep.
/// That is what makes a session starting work visible out of the corner
/// of the eye.
struct CompactSessionRow: View {

    /// What the row draws. Split out from the view so the decisions can
    /// be tested without rendering anything.
    struct Content: Equatable {
        let name: String
        let worktree: String?
        let agentCount: Int?
        /// What the session is doing, in a word or two. Nil for a quiet
        /// session, whose whole story fits in `trailing`.
        let meta: String?
        let trailing: String
        let state: PixelStatusIndicator.State
    }

    /// What the row's slot holds. The full panel gives an idle session a
    /// numbered squircle and an active one the sprite; compact keeps
    /// that language.
    enum Slot: Equatable {
        case number(Int)
        case indicator
    }

    let session: Session
    /// Position in the list, for the slot number.
    var index: Int = 0
    let onOpen: () -> Void

    @SwiftUI.State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// One height for every card. A quiet card carries the same devices
    /// as an active one with all of them switched off — same shape,
    /// same slot, same two lines — and that sameness is what makes a
    /// session starting work visible from the corner of the eye.
    ///
    /// Shortening the quiet ones was tried and took their structure
    /// away: a name and a long string of text with nothing holding them
    /// apart.
    /// Two lines and their padding, and no more. At 44 the card was
    /// comfortable and four sessions came to 61% of the full panel,
    /// which is not a compact mode — it is the same panel with less in
    /// it.
    static let cardHeight: CGFloat = 40
    /// Space between cards, so they read as separate surfaces.
    static let gap: CGFloat = 5

    static func height(for session: Session) -> CGFloat { cardHeight }

    /// Kept for the empty-state placeholder's height.
    static var quietHeight: CGFloat { cardHeight }

    static func slot(for session: Session, index: Int) -> Slot {
        PixelStatusIndicator.state(for: session) == .idle ? .number(index + 1) : .indicator
    }

    static func content(for session: Session) -> Content {
        let workingAgents = session.activeSubagents.filter { !$0.isIdle }.count
        let state = PixelStatusIndicator.state(for: session)
        return Content(
            name: session.displayName,
            worktree: session.worktreeName.isEmpty ? nil : session.worktreeName,
            agentCount: workingAgents > 0 ? workingAgents : nil,
            meta: meta(for: session, state: state),
            trailing: trailing(for: session, state: state),
            state: state
        )
    }

    /// The row's middle: what this session is doing.
    static func meta(for session: Session, state: PixelStatusIndicator.State) -> String? {
        switch state {
        case .needsAttention:
            return "needs you"
        case .working:
            return session.activeTool?.toolName ?? "working"
        case .idle:
            // The label carries the state; the figure beside it carries
            // the duration. Putting both in one string left the card
            // with a name and a sentence and no structure.
            return "waiting"
        }
    }

    /// The trailing figure, with the verb the bare number was missing:
    /// "42s" is forty-two seconds of what.
    static func trailing(for session: Session, state: PixelStatusIndicator.State) -> String {
        duration(Int(Date().timeIntervalSince(session.statusChangedAt)))
    }

    /// Clicking a row brings its terminal forward — an affordance the
    /// row never advertised.
    static let hoverLabel = "Open"

    /// Coarser the longer it runs: seconds stop mattering after an hour,
    /// minutes after a day.
    static func duration(_ seconds: Int) -> String {
        let seconds = max(0, seconds)
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 {
            let m = seconds / 60, s = seconds % 60
            return s == 0 ? "\(m)m" : "\(m)m \(s)s"
        }
        if seconds < 86_400 {
            let h = seconds / 3600, m = (seconds % 3600) / 60
            return m == 0 ? "\(h)h" : "\(h)h \(m)m"
        }
        let d = seconds / 86_400, h = (seconds % 86_400) / 3600
        return h == 0 ? "\(d)d" : "\(d)d \(h)h"
    }

    static func namesAreProminent(in state: PixelStatusIndicator.State) -> Bool {
        state != .idle
    }

    var body: some View {
        let content = Self.content(for: session)
        let accent = PixelStatusIndicator.color(for: content.state)
        let isActive = content.state != .idle

        // 7 (card inset) + 11 (card padding) + 24 (slot) + 16 = 58,
        // which is where the full panel's session names start:
        // 12 + 34 + 12. Switching modes then moves the window's
        // contents, not the column they are read down.
        HStack(spacing: 16) {
            slotView(state: content.state)

            VStack(alignment: .leading, spacing: 3) {
                Text(content.name)
                    // 13 is the full panel's session name. Weight
                    // carries the state; the size is shared, so a name
                    // does not change size when the mode does.
                    .font(.system(size: 13,
                                  weight: Self.namesAreProminent(in: content.state) ? .semibold : .medium))
                    .foregroundStyle(Self.namesAreProminent(in: content.state)
                                     ? TextColor.primary : TextColor.secondary)
                    .lineLimit(1)

                if let meta = content.meta {
                    HStack(spacing: 5) {
                        // Only an active state colours its label. A green
                        // WAITING on every quiet card shouts the least
                        // interesting thing on screen.
                        MicroLabel(text: meta,
                                   color: isActive ? accent : TextColor.tertiary)
                        if let worktree = content.worktree { Chip(text: worktree, tinted: true) }
                        if let agents = content.agentCount { Chip(text: "◉ \(agents)", tinted: false) }
                    }
                }
            }

            Spacer(minLength: 6)

            trailingView(content: content, isActive: isActive)
        }
        .padding(.horizontal, 11)
        .frame(height: Self.cardHeight)
        .background(cardBackground(state: content.state, accent: accent))
        .overlay(alignment: .top) {
            // One hairline gradient is the whole difference between a
            // rectangle and something raised.
            LinearGradient(colors: [.clear, .white.opacity(0.14), .clear],
                           startPoint: .leading, endPoint: .trailing)
                .frame(height: 1)
        }
        .overlay(alignment: .bottom) {
            // The sweep belongs to work, not to waiting. Held still for
            // an attention card it stopped being light crossing the
            // surface and became a coloured bottom border — and the
            // whole point of that state is that it does not move.
            if content.state == .working {
                SweepLine(color: accent, animates: !reduceMotion)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(borderColour(state: content.state, accent: accent), lineWidth: 1)
        )
        .offset(y: isHovered ? -1 : 0)
        .animation(.easeOut(duration: 0.14), value: isHovered)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(perform: onOpen)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.accessibilityLabel(for: content))
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Surface

    /// The state is the surface: a wash falling off from the leading
    /// edge rather than a coloured outline, so a busy session reads as
    /// warm instead of ringed. A rail down the left edge said the same
    /// thing a third time, in the way every generated card on the web
    /// currently says it, and was dropped.
    @ViewBuilder
    private func cardBackground(state: PixelStatusIndicator.State, accent: Color) -> some View {
        ZStack {
            Color.white.opacity(0.042)

            if state != .idle {
                RadialGradient(
                    colors: [accent.opacity(state == .needsAttention ? 0.22 : 0.20), .clear],
                    center: .leading,
                    startRadius: 0,
                    endRadius: 260
                )
                // The mascot is pixel art; this is that world at the
                // scale of a surface. Fades out across the card so it
                // stays at the threshold of visible.
                DitherField()
                    .mask(
                        LinearGradient(colors: [.black.opacity(0.85), .clear],
                                       startPoint: .leading, endPoint: .trailing)
                    )
            }
        }
    }

    private func borderColour(state: PixelStatusIndicator.State, accent: Color) -> Color {
        switch state {
        case .idle: return .white.opacity(isHovered ? 0.12 : 0.05)
        case .working, .needsAttention: return accent.opacity(0.22)
        }
    }

    @ViewBuilder
    private func trailingView(content: Content, isActive: Bool) -> some View {
        if isHovered {
            HStack(spacing: 3) {
                Text(Self.hoverLabel)
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 8, weight: .semibold))
            }
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(TextColor.secondary)
        } else {
            HStack(spacing: 4) {
                if isActive {
                    // A counter ticks in hard steps; it is the one place
                    // a hard step is right.
                    TickPixel(color: PixelStatusIndicator.color(for: content.state),
                              animates: content.state == .working && !reduceMotion)
                }
                Text(content.trailing)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(isActive ? TextColor.secondary : TextColor.tertiary)
                    .monospacedDigit()
            }
        }
    }

    /// The corner of a drawn sprite rather than of a web card.
    @ViewBuilder
    private func slotView(state: PixelStatusIndicator.State) -> some View {
        let accent = PixelStatusIndicator.color(for: state)
        let isActive = state != .idle

        ZStack {
            // The step is a proportion, not a constant: 4 points on a
            // 24-point slot is a deeper bite than 4 on a 34-point one,
            // and the two modes stopped looking like the same mark.
            SteppedSquare(step: 24 * SteppedSquare.stepRatio)
                .fill(isActive ? accent.opacity(0.16) : Color.white.opacity(0.05))
            SteppedSquare(step: 24 * SteppedSquare.stepRatio)
                .stroke(isActive ? accent.opacity(0.40) : Color.white.opacity(0.07), lineWidth: 1)

            switch Self.slot(for: session, index: index) {
            case .number(let n):
                Text(String(format: "%02d", n))
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(TextColor.tertiary)
            case .indicator:
                // Half the slot, near enough: smaller and the grid sat
                // in the middle of an empty square, reading as
                // decoration rather than as light crossing a grid.
                PixelStatusIndicator(state: state, size: 5, spacing: 2)
            }
        }
        .frame(width: 24, height: 24)
    }

    static func accessibilityLabel(for content: Content) -> String {
        var parts = [content.name]
        if let meta = content.meta { parts.append(meta) }
        if let worktree = content.worktree { parts.append("worktree \(worktree)") }
        if let agents = content.agentCount {
            parts.append(agents == 1 ? "1 agent" : "\(agents) agents")
        }
        parts.append(content.trailing)
        return parts.joined(separator: ", ")
    }
}

// MARK: - Pieces

private struct Chip: View {
    let text: String
    let tinted: Bool

    var body: some View {
        Text(text)
            .font(.system(size: 8.5, design: .monospaced))
            .foregroundStyle(tinted ? SessionTheme.readyColor.opacity(0.95) : TextColor.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(tinted ? SessionTheme.readyColor.opacity(0.22) : Color.white.opacity(0.11))
            )
    }
}

/// One-pixel diagonal hatching. Drawn rather than tiled from an asset so
/// it stays exactly one pixel at any scale factor.
private struct DitherField: View {
    var body: some View {
        Canvas { context, size in
            // Wider apart and a touch stronger than the mockup's CSS:
            // one CSS pixel is half a point on this display, so the
            // literal port came out invisible.
            let spacing: CGFloat = 4
            var offset = -size.height
            let colour = GraphicsContext.Shading.color(.white.opacity(0.075))
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
private struct SweepLine: View {
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
private struct TickPixel: View {
    let color: Color
    let animates: Bool

    var body: some View {
        Group {
            if animates {
                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    let on = Int(context.date.timeIntervalSinceReferenceDate * 2) % 2 == 0
                    pixel.opacity(on ? 1 : 0.25)
                }
            } else {
                pixel.opacity(0.8)
            }
        }
    }

    private var pixel: some View {
        RoundedRectangle(cornerRadius: 0.5)
            .fill(color)
            .frame(width: 3, height: 3)
    }
}

/// A square with two-pixel steps at each corner: drawn on a grid, the
/// way the mascot is.
struct SteppedSquare: Shape {
    /// How deep the corner steps are, as a fraction of the square. Held
    /// here so every slot in the app bites the same amount whatever
    /// size it is drawn at.
    static let stepRatio: CGFloat = 0.12

    var step: CGFloat = 3

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + step, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - step, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + step))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - step))
        path.addLine(to: CGPoint(x: rect.maxX - step, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + step, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - step))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + step))
        path.closeSubpath()
        return path
    }
}
