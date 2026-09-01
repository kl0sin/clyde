import SwiftUI

/// Compact mode: the session rows, a strip to drag the window by, and a
/// line of counts. Everything the full panel has for reading — the
/// header, the Activity trail, the summary bar — is what this leaves
/// out, because none of it earns its space in a window kept open beside
/// the work it reports on.
struct CompactRootView: View {

    @ObservedObject var appViewModel: AppViewModel
    @ObservedObject var sessionViewModel: SessionListViewModel

    @SwiftUI.State private var showsAdvisory = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let gripHeight: CGFloat = 14
    /// Taller than it looks: the counts need air under them or they
    /// read as resting on the window's edge.
    static let footerHeight: CGFloat = 34
    static let defaultRowCap = 4

    /// The height this view wants, which is the only thing in the app
    /// allowed to change the panel's size — and it does so by being
    /// told to, never by pushing from inside. See `ExpandedPanel`.
    ///
    /// Sessions are measured rather than counted: a quiet card is one
    /// line and an active one is two, so four quiet sessions and four
    /// busy ones are different windows.
    static func height(for sessions: [Session],
                       expanded request: PermissionRequest? = nil) -> CGFloat {
        let cards = sessions.reduce(CGFloat(0)) { $0 + CompactSessionRow.height(for: $1) }
        let gaps = CGFloat(max(0, sessions.count - 1)) * CompactSessionRow.gap
        let empty: CGFloat = sessions.isEmpty ? CompactSessionRow.quietHeight : 0
        return gripHeight
            + cardPadding * 2
            + separatorHeight
            + cards + gaps + empty
            + (request.map(requestHeight) ?? 0)
            + footerHeight
    }

