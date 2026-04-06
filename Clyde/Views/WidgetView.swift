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
    let pulse: Bool
    let visible: Bool

    var body: some View {
        HStack(spacing: 3) {
            Circle()
                .fill(color)
                .frame(width: 5, height: 5)
                .opacity(pulse ? 0.35 : 1.0)
            Text("\(count)")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundColor(color)
                .monospacedDigit()
        }
        .opacity(visible ? 1 : 0)
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
                Text("idle")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundColor(Color(white: 0.5))
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: 6) {
                    // Always reserve slot for processing
                    StatusDotCount(
                        count: processing,
                        color: .orange,
                        pulse: isPulsing,
                        visible: processing > 0
                    )
                    // Always reserve slot for ready
                    StatusDotCount(
                        count: ready,
                        color: .green,
                        pulse: false,
                        visible: ready > 0
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 56, alignment: .leading)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                isPulsing = true
            }
        }
    }
}
