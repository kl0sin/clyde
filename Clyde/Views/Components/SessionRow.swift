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
    let expandedSubagentSessions: Set<UUID>
    let onToggleSubagentExpansion: (UUID) -> Void

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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
        HStack(alignment: .top, spacing: 12) {
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
                        .accessibilityLabel("Session name")

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
                        .accessibilityLabel("Save name")

                        Button(action: { isEditing = false }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.gray)
                                .frame(width: 20, height: 20)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Cancel rename")
                    }
                } else {
                    // Reserve the pencil-button's height (18pt) so the row
                    // doesn't grow vertically when hover reveals the
                    // rename affordance. Without this the HStack jumps
                    // up by ~1–2pt as the pencil appears.
                    HStack(spacing: 6) {
                        Text(session.displayName)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white)
                            .lineLimit(1)

                        if let plan = session.activePlan {
                            PlanBadge(plan: plan)
                        }

                        if session.runtime == "cleat" {
                            CleatBadge(container: session.container)
                        }

                        if let suffix = disambiguator {
                            Text(suffix)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(TextColor.tertiary)
                        }

                        if isHovered {
                            Button(action: {
                                editName = session.customName ?? ""
                                isEditing = true
                            }) {
                                Image(systemName: "pencil")
                                    .font(.system(size: 9))
                                    .foregroundStyle(TextColor.tertiary)
                                    .frame(width: 18, height: 18)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .transition(.opacity)
                        }
                    }
                    .frame(minHeight: 18)
                }

                if session.activeSubagents.count >= 2 {
                    SubagentSummaryLine(session: session)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(
                            "\(session.activeSubagents.count) agents running"
                        )
                        .accessibilityAddTraits(.updatesFrequently)
                } else {
                    ZStack(alignment: .leading) {
                        if let tool = session.activeTool, let label = session.toolDisplayLabel {
                            TimelineView(.periodic(from: tool.startedAt, by: 1)) { context in
                                Text("\(label) · \(formatDuration(from: tool.startedAt, now: context.date))")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(Color(white: 0.65))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                            .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                        } else {
                            Text(session.workingDirectory.isEmpty
                                 ? "Unknown path"
                                 : abbreviatePath(session.workingDirectory))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(TextColor.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                        }
                    }
                    .frame(height: 14, alignment: .leading)
                    .clipped()
                    // Bool trigger: back-to-back tools skip the slide (tool
                    // identity changes but both states stay non-nil).
                    // Intentional — rapid tool chaining would look jittery
                    // with double slides.
                    .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.85),
                               value: session.activeTool != nil)
                    .coachmarkAnchor(.toolPlan, identity: AnyHashable(session.id))
                }
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

        if session.activeSubagents.count >= 2 {
            SubagentList(
                session: session,
                isExpanded: expandedSubagentSessions.contains(session.id),
                onToggle: { onToggleSubagentExpansion(session.id) }
            )
            // Align under the title: mascot (34) + HStack spacing (12).
            .padding(.leading, 46)
            .padding(.top, 4)
            .transition(reduceMotion
                ? .opacity
                : .asymmetric(
                    insertion: .opacity.combined(with: .move(edge: .top)),
                    removal: .opacity))
            .animation(reduceMotion
                ? .easeInOut(duration: 0.12)
                : .spring(response: 0.28, dampingFraction: 0.85),
                value: session.activeSubagents.map(\.id))
        }
        }
        .opacity(session.isGhost ? 0.55 : 1.0)
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
        .background(
            RoundedRectangle(cornerRadius: Radius.medium)
                .fill(rowBackground)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { onFocus() }
        .accessibilityElement(children: isEditing ? .contain : .combine)
        .accessibilityLabel(isEditing ? "" : rowAccessibilityLabel)
        .accessibilityHint(isEditing ? "" : "Double-tap to focus terminal")
        .accessibilityAddTraits(isEditing ? [] : .isButton)
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
                // Flash the row on state change. One easeInOut curve in
                // each direction reads as a single calm pulse — the old
                // split (.easeIn 0.15 → hold 0.65 → .easeOut 0.5) felt
                // jittery because the on/off curves didn't match.
                if reduceMotion {
                    stateFlash = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        stateFlash = false
                    }
                } else {
                    withAnimation(.easeInOut(duration: 0.35)) {
                        stateFlash = true
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
                        withAnimation(.easeInOut(duration: 0.35)) {
                            stateFlash = false
                        }
                    }
                }
            }
            lastSeenStatus = newStatus
        }
        .onAppear {
            lastSeenStatus = session.status
            if !reduceMotion {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    pillPulse = true
                }
            }
        }
        .coachmarkAnchor(.sessionRow, identity: AnyHashable(session.id))
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

    /// Composed VoiceOver label for the row. The previous label was just
    /// "<name>, <status>" which dropped the active-tool line and the
    /// plan-progress badge from the audible read-out. We rebuild it from
    /// the same surface signals a sighted user sees: name, status, the
    /// running tool with elapsed seconds, and plan progress when there's
    /// a non-empty plan.
    private var rowAccessibilityLabel: String {
        let nameAlreadyMentionsSession = session.displayName
            .range(of: "session", options: .caseInsensitive) != nil
        let nameWithRole = nameAlreadyMentionsSession
            ? session.displayName
            : "\(session.displayName) session"
        var parts: [String] = [nameWithRole, accessibilityStatusDescription]

        if session.activeSubagents.count >= 2 {
            parts.append("\(session.activeSubagents.count) agents running")
        } else if let tool = session.activeTool, let label = session.toolDisplayLabel {
            let elapsed = max(0, Int(Date().timeIntervalSince(tool.startedAt)))
            let elapsedStr = elapsed == 1 ? "1 second elapsed" : "\(elapsed) seconds elapsed"
            parts.append("\(label), \(elapsedStr)")
        }

        if let plan = session.activePlan, plan.taskCount > 0 {
            if plan.isComplete {
                parts.append("plan complete, \(plan.doneCount) of \(plan.taskCount) tasks")
            } else {
                parts.append("plan \(plan.doneCount) of \(plan.taskCount) tasks complete")
            }
        }

        return parts.joined(separator: ", ")
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
        return TextColor.tertiary
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
        } else if let errorText = session.errorDisplayText {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 8))
                Text(errorText)
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(SessionTheme.errorColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(SessionTheme.errorColor.opacity(0.15))
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

    /// Human-readable elapsed time for the active-tool indicator.
    /// Mirrors `timeAgo`'s style but trims to "Ns" / "Nm" / "Nm Ns" so
    /// the second line stays compact even on a 90s Bash command.
    private func formatDuration(from start: Date, now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(start)))
        if s < 60 { return "\(s)s" }
        let m = s / 60
        let r = s % 60
        return r == 0 ? "\(m)m" : "\(m)m \(r)s"
    }
}

