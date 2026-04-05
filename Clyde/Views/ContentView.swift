import SwiftUI

struct ContentView: View {
    @ObservedObject var appViewModel: AppViewModel
    @ObservedObject var sessionViewModel: SessionListViewModel

    var body: some View {
        ZStack {
            // Both views exist simultaneously — opacity crossfade
            WidgetView(viewModel: appViewModel)
                .opacity(appViewModel.isCollapsed ? 1 : 0)
                .scaleEffect(appViewModel.isCollapsed ? 1 : 0.8)

            Group {
                if appViewModel.showSettings {
                    SettingsView(appViewModel: appViewModel)
                } else {
                    ExpandedView(
                        appViewModel: appViewModel,
                        sessionViewModel: sessionViewModel
                    )
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .opacity(appViewModel.isCollapsed ? 0 : 1)
            .scaleEffect(appViewModel.isCollapsed ? 1.05 : 1)
        }
        .animation(.easeOut(duration: 0.25), value: appViewModel.isCollapsed)
        .animation(.easeInOut(duration: 0.2), value: appViewModel.showSettings)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .edgesIgnoringSafeArea(.all)
    }
}
