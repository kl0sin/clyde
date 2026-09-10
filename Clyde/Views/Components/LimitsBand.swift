import SwiftUI

/// The two subscription windows, above Activity, in Activity's own
/// language: a header row that is the whole thing when closed, and two
/// rows with the resets when open.
struct LimitsBand: View {
    let limits: UsageLimits
    let rateLimited: Bool
    let stale: Bool
    let sessionName: String?

    @AppStorage("limitsBandExpanded") private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func level(_ window: UsageWindow, isSession: Bool) -> UsageLimits.Level {
        UsageLimits.level(for: window, rateLimited: isSession && rateLimited)
    }

    var body: some View {
        // Countdowns move; a periodic clock keeps them honest without
        // the store having to publish for a minute passing.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(spacing: 0) {
                header
                if expanded {
                    rows(now: context.date)
                }
            }
        }
        .background(Color.white.opacity(0.02))
        .overlay(
            Rectangle().frame(height: Rule.thickness).foregroundStyle(Rule.band),
            alignment: .top
        )
    }

    private var header: some View {
        Button(action: {
            if reduceMotion { expanded.toggle() } else {
                withAnimation(.easeInOut(duration: 0.22)) { expanded.toggle() }
            }
        }) {
            HStack(spacing: 8) {
                Image(systemName: "gauge.with.needle")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color(white: 0.5))
                Text("Limits")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(white: 0.7))
                if let w = limits.fiveHour {
                    UsageMeter(label: "5h", window: w, level: level(w, isSession: true),
                               stale: stale, barWidth: 44)
                }
                if let w = limits.sevenDay {
                    UsageMeter(label: "7d", window: w, level: level(w, isSession: false),
                               stale: stale, barWidth: 44)
                }
                Spacer(minLength: 4)
                Image(systemName: expanded ? "chevron.down" : "chevron.up")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color(white: 0.45))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Claude usage limits")
        .accessibilityHint(expanded ? "Tap to collapse" : "Tap to expand")
    }

    private func rows(now: Date) -> some View {
        VStack(spacing: 0) {
            if let w = limits.fiveHour {
                row(name: "Session", window: w, level: level(w, isSession: true), now: now)
            }
            if let w = limits.sevenDay {
                if limits.fiveHour != nil {
                    Rectangle().fill(Rule.row).frame(height: Rule.thickness).padding(.leading, 34)
                }
                row(name: "Week", window: w, level: level(w, isSession: false), now: now)
            }
            Text(limits.freshnessText(now: now, sessionName: sessionName, stale: stale))
                .font(.system(size: 9.5))
                .foregroundStyle(TextColor.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 34)
                .padding(.trailing, 14)
                .padding(.top, 4)
                .padding(.bottom, 8)
        }
    }

    private func row(name: String, window: UsageWindow, level: UsageLimits.Level, now: Date) -> some View {
        let fill = UsageMeter.color(for: level)
        return HStack(spacing: 12) {
            Text(name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(TextColor.secondary)
                .frame(width: 58, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.10))
                    Capsule().fill(fill)
                        .frame(width: geo.size.width * CGFloat(min(100, max(0, window.usedPercentage)) / 100))
                }
            }
            .frame(height: 5)
            Text(UsageLimits.percentText(for: window, level: level))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(level == .normal ? TextColor.primary : fill)
                .frame(width: 34, alignment: .trailing)
            Text(UsageLimits.resetText(for: window, now: now, level: level))
                .font(.system(size: 10, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(level == .exhausted ? fill : TextColor.tertiary)
                .frame(width: 118, alignment: .trailing)
        }
        .padding(.leading, 34)
        .padding(.trailing, 14)
        .padding(.vertical, 7)
        .opacity(stale ? 0.55 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name) \(UsageLimits.percentText(for: window, level: level)) used, \(UsageLimits.resetText(for: window, now: now, level: level))")
    }
}
