import SwiftUI

/// The question itself, shown under the session that asked it.
///
/// It appears for a few seconds — as long as the hook is waiting — and
/// then leaves, because after that the terminal is asking and an answer
/// here would go nowhere.
struct PermissionRequestRow: View {
    let request: PermissionRequest
    let onDecide: (PermissionDecision) -> Void

    @State private var isExpanded = false

    /// How much of a long request is shown before it is folded. The
    /// panel is 420 points tall and holds a session list, an Activity
    /// bar and a summary line; a forty-line script would take all of it.
    static let collapsedLineLimit = 5
    /// Roughly the characters that fit on one line of the row at 11pt
    /// monospaced. Used to notice a single enormous line, which wraps
    /// into just as many rows as a long script.
    private static let charactersPerLine = 46

    /// A question belongs under the session that asked it, and only
    /// while it is still answerable. Two sessions can be waiting at
    /// once, and answering the wrong row runs the wrong command.
    static func shows(request: PermissionRequest, inRowFor pid: pid_t) -> Bool {
        request.pid == pid && request.isLive
    }

    /// Never abbreviated. The row scrolls instead — see
    /// `PermissionRequest.summary`.
    static func displayedSummary(for request: PermissionRequest) -> String {
        request.summary
    }

    /// True when the request is longer than the row shows at rest.
    /// Counts wrapped lines, not just newlines: one 600-character
    /// command fills the panel exactly as thoroughly as a long script.
    static func needsCap(for summary: String) -> Bool {
        wrappedLineCount(of: summary) > collapsedLineLimit
    }

    /// Says how much is folded away. A cap that hides an unknown amount
    /// is the truncation this row exists to avoid — the number is the
    /// difference between "shortened" and "hiding something".
    static func expandLabel(for summary: String) -> String {
        "Show all \(wrappedLineCount(of: summary)) lines"
    }

    /// Internal rather than private: compact mode has to know how tall
    /// a request will be *before* it draws it, because the window's
    /// height is computed and applied deliberately — the content is
    /// never allowed to push it.
    static func wrappedLineCount(of summary: String) -> Int {
        summary.components(separatedBy: "\n").reduce(0) { total, line in
            total + max(1, Int(ceil(Double(line.count) / Double(charactersPerLine))))
        }
    }

    static func label(for decision: PermissionDecision) -> String {
        switch decision {
        case .allow: return "Allow"
        case .deny: return "Deny"
        }
    }

    /// What a screen reader hears. "Allow" alone says nothing about
    /// what is being allowed.
    static func accessibilityLabel(for request: PermissionRequest) -> String {
        "Permission request from \(request.toolName): \(request.summary)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            HStack(spacing: Spacing.xxs) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(TextColor.secondary)
                Text(request.toolName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(TextColor.primary)
            }

            // Wraps rather than scrolls. Horizontal scrolling was the
            // first attempt and it read as a truncated command — the
            // tail sat past the panel edge with nothing to say it was
            // there, which is the exact habit this row must not
            // encourage. The session list already scrolls vertically,
            // so a tall question costs nothing.
            let summary = Self.displayedSummary(for: request)
            let capped = Self.needsCap(for: summary) && !isExpanded

            Text(summary)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(TextColor.secondary)
                .textSelection(.enabled)
                .lineLimit(capped ? Self.collapsedLineLimit : nil)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if Self.needsCap(for: summary) {
                Button(isExpanded ? "Show less" : Self.expandLabel(for: summary)) {
                    isExpanded.toggle()
                }
                .buttonStyle(.plain)
                .font(.system(size: 10))
                .foregroundStyle(TextColor.tertiary)
                .accessibilityHint("The request is longer than the space it is given")
            }

            HStack(spacing: Spacing.xxs) {
                button(.allow)
                button(.deny)
            }
            .padding(.top, 2)
        }
        .padding(Spacing.xs)
        .background(
            RoundedRectangle(cornerRadius: Radius.medium)
                .fill(Color.black.opacity(0.25))
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Self.accessibilityLabel(for: request))
    }

    private func button(_ decision: PermissionDecision) -> some View {
        Button(Self.label(for: decision)) { onDecide(decision) }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, Spacing.xs)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: Radius.small)
                    .fill(Color.white.opacity(decision == .allow ? 0.18 : 0.08))
            )
            .accessibilityLabel("\(Self.label(for: decision)) \(request.toolName)")
            .accessibilityHint(request.summary)
    }
}
