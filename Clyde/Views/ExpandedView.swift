import SwiftUI
import AppKit

// MARK: - Colors & Labels (single source of truth)

enum SessionTheme {
    static let processingColor = Color.orange
    static let readyColor = Color.green
    static let processingLabel = "Processing"
    static let readyLabel = "Ready"

    static func color(for status: SessionStatus) -> Color {
        status == .busy ? processingColor : readyColor
    }

    static func label(for status: SessionStatus) -> String {
        status == .busy ? processingLabel : readyLabel
    }
}

// MARK: - Expanded View

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

            if sessionViewModel.sessions.isEmpty {
                EmptyStateView()
            } else {
                SessionListView(
                    sessions: sessionViewModel.sessions,
                    onRename: { id, name in
                        sessionViewModel.renameSession(id: id, to: name)
                    },
                    onFocus: { session in
                        appViewModel.focusSession(session)
                    }
                )
            }

            Spacer(minLength: 0)

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
    let onRename: (UUID, String) -> Void
    let onFocus: (Session) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(disambiguated, id: \.session.pid) { item in
                    SessionRow(
                        session: item.session,
                        disambiguator: item.suffix,
                        onRename: { name in onRename(item.session.id, name) },
                        onFocus: { onFocus(item.session) }
                    )
                    if item.session.pid != sessions.last?.pid {
                        Divider()
                            .background(Color(white: 0.15))
                            .padding(.leading, 52)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    /// Add numbered suffix for sessions sharing the same project name
    private var disambiguated: [(session: Session, suffix: String?)] {
        var counts: [String: Int] = [:]
        var indices: [String: Int] = [:]

        // Count duplicates
        for s in sessions {
            counts[s.displayName, default: 0] += 1
        }

        return sessions.map { session in
            let name = session.displayName
            if (counts[name] ?? 0) > 1 {
                indices[name, default: 0] += 1
                return (session, "#\(indices[name]!)")
            }
            return (session, nil)
        }
    }
}

// MARK: - Session Row

struct SessionRow: View {
    let session: Session
    let disambiguator: String?
    let onRename: (String) -> Void
    let onFocus: () -> Void

    @State private var isEditing = false
    @State private var editName = ""
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            SessionStatusIndicator(status: session.status)

            VStack(alignment: .leading, spacing: 3) {
                if isEditing {
                    HStack(spacing: 6) {
                        TextField("Session name", text: $editName, onCommit: {
                            onRename(editName)
                            isEditing = false
                        })
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color(white: 0.2))
                        .clipShape(RoundedRectangle(cornerRadius: 4))

                        Button(action: {
                            onRename(editName)
                            isEditing = false
                        }) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.green)
                                .frame(width: 20, height: 20)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Button(action: { isEditing = false }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.gray)
                                .frame(width: 20, height: 20)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    HStack(spacing: 6) {
                        Text(session.displayName)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.white)
                            .lineLimit(1)

                        if let suffix = disambiguator {
                            Text(suffix)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(Color(white: 0.35))
                        }

                        if isHovered {
                            Button(action: {
                                editName = session.customName ?? ""
                                isEditing = true
                            }) {
                                Image(systemName: "pencil")
                                    .font(.system(size: 9))
                                    .foregroundColor(Color(white: 0.35))
                                    .frame(width: 18, height: 18)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .transition(.opacity)
                        }
                    }
                }

                Text(session.workingDirectory.isEmpty ? "Unknown path" : abbreviatePath(session.workingDirectory))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Color(white: 0.4))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            if !isEditing {
                VStack(alignment: .trailing, spacing: 3) {
                    Text(SessionTheme.label(for: session.status))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(SessionTheme.color(for: session.status))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(SessionTheme.color(for: session.status).opacity(0.1))
                        .clipShape(Capsule())

                    Text(timeAgo(session.statusChangedAt))
                        .font(.system(size: 9))
                        .foregroundColor(Color(white: 0.35))
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(isHovered ? Color(white: 0.14) : Color.clear)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { onFocus() }
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

// MARK: - Session Status Indicator (animated mini Clyde)

struct SessionStatusIndicator: View {
    let status: SessionStatus

    @State private var bounce = false

    var body: some View {
        ZStack {
            // Background glow
            Circle()
                .fill(SessionTheme.color(for: status).opacity(0.1))
                .frame(width: 36, height: 36)

            if status == .busy {
                // Animated mini Clyde for processing
                ClydeAnimationView(state: .busy, pixelSize: 1.2)
                    .frame(width: 20, height: 20)
                    .offset(y: bounce ? -1 : 1)
                    .onAppear {
                        withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                            bounce = true
                        }
                    }
            } else {
                // Static checkmark-style idle indicator
                ClydeAnimationView(state: .idle, pixelSize: 1.2)
                    .frame(width: 20, height: 20)
            }
        }
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
                        StatusPill(count: busyCount, label: "processing", color: SessionTheme.processingColor, pulse: true)
                    }
                    if idleCount > 0 {
                        StatusPill(count: idleCount, label: "ready", color: SessionTheme.readyColor, pulse: false)
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
