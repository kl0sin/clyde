import SwiftUI

struct ContentView: View {
    @ObservedObject var appViewModel: AppViewModel
    @ObservedObject var sessionViewModel: SessionListViewModel

    var body: some View {
        Group {
            if appViewModel.isCollapsed {
                WidgetView(viewModel: appViewModel)
            } else {
                if appViewModel.showSettings {
                    SettingsView(appViewModel: appViewModel)
                } else {
                    ExpandedView(
                        appViewModel: appViewModel,
                        sessionViewModel: sessionViewModel,
                        onFocusSession: { session in
                            Task {
                                try? await appViewModel.terminalLauncher.focusSession(session)
                            }
                        },
                        onNewSession: {
                            Task {
                                try? await appViewModel.terminalLauncher.openNewSession()
                            }
                        }
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
