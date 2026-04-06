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
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                ExpandedView(
                    appViewModel: appViewModel,
                    sessionViewModel: sessionViewModel
                )
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .edgesIgnoringSafeArea(.all)
    }
}
