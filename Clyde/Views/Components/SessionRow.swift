import SwiftUI
import AppKit

// MARK: - Session Row

struct SessionRow: View {
    let session: Session
    let disambiguator: String?
    let onRename: (String) -> Void
    let onFocus: () -> Void
    let onReset: (() -> Void)?
    let notificationService: NotificationService?

    static let availableSounds = [
        "Glass", "Blow", "Bottle", "Frog", "Funk", "Hero",
        "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink"
    ]

    @State private var isEditing = false
    @State private var editName = ""
    @State private var isHovered = false
    @State private var stateFlash = false
    @State private var lastSeenStatus: SessionStatus?
    /// Drives the ambient pulse on busy / attention status pills.
    @State private var pillPulse = false

    var body: some View {
        HStack(spacing: 12) {
            SessionStatusIndicator(session: session)

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
                    statusPill(for: session)

                    Text(timeAgo(session.endedAt ?? session.statusChangedAt))
                        .font(.system(size: 9))
                        .foregroundColor(Color(white: 0.35))
                }
            }
        }
        .opacity(session.isGhost ? 0.55 : 1.0)
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

            if let notificationService, let sid = session.sessionId {
                Divider()
                Menu("Ready sound") {
                    soundMenuItems(
                        current: notificationService.perSessionReadySound[sid],
                        defaultSound: notificationService.readySound
                    ) { choice in
                        notificationService.setReadySound(choice, forSessionId: sid)
                    }
                }
                Menu("Attention sound") {
                    soundMenuItems(
                        current: notificationService.perSessionAttentionSound[sid],
                        defaultSound: notificationService.attentionSound
                    ) { choice in
                        notificationService.setAttentionSound(choice, forSessionId: sid)
                    }
                }
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
        .onAppear {
            lastSeenStatus = session.status
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                pillPulse = true
            }
        }
    }

    /// Status pill on the right of the row. Ghost and ready are static.
    /// Busy and attention pulse a leading dot so the row visually "breathes"
    /// in sync with the widget.
    @ViewBuilder
    private func statusPill(for session: Session) -> some View {
        if session.isGhost {
            HStack(spacing: 4) {
                Image(systemName: "moon.zzz.fill")
                    .font(.system(size: 8))
                Text("Ended")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundColor(Color(white: 0.5))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color(white: 0.18))
            .clipShape(Capsule())
        } else if session.needsAttention {
            HStack(spacing: 5) {
                Circle()
                    .fill(SessionTheme.attentionColor)
                    .frame(width: 6, height: 6)
                    .opacity(pillPulse ? 0.4 : 1.0)
                    .shadow(color: SessionTheme.attentionColor.opacity(pillPulse ? 0.0 : 0.8), radius: pillPulse ? 0 : 4)
                Text(SessionTheme.attentionLabel)
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundColor(SessionTheme.attentionColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(SessionTheme.attentionColor.opacity(0.15))
            .clipShape(Capsule())
        } else if session.status == .busy {
            HStack(spacing: 5) {
                Circle()
                    .fill(SessionTheme.processingColor)
                    .frame(width: 6, height: 6)
                    .opacity(pillPulse ? 0.4 : 1.0)
                    .shadow(color: SessionTheme.processingColor.opacity(pillPulse ? 0.0 : 0.7), radius: pillPulse ? 0 : 3)
                Text(SessionTheme.processingLabel)
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundColor(SessionTheme.processingColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(SessionTheme.processingColor.opacity(0.12))
            .clipShape(Capsule())
        } else {
            // Ready
            Text(SessionTheme.readyLabel)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(SessionTheme.readyColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(SessionTheme.readyColor.opacity(0.1))
                .clipShape(Capsule())
        }
    }

    private func abbreviatePath(_ path: String) -> String {
        path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    @ViewBuilder
    private func soundMenuItems(
        current: String?,
        defaultSound: String,
        select: @escaping (String?) -> Void
    ) -> some View {
        Button(action: { select(nil) }) {
            HStack {
                if current == nil { Image(systemName: "checkmark") }
                Text("Use default (\(defaultSound))")
            }
        }
        Divider()
        ForEach(Self.availableSounds, id: \.self) { sound in
            Button(action: {
                select(sound)
                NSSound(named: NSSound.Name(sound))?.play()
            }) {
                HStack {
                    if current == sound { Image(systemName: "checkmark") }
                    Text(sound)
                }
            }
        }
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
    let session: Session

    @State private var bounce = false
    @State private var orbitAngle: Double = 0
    @State private var attentionPulse = false

    private var halo: Color {
        if session.needsAttention { return SessionTheme.attentionColor }
        return SessionTheme.color(for: session.status)
    }

    var body: some View {
        ZStack {
            // Halo background — coloured per dominant state, subtle tint.
            Circle()
                .fill(halo.opacity(0.14))
                .frame(width: 36, height: 36)
            Circle()
                .strokeBorder(halo.opacity(session.needsAttention && attentionPulse ? 0.55 : 0.22), lineWidth: 1)
                .frame(width: 36, height: 36)

            // Mini Clyde — ClydeAnimationView uses the wider ClydeState
            // enum so we map from the per-session SessionStatus here.
            let mascotState: ClydeState = {
                if session.needsAttention { return .attention }
                return session.status == .busy ? .busy : .idle
            }()
            ClydeAnimationView(state: mascotState, pixelSize: 1.2)
                .frame(width: 20, height: 20)
                .offset(y: (session.status == .busy && bounce) ? -1 : 1)

            // Busy accent: small orbiting purple dot around the mascot.
            if session.status == .busy && !session.needsAttention {
                Circle()
                    .fill(SessionTheme.processingColor)
                    .frame(width: 4, height: 4)
                    .shadow(color: SessionTheme.processingColor, radius: 3)
                    .offset(x: cos(orbitAngle) * 15, y: sin(orbitAngle) * 15)
            }

            // Attention accent: yellow "!" badge in top-right corner.
            if session.needsAttention {
                Circle()
                    .fill(SessionTheme.attentionColor)
                    .frame(width: 12, height: 12)
                    .overlay(
                        Text("!")
                            .font(.system(size: 9, weight: .heavy, design: .rounded))
                            .foregroundColor(.white)
                    )
                    .offset(x: 13, y: -13)
                    .scaleEffect(attentionPulse ? 1.1 : 0.92)
            }
        }
        .onAppear {
            if session.status == .busy {
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                    bounce = true
                }
            }
            if session.needsAttention {
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                    attentionPulse = true
                }
            }
        }
        .task(id: session.status == .busy && !session.needsAttention) {
            // Continuous orbit while busy — driven by a dedicated loop so
            // it survives view re-renders and restarts cleanly on status
            // transitions.
            guard session.status == .busy, !session.needsAttention else { return }
            let start = Date()
            while !Task.isCancelled {
                let elapsed = Date().timeIntervalSince(start)
                orbitAngle = (elapsed / 2.0) * .pi * 2  // 2s per full orbit
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }
}
