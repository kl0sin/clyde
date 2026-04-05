import SwiftUI

struct WidgetView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        HStack(spacing: 10) {
            ClydeAnimationView(
                state: viewModel.clydeState,
                pixelSize: 2
            )
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text("Clyde")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white)

                Text(viewModel.statusText)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(statusColor)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: NSColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 0.95)))
                .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(statusBorderColor.opacity(0.3), lineWidth: 1)
        )
        .onTapGesture {
            viewModel.toggleExpanded()
        }
    }

    private var statusColor: Color {
        switch viewModel.clydeState {
        case .busy: return .red
        case .idle: return .green
        case .sleeping: return Color(white: 0.5)
        }
    }

    private var statusBorderColor: Color {
        switch viewModel.clydeState {
        case .busy: return .red
        case .idle: return .green
        case .sleeping: return Color(white: 0.3)
        }
    }
}
