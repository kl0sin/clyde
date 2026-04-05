import SwiftUI

struct WidgetView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        HStack(spacing: 8) {
            ClydeAnimationView(
                state: viewModel.clydeState,
                pixelSize: 1.8
            )
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text("Clyde")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white)

                Text(viewModel.statusText)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(statusColor)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.4), radius: 6, y: 2)
        .onTapGesture {
            viewModel.toggleExpanded()
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
