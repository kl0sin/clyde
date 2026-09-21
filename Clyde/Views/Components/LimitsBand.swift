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
                Spacer(minLength: 4)
                // Words, not bars. A grey bar at 1% is background
                // pretending to be content, and six things in one row
                // read as a form. The same voice as the summary bar's
                // "6 sessions · 2 automated": a word and a figure, mono,
                // muted. Colour arrives only with something to say —
                // the bars live in the opened rows, where they have
                // width and a reset beside them.
                HStack(spacing: 0) {
                    if let w = limits.fiveHour {
                        quiet("Session", window: w, level: level(w, isSession: true))
                    }
                    if limits.fiveHour != nil, limits.sevenDay != nil {
                        Text(" · ")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(Color.white.opacity(0.25))
                    }
                    if let w = limits.sevenDay {
                        quiet("Week", window: w, level: level(w, isSession: false))
                    }
                }
                .opacity(stale ? 0.55 : 1)
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

    /// One window as a word and a figure. The figure alone carries the
    /// level's colour; the word stays muted at every level.
    private func quiet(_ name: String, window: UsageWindow, level: UsageLimits.Level) -> some View {
        HStack(spacing: 4) {
            Text(name)
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(TextColor.tertiary)
            Text(UsageLimits.percentText(for: window, level: level))
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(level == .normal ? TextColor.secondary : UsageMeter.color(for: level))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name) \(UsageLimits.percentText(for: window, level: level)) used")
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
            Text(limits.freshnessText(now: now, sessionName: sessionName, stale: stale)
                 + (limits.modelName.map { " · \($0)" } ?? ""))
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
            UsageBar(usedPercentage: window.usedPercentage, fill: fill, height: 5)
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
