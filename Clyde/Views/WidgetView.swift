import SwiftUI

struct WidgetView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        HStack(spacing: 10) {
            ClydeAnimationView(
                state: viewModel.clydeState,
                pixelSize: 1.4
            )
            .frame(width: 22, height: 22)

            Text("Clyde")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
                .fixedSize()

            // Divider
            RoundedRectangle(cornerRadius: 0.5)
                .fill(Color.white.opacity(0.12))
                .frame(width: 1, height: 14)

            // Status counts
            CompactStatusView(viewModel: viewModel)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.ultraThinMaterial)
                    .environment(\.colorScheme, .dark)

                RoundedRectangle(cornerRadius: 12)
                    .fill(
                        LinearGradient(
                            colors: [Color.white.opacity(0.06), Color.clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture {
            viewModel.toggleExpanded()
        }
        .contextMenu {
            Button(action: { viewModel.toggleExpanded() }) {
                Label("Open", systemImage: "rectangle.expand.vertical")
            }
            Button(action: { viewModel.showSettings = true; viewModel.isCollapsed = false }) {
                Label("Settings", systemImage: "gearshape")
            }
            Divider()
            Button(action: { NSApplication.shared.terminate(nil) }) {
                Label("Quit Clyde", systemImage: "power")
            }
        }
    }
}

private struct StatusDotCount: View {
    let count: Int
    let color: Color
    let activeColor: Color
    let pulse: Bool
    let dim: Bool

    var body: some View {
        HStack(spacing: 3) {
            Circle()
                .fill(dim ? Color(white: 0.3) : color)
                .frame(width: 5, height: 5)
                .opacity(pulse ? 0.35 : 1.0)
            Text("\(count)")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundColor(dim ? Color(white: 0.35) : activeColor)
                .monospacedDigit()
        }
    }
}

/// Compact status display: reserved width for both processing & ready slots
private struct CompactStatusView: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var isPulsing = false

    var body: some View {
        let sessions = viewModel.processMonitor.sessions
        let processing = sessions.filter { $0.status == .busy }.count
        let ready = sessions.count - processing

        Group {
            if sessions.isEmpty {
                HStack {
                    Spacer(minLength: 0)
                    Text("idle")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundColor(Color(white: 0.5))
                    Spacer(minLength: 0)
                }
            } else {
                HStack(spacing: 8) {
                    StatusDotCount(
                        count: processing,
                        color: .orange,
                        activeColor: .orange,
                        pulse: isPulsing && processing > 0,
                        dim: processing == 0
                    )
                    StatusDotCount(
                        count: ready,
                        color: .green,
                        activeColor: .green,
                        pulse: false,
                        dim: ready == 0
                    )
                }
            }
        }
        .frame(width: 60)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                isPulsing = true
            }
        }
    }
}