    /// Cards sit inset from the panel's edge so they read as surfaces
    /// on it rather than as bands across it.
    static let cardPadding: CGFloat = 7
    static let separatorHeight: CGFloat = 0.5

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
    /// The order itself is `SessionOrder`'s, shared with the full
    /// panel. All this adds is the cap: what falls off the bottom is
    /// always an idle session, never one working or waiting on an
    /// answer, because those rank above it.
    static func visible(sessions: [Session], cap: Int) -> [Session] {
        let live = SessionOrder.ranked(sessions.filter { !$0.isGhost })
        return Array(live.prefix(max(0, cap)))
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
            DragStrip()
                .frame(height: Self.gripHeight)

            cards

            if showsAdvisory,
               let advisory = appViewModel.hookHealthIssue,
               advisory.presentation == .chip {
                AdvisoryDetail(issue: advisory) { showsAdvisory = false }
                    .padding(.horizontal, Self.cardPadding)
                    .padding(.bottom, Self.cardPadding)
            }

            // The full panel separates its summary bar the same way.
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(height: 0.5)
                .padding(.horizontal, Self.cardPadding)

            footer
        }
        .background(panelSurface)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5)
        )
    }

    private var cards: some View {
        VStack(spacing: CompactSessionRow.gap) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, session in
                CompactSessionRow(session: session, index: index) {
                    appViewModel.focusSession(session)
                }

                // The question opens under the session that asked it.
                // Deferring to the terminal instead would mean the
                // feature the user switched on does not work in the
                // mode they keep open.
                if let request = expanded, request.pid == session.pid {
                    PermissionRequestRow(request: request) { decision in
                        appViewModel.answerPermissionRequest(request, with: decision)
                    }
                }
            }

            if rows.isEmpty {
                Text("No sessions")
                    .font(.system(size: 11))
                    .foregroundStyle(TextColor.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: CompactSessionRow.quietHeight)
            }
        }
        .padding(.horizontal, Self.cardPadding)
        .padding(.vertical, Self.cardPadding)
        // A session that starts working, or starts waiting on you,
        // climbs the list. Springing there rather than teleporting is
        // what makes the movement legible: you see which row moved and
        // where it came from.
        .animation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.82),
                   value: rows.map(\.id))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.28),
                   value: rows.map { PixelStatusIndicator.state(for: $0) })
    }

    /// The same material and border the full panel is made of: moving
    /// between modes should change the contents, not the window.
    private var panelSurface: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: NSColor(red: 0.08, green: 0.08, blue: 0.1, alpha: 0.85)))
        }
    }

    private var footer: some View {
        HStack(spacing: Spacing.xs) {
            // The same sprite the full panel's summary bar carries, at
            // the same size: the footer should say "Clyde" without
            // spelling it.
            ClydeAnimationView(state: appViewModel.clydeState, pixelSize: 0.75)
                .frame(width: 12, height: 12)

            ForEach(counts, id: \.label) { count in
                if isCrowded {
                    // Words do not fit beside an advisory and the way
                    // back: three labelled pills, a warning and a
                    // button come to more than 400 points, and the
                    // labels were truncating mid-word. The colours and
                    // the numbers survive; the words are a hover and a
                    // mode away.
                    CountDot(count: count.value, color: count.color)
                        .help("\(count.value) \(count.label)")
                } else {
                    StatusPill(count: count.value, label: count.label,
                               color: count.color, pulse: count.pulse)
                }
            }

            if counts.isEmpty {
                Text("No sessions")
                    .font(.system(size: 10))
                    .foregroundStyle(TextColor.tertiary)
            }

            Spacer(minLength: Spacing.xs)

            // The same advisory the full panel's summary bar carries.
            // Without it, switching to compact silently hid the fact
            // that the global shortcut is off — the panel that is meant
            // to stay open was the one place it went unsaid.
            if let advisory = appViewModel.hookHealthIssue,
               advisory.presentation == .chip {
                AdvisoryChip(issue: advisory) { showsAdvisory.toggle() }
            }

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
        .padding(.bottom, 4)
        .frame(height: Self.footerHeight)
    }

    private struct Count {
        let value: Int
        let label: String
        let color: Color
        let pulse: Bool
    }

    /// The same pills the full panel's summary bar uses, counted over
    /// every live session rather than the rows on screen — so the
    /// number never contradicts what the cap left out.
    /// Whether the footer has to give up its words.
    private var isCrowded: Bool {
        let advisory = appViewModel.hookHealthIssue?.presentation == .chip
        return counts.count > 2 || (advisory && counts.count > 1)
    }

    private var counts: [Count] {
        let live = sessionViewModel.sessions.filter { !$0.isGhost }
        let attention = live.filter(\.needsAttention).count
        let working = live.filter { $0.isWorking && !$0.needsAttention }.count
        let idle = live.count - attention - working

        var result: [Count] = []
        if attention > 0 {
            result.append(Count(value: attention, label: "needs you",
                                color: SessionTheme.attentionColor, pulse: true))
        }
        if working > 0 {
            result.append(Count(value: working, label: "working",
                                color: SessionTheme.processingColor, pulse: true))
        }
        if idle > 0 {
            result.append(Count(value: idle, label: "ready",
                                color: SessionTheme.readyColor, pulse: false))
        }
        return result
    }
}

/// A borderless window has nothing to grab, and compact has no header
/// to drag by.
private struct DragStrip: View {
    var body: some View {
        ZStack {
            Color.clear
            Capsule()
                .fill(Color.white.opacity(0.12))
                .frame(width: 22, height: 2.5)
        }
        .contentShape(Rectangle())
        .accessibilityHidden(true)
    }
}

/// A count with no room for its label: the dot keeps the colour, the
/// number keeps the fact, and the words are one hover away.
private struct CountDot: View {
    let count: Int
    let color: Color

    var body: some View {
        HStack(spacing: 3) {
            Circle()
                .fill(color)
                .frame(width: 5, height: 5)
            Text("\(count)")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(color.opacity(0.9))
                .monospacedDigit()
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 999)
                .fill(color.opacity(0.14))
        )
    }

}
