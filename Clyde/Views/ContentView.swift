import SwiftUI

struct ContentView: View {
    @ObservedObject var appViewModel: AppViewModel
    @ObservedObject var sessionViewModel: SessionListViewModel

    var body: some View {
        ZStack(alignment: .top) {
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

            // Error banner overlay
            if !appViewModel.isCollapsed, let error = appViewModel.lastError {
                ErrorBanner(message: error)
                    .padding(.top, 8)
                    .padding(.horizontal, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: appViewModel.lastError)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .edgesIgnoringSafeArea(.all)
    }
}

struct ErrorBanner: View {
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundColor(.red)
            Text(message)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white)
                .lineLimit(2)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.18))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.red.opacity(0.4), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
