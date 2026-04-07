import SwiftUI

// MARK: - Empty State

struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 12) {
            ClydeAnimationView(state: .sleeping, pixelSize: 2.5)
                .frame(width: 40, height: 40)

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
    }
}
