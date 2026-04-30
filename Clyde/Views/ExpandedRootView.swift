import SwiftUI

/// Root view hosted inside the expanded panel. Always shows the session
/// list — settings now live in their own standalone window.
struct ExpandedRootView: View {
    @ObservedObject var appViewModel: AppViewModel
    @ObservedObject var sessionViewModel: SessionListViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? .none : .easeOut(duration: 0.2), value: appViewModel.lastError)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .environmentObject(appViewModel.coachmarks)
        .onAppear {
            appViewModel.coachmarks.maybeStart(hasSessions: appViewModel.hasLiveSessions)
        }
        .onDisappear {
            if appViewModel.coachmarks.currentStep == .collapse {
                // Closing the panel while the popover points at the collapse
                // button IS the action the popover is teaching — treat it as
                // completion rather than a mid-tour reset.
                appViewModel.coachmarks.advance()
            } else {
                appViewModel.coachmarks.reset()
            }
        }
    }
}
