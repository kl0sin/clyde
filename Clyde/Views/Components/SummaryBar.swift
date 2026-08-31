import SwiftUI

// MARK: - Summary Bar

struct SummaryBar: View {
    let sessionCount: Int
    let busyCount: Int
    let idleCount: Int
    let clydeState: ClydeState
    /// An advisory that is not worth a banner: the shortcut being off,
    /// or cleat's hook bridge. Sits here as a chip, with the detail and
    /// the way to fix it on hover.
    var advisory: HookInstaller.HealthIssue? = nil
    /// Owned by the panel, which draws the detail card over its own
    /// content — a system popover brings its own corner radius and
    /// padding and reads as another app's window inside this one.
    var advisoryExpanded: Binding<Bool> = .constant(false)

    @State private var isHoveringChip = false

    var body: some View {
        HStack(spacing: 10) {
            ClydeAnimationView(state: clydeState, pixelSize: 0.75)
                .frame(width: 12, height: 12)

            if sessionCount > 0 {
                HStack(spacing: 6) {
                    if busyCount > 0 {
                        StatusPill(count: busyCount, label: "processing", color: SessionTheme.processingColor, pulse: true)
                    }
                    if idleCount > 0 {
                        StatusPill(count: idleCount, label: "ready", color: SessionTheme.readyColor, pulse: false)
                    }
                }
            } else {
                Text("Waiting for sessions...")
                    .font(.system(size: 10))
                    .foregroundStyle(Color(white: 0.4))
            }

            Spacer()

            if let advisory {
                advisoryChip(advisory)
            }

            if sessionCount > 0 {
                Text("\(sessionCount) \(sessionCount == 1 ? "session" : "sessions")")
                    .font(.system(size: 10))
                    .foregroundStyle(Color(white: 0.4))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.03))
        .overlay(
            Rectangle().frame(height: 1).foregroundStyle(Color(white: 0.18)),
            alignment: .top
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(summaryAccessibilityLabel)
    }

    private var summaryAccessibilityLabel: String {
        if sessionCount == 0 { return "Waiting for sessions" }
        var parts: [String] = []
        if busyCount > 0 { parts.append("\(busyCount) working") }
        if idleCount > 0 { parts.append("\(idleCount) ready") }
        let summary = "Status summary: " + parts.joined(separator: ", ")
        let total = sessionCount == 1 ? "1 session" : "\(sessionCount) sessions"
        return "\(summary). \(total) total."
    }

    private func advisoryChip(_ issue: HookInstaller.HealthIssue) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 8))
            Text(issue.chipLabel)
                .font(.system(size: 10))
        }
        .foregroundStyle(Color(red: 0.95, green: 0.75, blue: 0.35))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: Radius.small)
                .fill(Color(red: 0.95, green: 0.75, blue: 0.35).opacity(0.12))
        )
        // Without this the tap only lands on the drawn pixels — the
        // gaps between the icon and the label are not part of the chip
        // as far as hit-testing is concerned, which reads as a chip
        // that sometimes ignores a click.
        .contentShape(Rectangle())
        .onHover { isHoveringChip = $0 }
        .opacity(isHoveringChip ? 0.85 : 1)
        .onTapGesture { advisoryExpanded.wrappedValue.toggle() }
        .help(issue.bannerMessage)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(issue.bannerTitle ?? issue.chipLabel)
        .accessibilityHint(issue.bannerMessage)
    }
}

struct StatusPill: View {
    let count: Int
    let label: String
    let color: Color
    let pulse: Bool

    @State private var isPulsing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
                .opacity(pulse && isPulsing ? 0.4 : 1.0)

            Text("\(count) \(label)")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(color.opacity(0.9))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color.opacity(0.1))
        .clipShape(Capsule())
        .onAppear {
            if pulse && !reduceMotion {
                withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                    isPulsing = true
                }
            }
        }
    }

}
