import SwiftUI

struct ExpandedView: View {
    @ObservedObject var appViewModel: AppViewModel
    @ObservedObject var sessionViewModel: SessionListViewModel
    let onFocusSession: (Session) -> Void
    let onNewSession: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            TitleBar(
                clydeState: appViewModel.clydeState,
                onSettings: { appViewModel.showSettings = true },
                onCollapse: { appViewModel.toggleExpanded() }
            )

            Divider().background(Color(white: 0.2))

            SessionTabBar(
                sessions: sessionViewModel.sessions,
                selectedID: sessionViewModel.selectedSessionID ?? sessionViewModel.sessions.first?.id,
                onSelect: { session in
                    sessionViewModel.selectSession(session)
                    onFocusSession(session)
                },
                onNewSession: onNewSession
            )

            Divider().background(Color(white: 0.2))

            if let session = sessionViewModel.selectedSession {
                SessionDetailView(session: session)
            } else {
                VStack {
                    Text("No active sessions")
                        .foregroundColor(.gray)
                        .font(.system(size: 13))
                    Button("Start a session") { onNewSession() }
                        .buttonStyle(.plain)
                        .foregroundColor(.purple)
                        .font(.system(size: 13))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            }

            Spacer(minLength: 0)

            StatusBar(
                sessionCount: sessionViewModel.sessionCount,
                busyCount: sessionViewModel.busyCount,
                idleCount: sessionViewModel.idleCount
            )
        }
        .background(Color(nsColor: NSColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1)))
    }
}

struct TitleBar: View {
    let clydeState: ClydeState
    let onSettings: () -> Void
    let onCollapse: () -> Void

    var body: some View {
        HStack {
            HStack(spacing: 8) {
                ClydeAnimationView(state: clydeState, pixelSize: 1.25)
                    .frame(width: 20, height: 20)

                Text("Clyde")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
            }

            Spacer()

            HStack(spacing: 8) {
                Button(action: onSettings) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 11))
                        .foregroundColor(.gray)
                }
                .buttonStyle(.plain)

                Button(action: onCollapse) {
                    Image(systemName: "minus")
                        .font(.system(size: 14))
                        .foregroundColor(.gray)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(white: 0.13))
    }
}

struct StatusBar: View {
    let sessionCount: Int
    let busyCount: Int
    let idleCount: Int

    var body: some View {
        HStack {
            Text("\(sessionCount) sessions")
                .foregroundColor(.gray)

            Spacer()

            HStack(spacing: 12) {
                if busyCount > 0 {
                    HStack(spacing: 4) {
                        Circle().fill(Color.red).frame(width: 6, height: 6)
                        Text("\(busyCount) busy").foregroundColor(.red)
                    }
                }
                if idleCount > 0 {
                    HStack(spacing: 4) {
                        Circle().fill(Color.green).frame(width: 6, height: 6)
                        Text("\(idleCount) idle").foregroundColor(.green)
                    }
                }
            }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(white: 0.13))
        .overlay(Divider().background(Color(white: 0.2)), alignment: .top)
    }
}
