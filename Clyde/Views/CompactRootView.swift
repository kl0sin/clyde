import SwiftUI

/// Compact mode: the session rows, a strip to drag the window by, and a
/// line of counts. Everything the full panel has for reading — the
/// header, the Activity trail, the summary bar — is what this leaves
/// out, because none of it earns its space in a window kept open beside
/// the work it reports on.
struct CompactRootView: View {

    @ObservedObject var appViewModel: AppViewModel
    @ObservedObject var sessionViewModel: SessionListViewModel

    static let gripHeight: CGFloat = 14
    static let footerHeight: CGFloat = 26
    static let defaultRowCap = 4

    /// The height this view wants, which is the only thing in the app
    /// allowed to change the panel's size — and it does so by being
    /// told to, never by pushing from inside. See `ExpandedPanel`.
    static func height(rows: Int, expanded request: PermissionRequest? = nil) -> CGFloat {
        gripHeight
            + CGFloat(max(0, rows)) * CompactSessionRow.height
            + (request.map(requestHeight) ?? 0)
            + footerHeight
    }

    /// How much room an open question needs, worked out before it is
    /// drawn. The window's height is computed and applied deliberately
    /// — content is never allowed to push it — so this has to be an
    /// answer rather than a measurement after the fact.
    static func requestHeight(for request: PermissionRequest) -> CGFloat {
        let lines = min(PermissionRequestRow.wrappedLineCount(of: request.summary),
                        PermissionRequestRow.collapsedLineLimit)
        // tool name + buttons + padding, plus the command itself
        return 62 + CGFloat(lines) * 14
    }

    /// The one question that is open, if any: the newest, and only when
    /// its session is on screen to carry it.
    ///
    /// One at a time is deliberate. Two expanded questions in a panel
    /// this size is most of the panel, and the second is answerable a
    /// few seconds later anyway.
    static func expandedRequest(from requests: [PermissionRequest],
                                visiblePIDs: Set<pid_t>? = nil) -> PermissionRequest? {
        requests
            .filter { request in
                guard request.isLive else { return false }
                guard let visiblePIDs else { return true }
                return visiblePIDs.contains(request.pid)
            }
            .max { $0.expiresAt < $1.expiresAt }
    }

    /// Which sessions make the cut, in the order they appear.
    ///
    /// Needs-you first: it is the only state that requires something of
    /// the user. Working next, because it is worth glancing at. Then
    /// idle, most recent first — and those are the ones the cap drops,
    /// never a session that is working or waiting on an answer.
    static func visible(sessions: [Session], cap: Int) -> [Session] {
        let live = sessions.filter { !$0.isGhost }
        let ranked = live.sorted { lhs, rhs in
            let l = rank(lhs), r = rank(rhs)
            if l != r { return l < r }
            return lhs.statusChangedAt > rhs.statusChangedAt
        }
        return Array(ranked.prefix(max(0, cap)))
    }

    private static func rank(_ session: Session) -> Int {
        if session.needsAttention { return 0 }
        return session.isWorking ? 1 : 2
    }

    private var rows: [Session] {
        Self.visible(sessions: sessionViewModel.sessions, cap: appViewModel.compactRowCap)
    }

    private var expanded: PermissionRequest? {
        Self.expandedRequest(from: appViewModel.permissionRequests,
                             visiblePIDs: Set(rows.map(\.pid)))
    }

    var body: some View {
        VStack(spacing: 0) {
            // The header used to be the drag handle; without it the
            // window needs somewhere to be picked up.
            DragStrip()
                .frame(height: Self.gripHeight)

            VStack(spacing: 0) {
                ForEach(rows) { session in
                    CompactSessionRow(session: session) {
                        appViewModel.focusSession(session)
                    }

                    // The question opens under the session that asked
                    // it. Deferring to the terminal instead would mean
                    // the feature the user switched on does not work in
                    // the mode they keep open.
                    if let request = expanded, request.pid == session.pid {
                        PermissionRequestRow(request: request) { decision in
                            appViewModel.answerPermissionRequest(request, with: decision)
                        }
                        .padding(.horizontal, Spacing.xs)
                        .padding(.bottom, Spacing.xxs)
                    }

                    Divider().opacity(0.35)
                }
            }

            if rows.isEmpty {
                Text("No sessions")
                    .font(.system(size: 11))
                    .foregroundStyle(TextColor.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Spacing.sm)
                    .frame(height: CompactSessionRow.height)
            }

            footer
        }
        // The same surface the full panel uses, so switching modes
        // changes the contents and not the material.
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.ultraThinMaterial)
                    .environment(\.colorScheme, .dark)
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(nsColor: NSColor(red: 0.08, green: 0.08, blue: 0.1, alpha: 0.85)))
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5)
        )
    }

    private var footer: some View {
        HStack(spacing: Spacing.xs) {
            Text(summary)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(TextColor.tertiary)

            Spacer(minLength: Spacing.xs)

            Button {
                appViewModel.panelMode = .full
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                    Text("Expand")
                        .font(.system(size: 10))
                }
                .foregroundStyle(TextColor.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: Radius.small)
                        .fill(Color.white.opacity(0.07))
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Expand to the full panel")
        }
        .padding(.horizontal, Spacing.sm)
        .frame(height: Self.footerHeight)
    }

    /// The counts the summary bar carries in the full panel, in one
    /// line — including the sessions the cap left out, so the number
    /// never contradicts what is on screen.
    private var summary: String {
        let live = sessionViewModel.sessions.filter { !$0.isGhost }
        var parts: [String] = []
        let attention = live.filter(\.needsAttention).count
        let working = live.filter { $0.isWorking && !$0.needsAttention }.count
        let idle = live.count - attention - working
        if attention > 0 { parts.append("\(attention) needs you") }
        if working > 0 { parts.append("\(working) working") }
        if idle > 0 { parts.append("\(idle) ready") }
        return parts.isEmpty ? "No sessions" : parts.joined(separator: " · ")
    }
}

/// A borderless window has nothing to grab, and compact has no header
/// to drag by.
private struct DragStrip: View {
    var body: some View {
        ZStack {
            Color.clear
            Capsule()
                .fill(Color.white.opacity(0.14))
                .frame(width: 26, height: 3)
        }
        .contentShape(Rectangle())
        .accessibilityHidden(true)
    }
}
