import SwiftUI

/// Label · bar · percentage. One component in three widths: the full
/// panel's band, compact's footer, and the band's opened rows use it
/// with different bars and the same words.
struct UsageMeter: View {
    /// "5h" / "7d". Nil when the footer is too crowded for words.
    let label: String?
    let window: UsageWindow
    let level: UsageLimits.Level
    let stale: Bool
    let barWidth: CGFloat
    var showsValue: Bool = true

    static func color(for level: UsageLimits.Level) -> Color {
        switch level {
        case .normal:    return Color.white.opacity(0.55)
        case .warning:   return SessionTheme.attentionColor
        case .exhausted: return SessionTheme.errorColor
        }
    }

    var body: some View {
        let fill = Self.color(for: level)
        HStack(spacing: 4) {
            if let label {
                Text(label)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(TextColor.tertiary)
            }
            UsageBar(usedPercentage: window.usedPercentage, fill: fill)
                .frame(width: barWidth)
            if showsValue {
                Text(UsageLimits.percentText(for: window, level: level))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(level == .normal ? TextColor.secondary : fill)
            }
        }
        .opacity(stale ? 0.55 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        let name = label == "7d" ? "Week" : "Session"
        return "\(name) \(UsageLimits.percentText(for: window, level: level)) used"
    }
}

/// The bar alone: a track and a fill, sized by whatever frame it is
/// given. The meter gives it a fixed width; the band's rows let it
/// fill the row.
struct UsageBar: View {
    let usedPercentage: Double
    let fill: Color
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.10))
                Capsule().fill(fill)
                    .frame(width: geo.size.width * CGFloat(min(100, max(0, usedPercentage)) / 100))
            }
        }
        .frame(height: height)
    }
}
