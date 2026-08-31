import SwiftUI

/// One session, one line, thirty points tall.
///
/// The full panel's row is 44 and spends its second line on a reply
/// preview. Compact keeps only what answers "should I look at this
/// session": which project, which worktree, how many agents, how long.
/// Everything else is a reason to open the full panel, which is one
/// click away.
struct CompactSessionRow: View {

    /// What the row draws. Split out from the view so the decisions can
    /// be tested without rendering anything.
    struct Content: Equatable {
        let name: String
        let worktree: String?
        let agentCount: Int?
        /// What the session is doing, in a word or two. Nil for a
        /// quiet session, whose whole story fits in `trailing`.
        let meta: String?
        let trailing: String
        let state: PixelStatusIndicator.State
    }

    /// What the row's left-hand square holds. The full panel gives an
    /// idle session a numbered squircle and an active one the sprite;
    /// compact keeps that language. A row of bare dots reads as a list
    /// from any application — the numbered slot is what makes it this
    /// one.
    enum Slot: Equatable {
        case number(Int)
        case indicator
    }

    static let height: CGFloat = 30

    let session: Session
    /// Position in the list, for the slot number.
    var index: Int = 0
    let onOpen: () -> Void

    @SwiftUI.State private var isHovered = false

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
    ///
    /// Nothing for a quiet one. "Waiting for you" repeated down every
    /// idle row differentiates nothing, and the time already says it
    /// once it is given a verb.
    static func meta(for session: Session, state: PixelStatusIndicator.State) -> String? {
        switch state {
        case .needsAttention:
            return "needs you"
        case .working:
            // The tool it is running says more than the word "working"
            // ever could, and it is already on screen in the full panel.
            return session.activeTool?.toolName ?? "working"
        case .idle:
            return nil
        }
    }

    /// The trailing figure, with the verb the bare number was missing:
    /// "42s" is forty-two seconds of what.
    static func trailing(for session: Session, state: PixelStatusIndicator.State) -> String {
        let elapsed = duration(Int(Date().timeIntervalSince(session.statusChangedAt)))
        return state == .idle ? "waiting \(elapsed)" : elapsed
    }

    /// Clicking a row brings its terminal forward — an affordance the
    /// row never advertised.
    static let hoverLabel = "Open"

    /// Quiet rows recede. A session that starts working then stands out
    /// on contrast alone, with nothing needing to flash.
    static func namesAreProminent(in state: PixelStatusIndicator.State) -> Bool {
        state != .idle
    }

    /// Coarser the longer it runs: seconds stop mattering after an hour,
    /// minutes after a day. The row has no space to spend on precision
    /// nobody reads.
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

    var body: some View {
        let content = Self.content(for: session)
        let accent = PixelStatusIndicator.color(for: content.state)
        let isActive = content.state != .idle

        HStack(spacing: Spacing.xs) {
            // A hairline of the state's colour down the leading edge —
            // the same device the subagent list uses, so an active row
            // is legible from the corner of the eye without a second
            // badge competing with the slot.
            RoundedRectangle(cornerRadius: 1)
                .fill(isActive ? accent.opacity(0.75) : .clear)
                .frame(width: 2, height: 16)

            slotView(state: content.state)

            Text(content.name)
                .font(.system(size: 12.5,
                              weight: Self.namesAreProminent(in: content.state) ? .semibold : .medium))
                .foregroundStyle(Self.namesAreProminent(in: content.state)
                                 ? TextColor.primary : TextColor.secondary)
                .lineLimit(1)

            if let worktree = content.worktree {
                WorktreeBadge(name: worktree)
            }

            if let agents = content.agentCount {
                AgentCount(count: agents)
            }

            if let meta = content.meta {
                Text(meta)
                    .font(.system(size: 10.5))
                    .foregroundStyle(TextColor.tertiary)
                    .lineLimit(1)
                    .layoutPriority(-1)
            }

            Spacer(minLength: Spacing.xxs)

            if isHovered {
                HStack(spacing: 3) {
                    Text(Self.hoverLabel)
                    Image(systemName: "arrow.up.forward")
                        .font(.system(size: 8, weight: .semibold))
                }
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(TextColor.secondary)
            } else {
                Text(content.trailing)
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(TextColor.tertiary)
                    .monospacedDigit()
            }
        }
        .padding(.leading, Spacing.xs)
        .padding(.trailing, Spacing.sm)
        .frame(height: Self.height)
        .background(
            // Rounded highlights instead of divider lines: rules between
            // rows read as a table, and a table is the most generic
            // shape a list can take.
            RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
                .fill(isActive ? accent.opacity(0.07) : Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
                        .fill(Color.white.opacity(isHovered ? 0.05 : 0))
                )
                .padding(.horizontal, 4)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(perform: onOpen)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.accessibilityLabel(for: content))
        .accessibilityAddTraits(.isButton)
    }

    /// A squircle in miniature — the same shape the full panel's slot
    /// uses, at 20 points instead of 34, tinted by the state it is in.
    @ViewBuilder
    private func slotView(state: PixelStatusIndicator.State) -> some View {
        let accent = PixelStatusIndicator.color(for: state)
        let isActive = state != .idle

        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isActive ? accent.opacity(0.16) : Color(white: 0.11))
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(isActive ? accent.opacity(0.5) : Color(white: 0.18),
                              lineWidth: isActive ? 1 : 0.5)

            switch Self.slot(for: session, index: index) {
            case .number(let n):
                Text(String(format: "%02d", n))
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(TextColor.tertiary)
            case .indicator:
                PixelStatusIndicator(state: state, size: 3.5, spacing: 1.5)
            }
        }
        .frame(width: 20, height: 20)
    }

    /// Spoken rather than shown: the indicator is decorative, so the
    /// state has to be in words here or a screen reader hears a name
    /// and a number.
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

/// The worktree a session moved into. Its own mark rather than more
/// text, because the name beside it is already the project.
private struct WorktreeBadge: View {
    let name: String

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 8))
            Text(name)
                .font(.system(size: 9, design: .monospaced))
                .lineLimit(1)
        }
        .foregroundStyle(SessionTheme.readyColor.opacity(0.85))
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .background(
            RoundedRectangle(cornerRadius: 3)
                .fill(SessionTheme.readyColor.opacity(0.14))
        )
    }
}

/// How many agents are working, with a mark from the mascot's family so
/// the number is unmistakably agents and not four of anything else.
private struct AgentCount: View {
    let count: Int

    var body: some View {
        HStack(spacing: 3) {
            AgentMark()
            Text("\(count)")
                .font(.system(size: 10, design: .monospaced))
                .monospacedDigit()
        }
        .foregroundStyle(TextColor.tertiary)
    }
}

/// A head with two eyes at eight points across — the smallest the
/// mascot can be and still be recognisable as one.
private struct AgentMark: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(SessionTheme.processingColor.opacity(0.75))
                .frame(width: 8, height: 7)
            HStack(spacing: 2) {
                eye
                eye
            }
        }
    }

    private var eye: some View {
        RoundedRectangle(cornerRadius: 0.5)
            .fill(Color(white: 0.1))
            .frame(width: 1.5, height: 1.5)
    }
}
