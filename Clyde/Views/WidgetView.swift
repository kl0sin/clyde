import SwiftUI

struct WidgetView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        HStack(spacing: 10) {
            // Clyde with status ring
            ZStack {
                Circle()
                    .stroke(statusColor.opacity(0.6), lineWidth: 1.5)
                    .frame(width: 30, height: 30)
                ClydeAnimationView(
                    state: viewModel.clydeState,
                    pixelSize: 1.25
                )
                .frame(width: 20, height: 20)
            }

            // Label + status
            VStack(alignment: .leading, spacing: 1) {
                Text("Clyde")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)

                HStack(spacing: 4) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 5, height: 5)
                    Text(viewModel.statusText)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundColor(statusColor)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            ZStack {
                // Glass base
                RoundedRectangle(cornerRadius: 14)
                    .fill(.ultraThinMaterial)
                    .environment(\.colorScheme, .dark)

                // Subtle top highlight gradient
                RoundedRectangle(cornerRadius: 14)
                    .fill(
                        LinearGradient(
                            colors: [Color.white.opacity(0.08), Color.clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: 14))
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

    private var statusColor: Color {
        switch viewModel.clydeState {
        case .busy: return .orange
        case .idle: return .green
        case .sleeping: return Color(white: 0.5)
        }
    }
}
