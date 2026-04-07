import SwiftUI

// MARK: - Title Bar

struct TitleBar: View {
    let clydeState: ClydeState
    let onSettings: () -> Void
    let onCollapse: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            // Mascot tile — bigger, with a subtle tinted halo matching the
            // current Clyde state so the header carries a bit of personality.
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(accentColor.opacity(0.14))
                    .frame(width: 38, height: 38)
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(accentColor.opacity(0.25), lineWidth: 0.5)
                    .frame(width: 38, height: 38)
                ClydeAnimationView(state: clydeState, pixelSize: 1.5)
                    .frame(width: 24, height: 24)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("Clyde")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                Text(subtitle)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(accentColor.opacity(0.85))
            }

            Spacer()

            HStack(spacing: 2) {
                titleBarButton(icon: "gearshape", action: onSettings)
                titleBarButton(icon: "minus", action: onCollapse)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            ZStack {
                // Subtle horizontal gradient — slightly darker at the edges,
                // a touch of the accent colour bleeding in from the left.
                LinearGradient(
                    colors: [
                        accentColor.opacity(0.07),
                        Color.white.opacity(0.02),
                        Color.clear,
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            }
        )
        .overlay(
            // Accent-colored hairline underline so the state "bleeds" into
            // the session list below.
            LinearGradient(
                colors: [accentColor.opacity(0.45), accentColor.opacity(0.0)],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(height: 1),
            alignment: .bottom
        )
        .animation(.easeInOut(duration: 0.3), value: clydeState)
    }

    private func titleBarButton(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Color(white: 0.55))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            // Just a contentShape hover; native cursor change is enough.
            _ = hovering
        }
    }

    /// Matches the widget + SessionTheme palette: purple when any session is
    /// working, blue for attention, green for ready, dim grey for sleeping.
    private var accentColor: Color {
        switch clydeState {
        case .attention: return .blue
        case .busy:      return SessionTheme.processingColor
        case .idle:      return SessionTheme.readyColor
        case .sleeping:  return Color(white: 0.4)
        }
    }

    private var subtitle: String {
        switch clydeState {
        case .attention: return "Needs your input"
        case .busy:      return "Working on it"
        case .idle:      return "Ready"
        case .sleeping:  return "No sessions"
        }
    }
}
