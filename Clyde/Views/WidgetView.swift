import SwiftUI

struct WidgetView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
                )

            HStack(spacing: 8) {
                ClydeAnimationView(
                    state: viewModel.clydeState,
                    pixelSize: 1.5
                )
                .frame(width: 24, height: 24)

                VStack(alignment: .leading, spacing: 0) {
                    Text("Clyde")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)

                    Text(viewModel.statusText)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(statusColor)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    private var statusColor: Color {
        switch viewModel.clydeState {
        case .busy: return .orange
        case .idle: return .green
        case .sleeping: return Color(white: 0.45)
        }
    }
}
