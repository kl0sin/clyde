import SwiftUI

/// Root view hosted inside the expanded panel. Always shows the session
/// list — settings now live in their own standalone window.
struct ExpandedRootView: View {
    @ObservedObject var appViewModel: AppViewModel
    @ObservedObject var sessionViewModel: SessionListViewModel

    var body: some View {
        ZStack(alignment: .top) {
            ExpandedView(
                appViewModel: appViewModel,
                sessionViewModel: sessionViewModel
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))

            if let error = appViewModel.lastError {
                ErrorBanner(message: error)
                    .padding(.top, 8)
                    .padding(.horizontal, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: appViewModel.lastError)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
    }
}
