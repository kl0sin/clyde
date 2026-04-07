import SwiftUI
import AppKit

// MARK: - Session Row

struct SessionRow: View {
    let session: Session
    let disambiguator: String?
    /// Position among idle (non-ghost, non-busy, non-attention) sessions,
    /// used for the slot number on the left. Nil for active sessions.
    let idleIndex: Int?
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
            SessionStatusIndicator(session: session, idleIndex: idleIndex)

            VStack(alignment: .leading, spacing: 3) {
                if isEditing {
                    HStack(spacing: 6) {
                        TextField("Session name", text: $editName, onCommit: {
                            onRename(editName)
                            isEditing = false
                        })
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
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
                                .foregroundStyle(.green)
                                .frame(width: 20, height: 20)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Button(action: { isEditing = false }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.gray)
                                .frame(width: 20, height: 20)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    HStack(spacing: 6) {
                        Text(session.displayName)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white)
                            .lineLimit(1)

                        if let suffix = disambiguator {
                            Text(suffix)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Color(white: 0.35))
                        }

                        if isHovered {
                            Button(action: {
                                editName = session.customName ?? ""
                                isEditing = true
                            }) {
                                Image(systemName: "pencil")
                                    .font(.system(size: 9))
                                    .foregroundStyle(Color(white: 0.35))
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
                    .foregroundStyle(Color(white: 0.4))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            if !isEditing {
                VStack(alignment: .trailing, spacing: 3) {
                    if showsStatusPill {
                        statusPill(for: session)
                    }

                    Text(timeAgo(session.endedAt ?? session.statusChangedAt))
                        .font(.system(size: 9))
                        .foregroundStyle(timeColor)
                }
            }
        }
        .opacity(session.isGhost ? 0.55 : 1.0)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(rowBackground)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { onFocus() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(session.displayName), \(accessibilityStatusDescription)")
        .accessibilityHint("Double-tap to focus terminal")
        .accessibilityAddTraits(.isButton)
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

    /// Pill is shown for active states (busy / attention) and ghosts.
    /// Idle ready sessions are silent — the slot number on the left and
    /// the dimmed time stamp carry the state.
    private var showsStatusPill: Bool {
        if session.isGhost { return true }
        if session.needsAttention { return true }
        if session.status == .busy { return true }
        return false
    }

    private var isActive: Bool {
        !session.isGhost && (session.needsAttention || session.status == .busy)
    }

    private var rowBackground: Color {
        if stateFlash {
            return SessionTheme.color(for: session.status).opacity(0.15)
        }
        if isHovered { return Color(white: 0.14) }
        if isActive {
            let tint: Color = session.needsAttention
                ? SessionTheme.attentionColor
                : SessionTheme.processingColor
            return tint.opacity(0.07)
        }
        return Color.clear
    }

    private var accessibilityStatusDescription: String {
        if session.isGhost { return "ended" }
        if session.needsAttention { return "needs your input" }
        if session.status == .busy { return "working" }
        return "ready, idle"
    }

    private var timeColor: Color {
        if session.needsAttention { return SessionTheme.attentionColor }
        if session.status == .busy { return SessionTheme.processingColor }
        return Color(white: 0.3)
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
            .foregroundStyle(Color(white: 0.5))
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
            .foregroundStyle(SessionTheme.attentionColor)
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
            .foregroundStyle(SessionTheme.processingColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(SessionTheme.processingColor.opacity(0.12))
            .clipShape(Capsule())
        } else {
            // Ready
            Text(SessionTheme.readyLabel)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(SessionTheme.readyColor)
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
    /// Slot number for idle sessions. Nil → render the active sprite.
    let idleIndex: Int?

    @State private var bounce = false
    @State private var orbitAngle: Double = 0
    @State private var attentionPulse = false

    private var isActive: Bool {
        !session.isGhost && (session.needsAttention || session.status == .busy)
    }

    private var accent: Color {
        if session.needsAttention { return SessionTheme.attentionColor }
        if session.status == .busy { return SessionTheme.processingColor }
        return Color(white: 0.25)
    }

    var body: some View {
        ZStack {
            // Squircle base — same shape as the header sprite.
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isActive ? accent.opacity(0.18) : Color(white: 0.11))
                .frame(width: 36, height: 36)
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(
                    isActive
                        ? accent.opacity(session.needsAttention && attentionPulse ? 0.65 : 0.55)
                        : Color(white: 0.18),
                    lineWidth: isActive ? 1.5 : 1
                )
                .frame(width: 36, height: 36)

            if isActive {
                // Active session: full sprite + accents.
                let mascotState: ClydeState = session.needsAttention ? .attention : .busy
                ClydeAnimationView(state: mascotState, pixelSize: 1.2)
                    .frame(width: 20, height: 20)
                    .offset(y: (session.status == .busy && bounce) ? -1 : 1)

                if session.status == .busy && !session.needsAttention {
                    Circle()
                        .fill(SessionTheme.processingColor)
                        .frame(width: 4, height: 4)
                        .shadow(color: SessionTheme.processingColor, radius: 3)
                        .offset(x: cos(orbitAngle) * 15, y: sin(orbitAngle) * 15)
                }

                if session.needsAttention {
                    Circle()
                        .fill(SessionTheme.attentionColor)
                        .frame(width: 12, height: 12)
                        .overlay(
                            Text("!")
                                .font(.system(size: 9, weight: .heavy, design: .rounded))
                                .foregroundStyle(.white)
                        )
                        .offset(x: 13, y: -13)
                        .scaleEffect(attentionPulse ? 1.1 : 0.92)
                }
            } else {
                // Idle: numbered slot. Two-digit format keeps width stable.
                Text(String(format: "%02d", idleIndex ?? 0))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(white: 0.42))
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
