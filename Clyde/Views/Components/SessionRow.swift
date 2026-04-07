import SwiftUI
import AppKit

// MARK: - Session Row

struct SessionRow: View {
    let session: Session
    let disambiguator: String?
    let onRename: (String) -> Void
    let onFocus: () -> Void
    let onReset: (() -> Void)?

    @State private var isEditing = false
    @State private var editName = ""
    @State private var isHovered = false
    @State private var stateFlash = false
    @State private var lastSeenStatus: SessionStatus?

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
                    if session.needsAttention {
                        HStack(spacing: 4) {
                            Image(systemName: "hand.tap.fill")
                                .font(.system(size: 8))
                            Text("Needs input")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundColor(.blue)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.blue.opacity(0.15))
                        .clipShape(Capsule())
                    } else {
                        Text(SessionTheme.label(for: session.status))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(SessionTheme.color(for: session.status))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(SessionTheme.color(for: session.status).opacity(0.1))
                            .clipShape(Capsule())
                    }

                    Text(timeAgo(session.statusChangedAt))
                        .font(.system(size: 9))
                        .foregroundColor(Color(white: 0.35))
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(stateFlash
                    ? SessionTheme.color(for: session.status).opacity(0.15)
                    : (isHovered ? Color(white: 0.14) : Color.clear))
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { onFocus() }
        .contextMenu {
            Button(action: { onFocus() }) {
                Label("Focus terminal", systemImage: "arrow.up.right.square")
            }
            Button(action: {
                editName = session.customName ?? ""
                isEditing = true
            }) {
                Label("Rename", systemImage: "pencil")
            }
            if let onReset {
                Divider()
                Button(role: .destructive, action: onReset) {
                    Label("Reset session state", systemImage: "arrow.counterclockwise")
                }
            }
        }
        .onChange(of: session.status) { newStatus in
            if lastSeenStatus != nil && lastSeenStatus != newStatus {
                // Flash the row on state change
                withAnimation(.easeIn(duration: 0.15)) {
                    stateFlash = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    withAnimation(.easeOut(duration: 0.5)) {
                        stateFlash = false
                    }
                }
            }
            lastSeenStatus = newStatus
        }
        .onAppear { lastSeenStatus = session.status }
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
