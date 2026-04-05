import SwiftUI

struct WidgetView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        VStack(spacing: 8) {
            ClydeAnimationView(
                state: viewModel.clydeState,
                pixelSize: 3
            )

            Text(viewModel.statusText)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(statusColor)
                .tracking(0.5)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(nsColor: NSColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1)))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color(white: 0.2), lineWidth: 1)
        )
        .onTapGesture {
            viewModel.toggleExpanded()
        }
    }

    private var statusColor: Color {
        switch viewModel.clydeState {
        case .busy: return .red
        case .idle: return .green
        case .sleeping: return .gray
        }
    }
}
