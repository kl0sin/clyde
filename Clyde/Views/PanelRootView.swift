import SwiftUI

/// What the panel window hosts: the full panel or the compact one.
///
/// Deliberately one hosting view that switches its contents rather than
/// two windows or a swapped `NSHostingView`. The window keeps its
/// identity — its position, its anchor to the widget, its shadow — and
/// only what is drawn inside it changes.
struct PanelRootView: View {
    @ObservedObject var appViewModel: AppViewModel
    @ObservedObject var sessionViewModel: SessionListViewModel

    var body: some View {
        switch appViewModel.panelMode {
        case .full:
            ExpandedRootView(appViewModel: appViewModel,
                             sessionViewModel: sessionViewModel)
        case .compact:
            CompactRootView(appViewModel: appViewModel,
                            sessionViewModel: sessionViewModel)
        }
    }
}
