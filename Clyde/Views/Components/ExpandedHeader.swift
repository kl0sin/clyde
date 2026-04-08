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
    let onSnooze: () -> Void
    let onSettings: () -> Void
    let onCollapse: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            // Mascot tile — colour driven by clydeState. Halo + glow scales
            // with the state so the user can read the dominant state from
            // the header alone, even before glancing at the stats.
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(accentColor.opacity(0.16))
                    .frame(width: 56, height: 56)
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(accentColor.opacity(0.45), lineWidth: 0.75)
                    .frame(width: 56, height: 56)
                ClydeAnimationView(state: clydeState, pixelSize: 2.625)
                    .frame(width: 42, height: 42)
            }
            .shadow(color: accentColor.opacity(0.30), radius: 14, y: 0)

            VStack(alignment: .leading, spacing: 4) {
                Text("Clyde")
                    .font(.system(size: 16, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .accessibilityAddTraits(.isHeader)

                statsRow
            }

            Spacer(minLength: 0)

            HStack(spacing: 4) {
                headerButton(
                    icon: isSnoozed ? "moon.zzz.fill" : "moon.zzz",
                    action: onSnooze,
                    accessibilityLabel: isSnoozed ? "Resume notifications" : "Snooze notifications"
                )
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
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
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
                    .fill(Color(white: 0.4))
                    .frame(width: 5, height: 5)
                Text("No active sessions")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color(white: 0.5))
            }
        } else {
            HStack(spacing: 10) {
                ForEach(entries, id: \.label) { entry in
                    HStack(spacing: 5) {
                        Circle()
                            .fill(entry.color)
                            .frame(width: 5, height: 5)
                        Text("\(entry.count) \(entry.label)")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color(white: 0.65))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
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
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color(white: 0.6))
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(0.04))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}
