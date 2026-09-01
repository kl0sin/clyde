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
    /// `#1` / `#2` when another session on screen shows the same name.
    var disambiguator: String? = nil
    /// False for the last row, which has nothing below it to be
    /// separated from.
    var showsSeparator: Bool = true
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
    /// Rows, not cards: they sit against each other and a hairline
    /// tells them apart, the same way the full panel's do. Cards with
    /// gaps and rounded borders said the same thing in a second visual
    /// language, and the two windows stopped looking like one app.
    static let gap: CGFloat = 0

    /// The slot, and the room around it.
    ///
    /// The leading inset equals the slot's own margin above and below,
    /// so the mark sits the same distance from three of the row's four
    /// edges. It was 11 against 8, which read as the mark being pushed
    /// to the right.
    static let slotSize: CGFloat = 26

    /// What centring the slot in the row leaves above and below it.
    /// Not set anywhere — stated here so the horizontal inset can be
    /// compared against it.
    static let verticalInset: CGFloat = (cardHeight - slotSize) / 2

    /// The window's margin, not the row's.
    ///
    /// Wider than the vertical inset on purpose. A row's leading edge
    /// is also the left edge of everything in the window — the footer
    /// sits at this same 12 — and a row inset less than its neighbours
    /// leaves the window with a ragged left edge, which is worse than
    /// the mark having slightly more air on its sides than above it.
    /// Vertical space, by contrast, belongs to the row alone.
    static let leadingInset: CGFloat = Spacing.sm

    /// Between the slot and the text: the same as the leading inset, so
    /// the mark's left and right are equal.
    static let slotGap: CGFloat = leadingInset
    /// Past the slot column, so the line separates the text.
    static let separatorInset: CGFloat = leadingInset + slotSize + slotGap

    static func height(for session: Session) -> CGFloat { cardHeight }

    /// Kept for the empty-state placeholder's height.
    static var quietHeight: CGFloat { cardHeight }

    static func slot(for session: Session, index: Int) -> Slot {
        PixelStatusIndicator.state(for: session) == .idle ? .number(index + 1) : .indicator
    }

    static func content(for session: Session, disambiguator: String? = nil) -> Content {
        let workingAgents = session.activeSubagents.filter { !$0.isIdle }.count
        let state = PixelStatusIndicator.state(for: session)
        return Content(
            name: disambiguator.map { "\(session.displayName) \($0)" } ?? session.displayName,
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
        let content = Self.content(for: session, disambiguator: disambiguator)
        let accent = PixelStatusIndicator.color(for: content.state)
        let isActive = content.state != .idle

        // 7 (card inset) + 11 (card padding) + 24 (slot) + 16 = 58,
        // which is where the full panel's session names start:
        // 12 + 34 + 12. Switching modes then moves the window's
        // contents, not the column they are read down.
        HStack(spacing: Self.slotGap) {
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
        .padding(.horizontal, Self.leadingInset)
        .frame(height: Self.cardHeight)
        .background(SessionSurface(state: content.state, accent: accent))
        // The wash fades in when a session starts working instead of
        // being there the next frame — the difference between a light
        // coming on and a light having been on.
        .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: content.state)
        .background(isHovered ? Color(white: 0.14) : .clear)
        .animation(.easeOut(duration: 0.14), value: isHovered)
        .overlay(alignment: .bottom) {
            // The same hairline the full panel puts between its rows,
            // set in by the width of the slot column so it separates
            // the text rather than cutting the row in two.
            if showsSeparator {
                Rectangle()
                    .fill(SessionSurface.separatorColour)
                    .frame(height: SessionSurface.separatorHeight)
                    .padding(.leading, Self.separatorInset)
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(perform: onOpen)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.accessibilityLabel(for: content))
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Surface

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
            SteppedSquare(step: Self.slotSize * SteppedSquare.stepRatio)
                .fill(isActive
                        ? accent.opacity(PixelStatusIndicator.slotFillOpacity)
                        : PixelStatusIndicator.quietSlotFill)
            SteppedSquare(step: Self.slotSize * SteppedSquare.stepRatio)
                .stroke(isActive
                            ? accent.opacity(PixelStatusIndicator.slotStrokeOpacity)
                            : PixelStatusIndicator.quietSlotStroke,
                        lineWidth: isActive
                            ? PixelStatusIndicator.slotStrokeWidth(slot: Self.slotSize)
                            : 1)

            switch Self.slot(for: session, index: index) {
            case .number(let n):
                Text(String(format: "%02d", n))
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(TextColor.tertiary)
            case .indicator:
                // The same mark as the full panel's row, sized from
                // this slot rather than that one.
                PixelStatusIndicator(state: state, slot: Self.slotSize)
            }
        }
        .frame(width: Self.slotSize, height: Self.slotSize)
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
