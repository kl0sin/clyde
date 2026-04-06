import SwiftUI

// MARK: - Summary Bar

struct SummaryBar: View {
    let sessionCount: Int
    let busyCount: Int
    let idleCount: Int
    let clydeState: ClydeState

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
                    .foregroundColor(Color(white: 0.4))
            }

            Spacer()

            if sessionCount > 0 {
                Text("\(sessionCount) \(sessionCount == 1 ? "session" : "sessions")")
                    .font(.system(size: 10))
                    .foregroundColor(Color(white: 0.4))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.03))
        .overlay(
            Rectangle().frame(height: 1).foregroundColor(Color(white: 0.18)),
            alignment: .top
        )
    }
}

struct StatusPill: View {
    let count: Int
    let label: String
    let color: Color
    let pulse: Bool

    @State private var isPulsing = false

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
                .opacity(pulse && isPulsing ? 0.4 : 1.0)

            Text("\(count) \(label)")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(color.opacity(0.9))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color.opacity(0.1))
        .clipShape(Capsule())
        .onAppear {
            if pulse {
                withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                    isPulsing = true
                }
            }
        }
    }
}
