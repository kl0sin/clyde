import SwiftUI

struct ContentView: View {
    @ObservedObject var appViewModel: AppViewModel
    @ObservedObject var sessionViewModel: SessionListViewModel

    var body: some View {
        ZStack {
            if appViewModel.isCollapsed {
                WidgetView(viewModel: appViewModel)
                    .transition(.opacity)
            } else if appViewModel.showSettings {
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
        .animation(.easeInOut(duration: 0.15), value: appViewModel.isCollapsed)
        .animation(.easeInOut(duration: 0.15), value: appViewModel.showSettings)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .edgesIgnoringSafeArea(.all)
    }
}
