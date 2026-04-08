import SwiftUI

/// Root view hosted inside the expanded panel. Switches between the
/// session list and the settings screen based on `appViewModel.showSettings`.
/// Doesn't host the widget — that lives in its own panel now.
struct ExpandedRootView: View {
    @ObservedObject var appViewModel: AppViewModel
    @ObservedObject var sessionViewModel: SessionListViewModel

    var body: some View {
        ZStack(alignment: .top) {
            Group {
                if appViewModel.showSettings {
                    SettingsView(appViewModel: appViewModel)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .transition(.opacity)
                } else {
                    ExpandedView(
                        appViewModel: appViewModel,
                        sessionViewModel: sessionViewModel
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.22), value: appViewModel.showSettings)

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