// MARK: - Plan Progress Badge

/// Inline badge that surfaces TaskCreated / TaskCompleted progress on
/// the session row's name line. Purple while in progress, green ✓ on
/// completion. The fixed-width 24pt progress bar prevents the badge
/// from changing width as digit counts grow (1/9 → 9/9 stays the same).
private struct PlanBadge: View {
    let plan: ActivePlan

    var body: some View {
        HStack(spacing: 4) {
            Text(plan.isComplete ? "✓" : "📋")
                .font(.system(size: 9))
            Text("\(plan.doneCount)/\(plan.taskCount)")
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .monospacedDigit()
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(accent.opacity(0.25))
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(accent)
                    .frame(width: 24 * plan.progress)
            }
            .frame(width: 24, height: 3)
        }
        .foregroundStyle(accent)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(accent.opacity(0.12))
        .clipShape(Capsule())
        // Lock the badge to its intrinsic width so the parent HStack
        // truncates `session.displayName` (which has lineLimit(1) and
        // no layout priority) before it ever squeezes the badge. Without
        // this, long project names eat into the badge's horizontal space
        // and the icon + counter render visibly clipped on the right edge.
        .fixedSize(horizontal: true, vertical: false)
        .animation(.easeInOut(duration: 0.25), value: plan.doneCount)
        .animation(.easeInOut(duration: 0.25), value: plan.isComplete)
        .accessibilityHidden(true)
    }

    private var accent: Color {
        plan.isComplete
            ? Color(red: 0.47, green: 0.78, blue: 0.55)   // soft green
            : Color(red: 0.71, green: 0.55, blue: 0.86)   // soft purple
    }
}

// MARK: - Cleat Runtime Badge

/// Small capsule next to the project name showing that the session
/// runs inside a Cleat Docker sandbox. The container name is exposed
/// via `.help` so hover reveals which container the session belongs
/// to — useful when several cleat projects are running in parallel.
private struct CleatBadge: View {
    let container: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "shippingbox")
                .font(.system(size: 9, weight: .semibold))
            Text("cleat")
                .font(.system(size: 9, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(accent)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(accent.opacity(0.12))
        .clipShape(Capsule())
        // See PlanBadge for the same reasoning — the parent HStack
        // would otherwise truncate this badge before truncating
        // `session.displayName`.
        .fixedSize(horizontal: true, vertical: false)
        .help(container.isEmpty ? "Cleat sandbox" : container)
        .accessibilityLabel("Cleat sandbox")
    }

    private var accent: Color {
        // Soft cyan — distinct from the purple PlanBadge so they read
        // as separate badges when both are present.
        Color(red: 0.45, green: 0.75, blue: 0.85)
    }
}

// MARK: - Subagent Summary Line

private struct SubagentSummaryLine: View {
    let session: Session

