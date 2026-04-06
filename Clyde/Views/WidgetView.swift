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

/// Compact status display: colored dot + count, only shown for non-zero states
private struct CompactStatusView: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var isPulsing = false

    var body: some View {
        let sessions = viewModel.processMonitor.sessions
        let processing = sessions.filter { $0.status == .busy }.count
        let ready = sessions.count - processing

        HStack(spacing: 6) {
            if sessions.isEmpty {
                Text("idle")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundColor(Color(white: 0.5))
            } else {
                if processing > 0 {
                    HStack(spacing: 3) {
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 5, height: 5)
                            .opacity(isPulsing ? 0.35 : 1.0)
                        Text("\(processing)")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundColor(.orange)
                            .monospacedDigit()
                    }
                }
                if ready > 0 {
                    HStack(spacing: 3) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 5, height: 5)
                        Text("\(ready)")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundColor(.green)
                            .monospacedDigit()
                    }
                }
            }
        }
        .fixedSize()
        .onAppear {
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                isPulsing = true
            }
        }
    }
}
