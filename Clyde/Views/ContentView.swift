import SwiftUI

struct ContentView: View {
    @ObservedObject var appViewModel: AppViewModel
    @ObservedObject var sessionViewModel: SessionListViewModel

    var body: some View {
        Group {
            if appViewModel.isCollapsed {
                WidgetView(viewModel: appViewModel)
            } else if appViewModel.showSettings {
                SettingsView(appViewModel: appViewModel)
            } else {
                ExpandedView(
                    appViewModel: appViewModel,
                    sessionViewModel: sessionViewModel,
                    onNewSession: {
                        sessionViewModel.createNewSession()
                    }
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .edgesIgnoringSafeArea(.all)
    }
}
