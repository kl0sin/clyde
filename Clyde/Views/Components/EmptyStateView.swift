import SwiftUI

// MARK: - Empty State

struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 12) {
            ClydeAnimationView(state: .sleeping, pixelSize: 3)
                .frame(width: 48, height: 48)

            Text("No Claude sessions")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color(white: 0.5))

            Text("Start claude in any terminal\nand Clyde will detect it")
                .font(.system(size: 11))
                .foregroundStyle(Color(white: 0.35))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .coachmarkAnchor(.emptyState)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("No active Claude sessions. Start one in your terminal to see it here.")
    }
}
