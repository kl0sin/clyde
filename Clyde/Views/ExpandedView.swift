import SwiftUI

struct ExpandedView: View {
    @ObservedObject var appViewModel: AppViewModel
    @ObservedObject var sessionViewModel: SessionListViewModel
    let onNewSession: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            TitleBar(
                clydeState: appViewModel.clydeState,
                onSettings: { appViewModel.showSettings = true },
                onCollapse: { appViewModel.toggleExpanded() }
            )

            // Terminal tabs
            TerminalTabBar(
                sessions: sessionViewModel.terminalSessions,
                selectedID: sessionViewModel.selectedSessionID ?? sessionViewModel.terminalSessions.first?.id,
                onSelect: { session in
                    sessionViewModel.selectSession(session)
                },
                onClose: { session in
                    sessionViewModel.closeSession(session)
                },
                onNewSession: onNewSession
            )

            // Terminal content
            if let session = sessionViewModel.selectedSession {
                TerminalContentView(session: session)
                    .id(session.id) // Force recreation on tab switch
            } else {
                VStack(spacing: 12) {
                    Text("No open terminals")
                        .foregroundColor(.gray)
                        .font(.system(size: 13))
                    Button("New Terminal") { onNewSession() }
                        .buttonStyle(.plain)
                        .foregroundColor(.purple)
                        .font(.system(size: 13, weight: .medium))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: NSColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1)))
            }

            // Status bar — shows Claude process monitoring info
            StatusBar(
                terminalCount: sessionViewModel.terminalSessions.count,
                claudeSessionCount: sessionViewModel.sessionCount,
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

            HStack(spacing: 4) {
                Button(action: onSettings) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12))
                        .foregroundColor(.gray)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button(action: onCollapse) {
                    Image(systemName: "minus")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.gray)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(white: 0.13))
    }
}

// Tab bar for terminal sessions
struct TerminalTabBar: View {
    let sessions: [TerminalSession]
    let selectedID: UUID?
    let onSelect: (TerminalSession) -> Void
    let onClose: (TerminalSession) -> Void
    let onNewSession: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(sessions) { session in
                        TerminalTab(
                            session: session,
                            isSelected: session.id == selectedID,
                            onClose: { onClose(session) }
                        )
                        .onTapGesture { onSelect(session) }
                    }
                }
            }

            Button(action: onNewSession) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.gray)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Divider().frame(height: 1).background(Color(white: 0.2))
        }
        .background(Color(white: 0.1))
        .overlay(
            Rectangle().frame(height: 1).foregroundColor(Color(white: 0.2)),
            alignment: .bottom
        )
    }
}

struct TerminalTab: View {
    @ObservedObject var session: TerminalSession
    let isSelected: Bool
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(session.isRunning ? Color.green : Color.gray)
                .frame(width: 6, height: 6)

            Text(session.title)
                .font(.system(size: 12))
                .foregroundColor(isSelected ? .white : .gray)
                .lineLimit(1)

            if isSelected {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.gray)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .background(isSelected ? Color(white: 0.17) : Color.clear)
        .overlay(
            Rectangle()
                .frame(height: 2)
                .foregroundColor(isSelected ? .purple : .clear),
            alignment: .bottom
        )
    }
}

struct StatusBar: View {
    let terminalCount: Int
    let claudeSessionCount: Int
    let busyCount: Int
    let idleCount: Int

    var body: some View {
        HStack {
            Text("\(terminalCount) tabs")
                .foregroundColor(.gray)

            Spacer()

            if claudeSessionCount > 0 {
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
        }
        .font(.system(size: 11))
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Color(white: 0.13))
        .overlay(
            Rectangle().frame(height: 1).foregroundColor(Color(white: 0.2)),
            alignment: .top
        )
    }
}
