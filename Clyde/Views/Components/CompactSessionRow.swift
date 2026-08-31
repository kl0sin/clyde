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
        let trailing: String
        let state: PixelStatusIndicator.State
    }

    static let height: CGFloat = 30

    let session: Session
    let onOpen: () -> Void

    static func content(for session: Session) -> Content {
        let workingAgents = session.activeSubagents.filter { !$0.isIdle }.count
        return Content(
            name: session.displayName,
            worktree: session.worktreeName.isEmpty ? nil : session.worktreeName,
            agentCount: workingAgents > 0 ? workingAgents : nil,
            trailing: duration(Int(Date().timeIntervalSince(session.statusChangedAt))),
            state: PixelStatusIndicator.state(for: session)
        )
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

        HStack(spacing: Spacing.xs) {
            PixelStatusIndicator(state: content.state)
                .frame(width: 14)

            Text(content.name)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(TextColor.primary)
                .lineLimit(1)

            if let worktree = content.worktree {
                WorktreeBadge(name: worktree)
            }

            if let agents = content.agentCount {
                AgentCount(count: agents)
            }

            Spacer(minLength: Spacing.xxs)

            Text(content.trailing)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(TextColor.tertiary)
                .monospacedDigit()
        }
        .padding(.horizontal, Spacing.sm)
        .frame(height: Self.height)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.accessibilityLabel(for: content))
        .accessibilityAddTraits(.isButton)
    }

    /// Spoken rather than shown: the indicator is decorative, so the
    /// state has to be in words here or a screen reader hears a name
    /// and a number.
    static func accessibilityLabel(for content: Content) -> String {
        var parts = [content.name]
        switch content.state {
        case .working: parts.append(SessionTheme.processingLabel)
        case .idle: parts.append(SessionTheme.readyLabel)
        case .needsAttention: parts.append(SessionTheme.attentionLabel)
        }
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
