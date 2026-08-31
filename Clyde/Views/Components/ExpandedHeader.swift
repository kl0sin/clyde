import SwiftUI

/// Hero-style header for the expanded panel: large mascot tile with a
/// stateful glow + halo, the "Clyde" wordmark, an inline stats row that
/// only shows non-zero counts, and the right-side controls
/// (snooze / settings / collapse).
///
/// Replaces the older `TitleBar` design. Lives in its own file so the
/// stats logic stays self-contained.
struct ExpandedHeader: View {
    let clydeState: ClydeState
    let attentionCount: Int
    let workingCount: Int
    let readyCount: Int
    let isSnoozed: Bool
    let snoozeRemainingMinutes: Int?
    let onSnooze: () -> Void
    let onSettings: () -> Void
    let onCollapse: () -> Void
    /// Switch to the compact panel: the rows, without the chrome built
    /// for reading. Nil hides the button, so the header stays usable in
    /// contexts that have no mode to switch to.
    var onCompact: (() -> Void)?

    var body: some View {
        HStack(spacing: Spacing.sm) {
            // Mascot tile — colour driven by clydeState. Halo + glow scales
            // with the state so the user can read the dominant state from
            // the header alone, even before glancing at the stats.
            ZStack {
                RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
                    .fill(accentColor.opacity(0.16))
                    .frame(width: 56, height: 56)
                RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
                    .strokeBorder(accentColor.opacity(0.45), lineWidth: 0.75)
                    .frame(width: 56, height: 56)
                ClydeAnimationView(state: clydeState, pixelSize: 2.625)
                    .frame(width: 42, height: 42)
            }
            .shadow(color: accentColor.opacity(0.30), radius: 14, y: 0)

            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text("Clyde")
                    .font(.system(size: 16, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .accessibilityAddTraits(.isHeader)

                statsRow
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(statsAccessibilityLabel)
            }

            Spacer(minLength: 0)

            HStack(spacing: 4) {
                headerButton(
                    icon: isSnoozed ? "moon.zzz.fill" : "moon.zzz",
                    action: onSnooze,
                    accessibilityLabel: isSnoozed ? "Resume notifications" : "Snooze notifications"
                )
                .coachmarkAnchor(.snooze)
                .accessibilityValue(snoozeAccessibilityValue)

                if let onCompact {
                    headerButton(
                        icon: "rectangle.compress.vertical",
                        action: onCompact,
                        accessibilityLabel: "Switch to the compact panel"
                    )
                    .accessibilityHint("Shows the session rows only, small enough to leave open")
                }

                headerButton(
                    icon: "gearshape",
                    action: onSettings,
                    accessibilityLabel: "Open settings"
                )

                headerButton(
                    icon: "minus",
                    action: onCollapse,
                    accessibilityLabel: "Collapse to widget"
                )
                .coachmarkAnchor(.collapse)
                .accessibilityHint("Or press Control-Command-C from anywhere")
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(
            // Soft state-coloured gradient bleeding from the top so the
            // header sits on a hint of the dominant colour without
            // taking attention away from the session list.
            LinearGradient(
                colors: [accentColor.opacity(0.10), Color.clear],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .overlay(
            // Hairline accent rule under the header that bleeds into the
            // session list, mirroring the original TitleBar treatment.
            LinearGradient(
                colors: [accentColor.opacity(0.45), accentColor.opacity(0.0)],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(height: 1),
            alignment: .bottom
        )
        .animation(.easeInOut(duration: 0.30), value: clydeState)
    }

    // MARK: - Stats row

    @ViewBuilder
    private var statsRow: some View {
        let entries = visibleStats
        if entries.isEmpty {
            // No live sessions at all — single muted line so the header
            // doesn't look empty / broken.
            HStack(spacing: 5) {
                Circle()
                    .fill(TextColor.tertiary)
                    .frame(width: 5, height: 5)
                Text("No active sessions")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(TextColor.tertiary)
            }
        } else {
            // Three states and four buttons do not fit across 400
            // points, and these counts refuse to shrink — so with
            // everything happening at once the header asked for more
            // width than the panel has and pushed the rows' elapsed
            // figures off the right edge. Past two states the words go
            // and the colours and numbers stay, exactly as the compact
            // footer does it.
            let crowded = entries.count > 2
            HStack(spacing: crowded ? 7 : 10) {
                ForEach(entries, id: \.label) { entry in
                    HStack(spacing: 5) {
                        Circle()
                            .fill(entry.color)
                            .frame(width: 5, height: 5)
                        Text(crowded ? "\(entry.count)" : "\(entry.count) \(entry.label)")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(TextColor.secondary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .help("\(entry.count) \(entry.label)")
                    }
                }
            }
        }
    }

    /// Stats to render in the header in priority order
    /// (attention > working > ready), filtering anything with count == 0
    /// so the header stays clean.
    private var visibleStats: [(label: String, count: Int, color: Color)] {
        var entries: [(String, Int, Color)] = []
        if attentionCount > 0 {
            entries.append(("attention", attentionCount, SessionTheme.attentionColor))
        }
        if workingCount > 0 {
            entries.append(("working", workingCount, SessionTheme.processingColor))
        }
        if readyCount > 0 {
            entries.append(("ready", readyCount, SessionTheme.readyColor))
        }
        return entries
    }

    /// Single combined VoiceOver string for the stats row. Visually the
    /// row is three colored dot+count pairs; VO users get a comma-joined
    /// summary in the same priority order (attention > working > ready)
    /// so they don't have to swipe through three elements to learn what
    /// changed.
    private var statsAccessibilityLabel: String {
        let entries = visibleStats
        if entries.isEmpty { return "No active sessions" }
        let parts = entries.map { "\($0.count) \($0.label)" }
        return "Status summary: " + parts.joined(separator: ", ")
    }

    /// Remaining-time announcement for the snooze button. Rendered as
    /// the button's `.accessibilityValue` so VO reads "Resume
    /// notifications, Snoozed for 23 minutes" — users learn when
    /// notifications resume without leaving the row.
    private var snoozeAccessibilityValue: String {
        guard isSnoozed, let minutes = snoozeRemainingMinutes else { return "" }
        return minutes == 1 ? "Snoozed for 1 minute" : "Snoozed for \(minutes) minutes"
    }

    // MARK: - Helpers

    private var accentColor: Color {
        switch clydeState {
        case .attention: return SessionTheme.attentionColor
        case .busy:      return SessionTheme.processingColor
        case .idle:      return SessionTheme.readyColor
        case .sleeping:  return Color(white: 0.4)
        }
    }

    @ViewBuilder
    private func headerButton(
        icon: String,
        action: @escaping () -> Void,
        accessibilityLabel: String
    ) -> some View {
        HoverableHeaderButton(
            icon: icon,
            action: action,
            accessibilityLabel: accessibilityLabel
        )
    }
}

/// Header / title-bar icon button with a hover state. macOS users expect
/// every clickable surface to respond to hover; the original
/// `headerButton` rendered a static low-opacity fill regardless of
/// cursor position, which made the gear / minus / snooze buttons read
/// as decorative on first glance.
private struct HoverableHeaderButton: View {
    let icon: String
    let action: () -> Void
    let accessibilityLabel: String

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isHovered ? Color.white : TextColor.tertiary)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
                        .fill(Color.white.opacity(isHovered ? 0.12 : 0.04))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .accessibilityLabel(accessibilityLabel)
    }
}