    private func formatElapsed(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        let m = seconds / 60
        let r = seconds % 60
        return r == 0 ? "\(m)m" : "\(m)m \(r)s"
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let oldest = session.activeSubagents.first?.startedAt ?? ctx.date
            let elapsed = max(0, Int(ctx.date.timeIntervalSince(oldest)))
            HStack(spacing: 4) {
                Text("\(session.activeSubagents.count) agents")
                Text("·")
                Text(formatElapsed(elapsed))
                    .monospacedDigit()
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(Color(white: 0.65))
        }
    }
}

// MARK: - Subagent List

private struct SubagentList: View {
    let session: Session
    let isExpanded: Bool
    let onToggle: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Soft lavender, matching PlanBadge's in-progress accent so the
    // subagent affordance reads as the same visual language.
    private let accent = Color(red: 0.71, green: 0.55, blue: 0.86)

    private var visible: [ActiveSubagent] {
        isExpanded ? session.activeSubagents : Array(session.activeSubagents.prefix(3))
    }

    private var overflowCount: Int {
        max(0, session.activeSubagents.count - 3)
    }

    private func formatElapsed(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        let m = seconds / 60
        let r = seconds % 60
        return r == 0 ? "\(m)m" : "\(m)m \(r)s"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(visible) { agent in
                agentRow(for: agent)
            }
            if overflowCount > 0 || isExpanded {
                expandLabel
            }
        }
        .padding(.leading, 8)
        .padding(.vertical, 2)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(accent.opacity(0.55))
                .frame(width: 2)
        }
        .padding(.top, 6)
        .padding(.leading, 2)
    }

    @ViewBuilder
    private func agentRow(for agent: ActiveSubagent) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let elapsed = max(0, Int(ctx.date.timeIntervalSince(agent.startedAt)))
            HStack(alignment: .top, spacing: 6) {
                ClydeAnimationView(state: .busy, pixelSize: 0.75, ambientIdleEnabled: false)
                    .frame(width: 12, height: 12)
                    .padding(.top, 1)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    HStack {
                        Text(agent.type)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(accent)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(formatElapsed(elapsed))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Color(white: 0.55))
                            .monospacedDigit()
                    }
                    if !agent.summary.isEmpty {
                        Text(agent.summary)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Color(white: 0.45))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(agent.type), \(agent.summary), running \(formatElapsed(elapsed))")
            .accessibilityAddTraits(.updatesFrequently)
        }
    }

    @ViewBuilder
    private var expandLabel: some View {
        Button(action: onToggle) {
            Text(isExpanded ? "▴ Show less" : "+ \(overflowCount) more agents")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(isExpanded ? AnyShapeStyle(Color(white: 0.55)) : AnyShapeStyle(accent))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(isExpanded ? "Show less" : "\(overflowCount) more agents")
        .accessibilityHint(isExpanded
            ? "Double-tap to collapse the subagent list"
            : "Double-tap to expand the subagent list")
    }
}

// MARK: - Session Status Indicator (animated mini Clyde)

struct SessionStatusIndicator: View {
    let session: Session
    /// Slot number for idle sessions. Nil → render the active sprite.
    let idleIndex: Int?

    @State private var bounce = false
    @State private var attentionPulse = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                .frame(width: 34, height: 34)
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(
                    isActive
                        ? accent.opacity(session.needsAttention && attentionPulse ? 0.65 : 0.55)
                        : Color(white: 0.18),
                    lineWidth: isActive ? 1.5 : 1
                )
                .frame(width: 34, height: 34)

            if isActive {
                // Active session: full sprite. The busy scale beat is
                // driven by a TimelineView (frame-locked) so the
                // animation always runs reliably — SwiftUI's
                // withAnimation/.repeatForever in onAppear has been
                // unreliable for newly-appearing rows.
                let mascotState: ClydeState = session.needsAttention ? .attention : .busy
                if session.status == .busy && !session.needsAttention {
                    TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                        let t = context.date.timeIntervalSinceReferenceDate
                        let phase: Double = reduceMotion ? 0 : (sin(t * .pi * 2 / 1.4) + 1) / 2  // 0…1, 1.4s cycle
                        let scale = 1.0 + phase * 0.12               // 1.0 … 1.12
                        ClydeAnimationView(state: mascotState, pixelSize: 1.5, ambientIdleEnabled: false)
                            .frame(width: 24, height: 24)
                            .scaleEffect(scale, anchor: .center)
                    }
                    .frame(width: 24, height: 24)
                } else {
                    ClydeAnimationView(state: mascotState, pixelSize: 1.5, ambientIdleEnabled: false)
                        .frame(width: 24, height: 24)
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
                    .foregroundStyle(TextColor.tertiary)
            }
        }
        .onAppear {
            if reduceMotion {
                if session.status == .busy { bounce = true }
                if session.needsAttention { attentionPulse = true }
            } else {
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
        }
        .accessibilityHidden(true)
    }
}
