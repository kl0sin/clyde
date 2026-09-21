import SwiftUI

// MARK: - Summary Bar

struct SummaryBar: View {
    let sessionCount: Int
    let busyCount: Int
    let idleCount: Int
    var automatedCount: Int = 0
    let clydeState: ClydeState
    /// An advisory that is not worth a banner: the shortcut being off,
    /// or cleat's hook bridge. Sits here as a chip, with the detail and
    /// the way to fix it on hover.
    var advisory: HookInstaller.HealthIssue? = nil
    /// Owned by the panel, which draws the detail card over its own
    /// content — a system popover brings its own corner radius and
    /// padding and reads as another app's window inside this one.
    var advisoryExpanded: Binding<Bool> = .constant(false)


    var body: some View {
        HStack(spacing: 10) {
            ClydeAnimationView(state: clydeState, pixelSize: ClydeAnimationView.barPixelSize)
                .frame(width: ClydeAnimationView.barSize, height: ClydeAnimationView.barSize)
                // Its ink on the window's margin, not its frame.
                .padding(.leading, -ClydeAnimationView.barInkInset)

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
                AdvisoryChip(issue: advisory) { advisoryExpanded.wrappedValue.toggle() }
            }

            if sessionCount > 0 || automatedCount > 0 {
                // The count is the first thing to give up its words: with
                // an advisory chip beside it, the full sentence pushed
                // the pills onto two lines. The pills never wrap; this
                // text shortens instead, then truncates.
                ViewThatFits(in: .horizontal) {
                    Text(summaryText)
                    Text(shortSummaryText)
                }
                .font(.system(size: 10))
                .foregroundStyle(Color(white: 0.4))
                .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.03))
        .overlay(
            Rectangle().frame(height: Rule.thickness).foregroundStyle(Rule.band),
            alignment: .top
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(summaryAccessibilityLabel)
    }

    /// "6 · 2 auto": the same facts when the sentence does not fit.
    private var shortSummaryText: String {
        if sessionCount == 0 { return "\(automatedCount) auto" }
        return automatedCount > 0 ? "\(sessionCount) · \(automatedCount) auto" : "\(sessionCount)"
    }

    private var summaryText: String {
        if sessionCount == 0 {
            return "\(automatedCount) automated"
        }
        let base = "\(sessionCount) \(sessionCount == 1 ? "session" : "sessions")"
        guard automatedCount > 0 else { return base }
        return "\(base) · \(automatedCount) automated"
    }

    private var summaryAccessibilityLabel: String {
        if sessionCount == 0 {
            if automatedCount > 0 { return "Waiting for sessions. \(automatedCount) automated." }
            return "Waiting for sessions"
        }
        var parts: [String] = []
        if busyCount > 0 { parts.append("\(busyCount) working") }
        if idleCount > 0 { parts.append("\(idleCount) ready") }
        let summary = "Status summary: " + parts.joined(separator: ", ")
        let total = sessionCount == 1 ? "1 session" : "\(sessionCount) sessions"
        var label = "\(summary). \(total) total."
        if automatedCount > 0 { label += " \(automatedCount) automated." }
        return label
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
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
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
