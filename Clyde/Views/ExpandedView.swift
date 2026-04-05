import SwiftUI

struct ExpandedView: View {
    @ObservedObject var appViewModel: AppViewModel
    @ObservedObject var sessionViewModel: SessionListViewModel

    var body: some View {
        VStack(spacing: 0) {
            TitleBar(
                clydeState: appViewModel.clydeState,
                onSettings: { appViewModel.showSettings = true },
                onCollapse: { appViewModel.toggleExpanded() }
            )

            // Session list
            if sessionViewModel.sessions.isEmpty {
                EmptyStateView()
            } else {
                SessionListView(
                    sessions: sessionViewModel.sessions,
                    onRename: { path, name in
                        sessionViewModel.renameSession(workingDirectory: path, to: name)
                    }
                )
            }

            Spacer(minLength: 0)

            // Summary bar
            SummaryBar(
                sessionCount: sessionViewModel.sessionCount,
                busyCount: sessionViewModel.busyCount,
                idleCount: sessionViewModel.idleCount,
                clydeState: appViewModel.clydeState
            )
        }
        .background(Color(nsColor: NSColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1)))
    }
}

// MARK: - Title Bar

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
        .overlay(
            Rectangle().frame(height: 1).foregroundColor(Color(white: 0.2)),
            alignment: .bottom
        )
    }
}

// MARK: - Session List

struct SessionListView: View {
    let sessions: [Session]
    let onRename: (String, String) -> Void  // (workingDirectory, newName)

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(sessions, id: \.pid) { session in
                    SessionRow(session: session, onRename: { name in
                        onRename(session.workingDirectory, name)
                    })
                    if session.pid != sessions.last?.pid {
                        Divider()
                            .background(Color(white: 0.15))
                            .padding(.leading, 52)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }
}

struct SessionRow: View {
    let session: Session
    let onRename: (String) -> Void

    @State private var isEditing = false
    @State private var editName = ""

    var body: some View {
        HStack(spacing: 12) {
            // Status indicator
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.15))
                    .frame(width: 32, height: 32)

                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
            }

            // Project info
            VStack(alignment: .leading, spacing: 3) {
                if isEditing {
                    TextField("Session name", text: $editName, onCommit: {
                        onRename(editName)
                        isEditing = false
                    })
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                } else {
                    Text(session.displayName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .onTapGesture(count: 2) {
                            editName = session.customName ?? ""
                            isEditing = true
                        }
                }

                Text(session.workingDirectory.isEmpty ? "Unknown path" : abbreviatePath(session.workingDirectory))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Color(white: 0.4))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            // Status badge + time
            VStack(alignment: .trailing, spacing: 3) {
                HStack(spacing: 5) {
                    if session.status == .busy {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 12, height: 12)
                    }

                    Text(statusLabel)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(statusColor)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(statusColor.opacity(0.1))
                .clipShape(Capsule())

                Text(timeAgo(session.statusChangedAt))
                    .font(.system(size: 9))
                    .foregroundColor(Color(white: 0.35))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private var statusColor: Color {
        session.status == .busy ? .orange : .green
    }

    private var statusLabel: String {
        session.status == .busy ? "Processing" : "Ready"
    }

    private func abbreviatePath(_ path: String) -> String {
        path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private func timeAgo(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        return "\(hours)h \(minutes % 60)m"
    }
}

// MARK: - Empty State

struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 12) {
            ClydeAnimationView(state: .sleeping, pixelSize: 2.5)
                .frame(width: 40, height: 40)

            Text("No Claude sessions")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Color(white: 0.5))

            Text("Start claude in any terminal\nand Clyde will detect it")
                .font(.system(size: 11))
                .foregroundColor(Color(white: 0.35))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

// MARK: - Summary Bar

struct SummaryBar: View {
    let sessionCount: Int
    let busyCount: Int
    let idleCount: Int
    let clydeState: ClydeState

    var body: some View {
        HStack(spacing: 10) {
            ClydeAnimationView(state: clydeState, pixelSize: 0.75)
                .frame(width: 12, height: 12)

            if sessionCount > 0 {
                HStack(spacing: 6) {
                    if busyCount > 0 {
                        StatusPill(count: busyCount, label: "processing", color: .red, pulse: true)
                    }
                    if idleCount > 0 {
                        StatusPill(count: idleCount, label: "ready", color: .green, pulse: false)
                    }
                }
            } else {
                Text("Waiting for sessions...")
                    .font(.system(size: 10))
                    .foregroundColor(Color(white: 0.4))
            }

            Spacer()

            if sessionCount > 0 {
                Text("\(sessionCount) \(sessionCount == 1 ? "session" : "sessions")")
                    .font(.system(size: 10))
                    .foregroundColor(Color(white: 0.4))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(white: 0.11))
        .overlay(
            Rectangle().frame(height: 1).foregroundColor(Color(white: 0.18)),
            alignment: .top
        )
    }
}

struct StatusPill: View {
    let count: Int
    let label: String
    let color: Color
    let pulse: Bool

    @State private var isPulsing = false

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
                .opacity(pulse && isPulsing ? 0.4 : 1.0)

            Text("\(count) \(label)")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(color.opacity(0.9))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color.opacity(0.1))
        .clipShape(Capsule())
        .onAppear {
            if pulse {
                withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                    isPulsing = true
                }
            }
        }
    }
}
