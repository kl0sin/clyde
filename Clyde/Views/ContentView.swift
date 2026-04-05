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
                                do {
                                    try await appViewModel.terminalLauncher.openNewSession()
                                } catch {
                                    print("Failed to open new session: \(error)")
                                }
                            }
                        }
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .edgesIgnoringSafeArea(.all)
    }
}
