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
    /// Permission requests this session is waiting on. Empty unless the
    /// user turned panel answering on.
    var permissionRequests: [PermissionRequest] = []
    var onPermissionDecision: ((PermissionRequest, PermissionDecision) -> Void)?

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

            // Bounded, or the second line pushes the elapsed time off
            // the panel's edge: an unconstrained column asks for the
            // width its longest text wants, and a tool summary can be
            // any length at all.
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

                        if let command = session.activeCommand {
                            CommandBadge(name: command)
                        }

                        if !session.worktreeName.isEmpty {
                            WorktreeBadge(name: session.worktreeName)
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

                // One agent counts. This was `>= 2` because the legacy
                // -subagent marker carried the single-agent case; v0.7.0
                // retired that marker and left one agent showing nothing.
                if let agentsLabel = session.activeAgentsLabel {
                    // Agents replaced the tool line wholesale, so a
                    // session with agents was the one working state
                    // that said nothing about what it is doing.
                    HStack(spacing: 5) {
                        MicroLabel(text: session.activeTool?.toolName ?? "working",
                                   color: SessionTheme.processingColor)
                        SubagentSummaryLine(session: session)
                    }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(agentsLabel) running")
                        .accessibilityAddTraits(.updatesFrequently)
                } else {
                    ZStack(alignment: .leading) {
                        if let tool = session.activeTool, let label = session.toolDisplayLabel {
                            TimelineView(.periodic(from: tool.startedAt, by: 1)) { context in
                                // A batch of parallel calls reads as a count:
                                // naming one of several is arbitrary and was
                                // what made the single-slot marker misleading.
                                let text = session.activeToolCount >= 2
                                    ? "\(session.activeToolCount) tools"
                                    : label
                                // Opens with the same micro-label the
                                // compact row uses, so a session states
                                // what it is doing in one voice
                                // whichever mode is open. What follows
                                // is the detail compact has no room for.
                                HStack(spacing: 5) {
                                    MicroLabel(text: tool.toolName,
                                               color: SessionTheme.processingColor)
                                    Text(detail(after: tool.toolName, in: text) +
                                         " · \(formatDuration(from: tool.startedAt, now: context.date))")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(Color(white: 0.65))
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                        // The detail is what gives way
                                        // when the row runs out of
                                        // width — not the elapsed time,
                                        // which is a fixed, small and
                                        // frequently read figure.
                                        .layoutPriority(-1)
                                }
                            }
                            .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                        } else if session.needsAttention {
                            HStack(spacing: 5) {
                                MicroLabel(text: "needs you",
                                           color: SessionTheme.attentionColor)
                                Text(abbreviatePath(session.workingDirectory))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(TextColor.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        } else if session.status == .idle, let reply = session.lastMessage {
                            // An idle session has nothing live to report, so
                            // the last thing Claude said is more use than the
                            // path — which is already on the row above.
                            HStack(spacing: 5) {
                                MicroLabel(text: "waiting", color: TextColor.tertiary)
                                Text("› \(reply)")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(TextColor.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                            .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                        } else {
                            HStack(spacing: 5) {
                                MicroLabel(text: session.status == .busy ? "working" : "waiting",
                                           color: session.status == .busy
                                               ? SessionTheme.processingColor
                                               : TextColor.tertiary)
                                Text(session.workingDirectory.isEmpty
                                     ? "Unknown path"
                                     : abbreviatePath(session.workingDirectory))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(TextColor.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
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

            // Greedy on its own — a Spacer beside it asked for the
            // width twice over, and the elapsed figure was what got
            // pushed off the edge.
            .frame(maxWidth: .infinity, alignment: .leading)

            if !isEditing {
                // A fixed lane rather than a negotiated one: the
                // elapsed figure is small, frequently read and never
                // longer than "10h 20m", and letting it compete with a
                // tool summary of arbitrary length pushed it off the
                // panel's edge.
                VStack(alignment: .trailing, spacing: 3) {
                    Text(timeAgo(session.endedAt ?? session.statusChangedAt))
                        .font(.system(size: 9))
                        .foregroundStyle(timeColor)
                        .fixedSize()
                }
                .frame(width: 46, alignment: .trailing)
            }
        }

        // The question goes under the session that asked it: answering
        // the wrong row would run the wrong command.
        ForEach(permissionRequests.filter {
            PermissionRequestRow.shows(request: $0, inRowFor: session.pid)
        }) { request in
            PermissionRequestRow(request: request) { decision in
                onPermissionDecision?(request, decision)
            }
            // Align under the title: mascot (34) + HStack spacing (12).
            .padding(.leading, 46)
            .padding(.top, 4)
            .transition(reduceMotion ? .opacity
                                     : .opacity.combined(with: .move(edge: .top)))
        }

        if !session.activeSubagents.isEmpty {
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

        if let agentsLabel = session.activeAgentsLabel {
            parts.append("\(agentsLabel) running")
        } else if let tool = session.activeTool, let label = session.toolDisplayLabel {
            let elapsed = max(0, Int(Date().timeIntervalSince(tool.startedAt)))
            let elapsedStr = elapsed == 1 ? "1 second elapsed" : "\(elapsed) seconds elapsed"
            let what = session.activeToolCount >= 2
                ? "\(session.activeToolCount) tools running"
                : label
            parts.append("\(what), \(elapsedStr)")
        } else if session.status == .idle, let reply = session.lastMessage {
            parts.append("last reply, \(reply)")
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
    /// The tool label without its leading tool name — the micro-label
    /// now carries that, and printing it twice was the redundancy this
    /// change removes.
    private func detail(after toolName: String, in label: String) -> String {
        let prefix = "\(toolName) · "
        return label.hasPrefix(prefix) ? String(label.dropFirst(prefix.count)) : label
    }

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
/// Names the git worktree a session is working inside — otherwise the
/// row shows an opaque `.claude/worktrees/…` path and nothing else.
private struct WorktreeBadge: View {
    let name: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 9, weight: .semibold))
            Text(name)
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .lineLimit(1)
        }
        .foregroundStyle(accent)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(accent.opacity(0.12))
        .clipShape(Capsule())
        .fixedSize(horizontal: true, vertical: false)
        .help("Worktree \(name)")
        .accessibilityLabel("worktree \(name)")
    }

    private var accent: Color {
        // Soft green — the fourth badge colour, distinct from the purple
        // plan, cyan cleat and amber command capsules.
        Color(red: 0.55, green: 0.80, blue: 0.60)
    }
}

/// The slash command driving the current turn. Long autonomous runs
/// (`/loop`, `/code-review`) otherwise render as an anonymous "Working".
private struct CommandBadge: View {
    let name: String

    var body: some View {
        Text("/\(name)")
            .font(.system(size: 9, weight: .semibold, design: .rounded))
            .foregroundStyle(accent)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(accent.opacity(0.12))
            .clipShape(Capsule())
            // Same reasoning as PlanBadge: the name takes the ellipsis,
            // not the badge.
            .fixedSize(horizontal: true, vertical: false)
            .help("Running /\(name)")
            .accessibilityLabel("running slash command \(name)")
    }

    private var accent: Color {
        // Soft amber — distinct from the purple plan badge and the cyan
        // cleat capsule so three badges stay tellable apart.
        Color(red: 0.88, green: 0.72, blue: 0.42)
    }
}

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
                Text(session.activeAgentsLabel ?? "")
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
            // An idle teammate keeps its row but stops reading as live
            // work: the sprite settles, the duration stops ticking, and
            // the accent drops to the same grey as secondary text.
            let trailing = agent.isIdle ? "idle" : formatElapsed(elapsed)
            HStack(alignment: .top, spacing: 6) {
                ClydeAnimationView(
                    state: agent.isIdle ? .idle : .busy,
                    pixelSize: 0.75,
                    ambientIdleEnabled: false
                )
                .frame(width: 12, height: 12)
                .padding(.top, 1)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    HStack {
                        Text(agent.type)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(agent.isIdle ? Color(white: 0.55) : accent)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(trailing)
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
            .accessibilityLabel(agent.isIdle
                ? "\(agent.type), \(agent.summary), idle"
                : "\(agent.type), \(agent.summary), running \(formatElapsed(elapsed))")
            .accessibilityAddTraits(agent.isIdle ? [] : .updatesFrequently)
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
        Group {
            if session.needsAttention && !reduceMotion {
                TimelineView(.animation(minimumInterval: PixelStatusIndicator.frameInterval)) { context in
                    slot(pulse: PixelStatusIndicator.attentionPulse(
                        at: context.date.timeIntervalSinceReferenceDate))
                }
            } else {
                // Held at the top of the breath rather than the bottom:
                // still, but as visible as the pulse ever makes it.
                slot(pulse: session.needsAttention ? 1 : 0)
            }
        }
        .accessibilityHidden(true)
    }

    private func slot(pulse: Double) -> some View {
        ZStack {
            // Stepped corners rather than a radius: the corner of a
            // drawn sprite, which is what this holds. The compact
            // panel's slot uses the same shape, so the mark is one
            // thing in both modes rather than two dialects of it.
            SteppedSquare(step: 34 * SteppedSquare.stepRatio)
                .fill(isActive
                        ? accent.opacity(PixelStatusIndicator.slotFillOpacity)
                        : PixelStatusIndicator.quietSlotFill)
                .frame(width: 34, height: 34)
            SteppedSquare(step: 34 * SteppedSquare.stepRatio)
                .stroke(
                    isActive
                        ? accent.opacity(session.needsAttention
                                            ? PixelStatusIndicator.attentionStrokeOpacity(at: pulse)
                                            : PixelStatusIndicator.slotStrokeOpacity)
                        : PixelStatusIndicator.quietSlotStroke,
                    lineWidth: isActive ? PixelStatusIndicator.slotStrokeWidth(slot: 34) : 1
                )
                .frame(width: 34, height: 34)

            if isActive {
                // The session's own state, in the same grid the
                // compact panel uses — sized from the slot, so the two
                // modes are one mark at two sizes rather than two marks
                // that have to be kept in step by hand.
                //
                // The mascot keeps the header, the summary bar and the
                // widget, where it stands for the app rather than for a
                // session. On a row it was saying "Clyde", which every
                // row here already is.
                PixelStatusIndicator(
                    state: session.needsAttention ? .needsAttention : .working,
                    slot: 34
                )

                if session.needsAttention {
                    Circle()
                        .fill(SessionTheme.attentionColor)
                        .frame(width: 12, height: 12)
                        .overlay(AttentionBadgeMark())
                        .offset(x: 13, y: -13)
                        .scaleEffect(PixelStatusIndicator.attentionScale(at: pulse))
                }
            } else {
                // Idle: numbered slot. Two-digit format keeps width stable.
                Text(String(format: "%02d", idleIndex ?? 0))
                    // Monospaced, like the compact slot's: the same
                    // number should not change typeface with the mode.
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(TextColor.tertiary)
            }
        }
    }
}

// MARK: - Attention badge

/// The mark inside the attention badge, drawn rather than typed.
///
/// It was `Text("!")` centred in the circle, and it sat visibly high:
/// a text view is centred by its layout box, which reserves room below
/// the baseline for descenders that an exclamation mark does not have.
/// The glyph therefore floats in the upper part of a box that is itself
/// centred correctly — a fix by eye would have been an offset nobody
/// could later justify.
///
/// Drawn as two rectangles it is centred by construction, and it is
/// made of the same pixels as everything else in this window.
struct AttentionBadgeMark: View {

    /// Whole points, and an even total, so the mark centres on the
    /// pixel grid inside a 12-point circle rather than on a half point.
    static let barWidth: CGFloat = 2
    static let barHeight: CGFloat = 5
    static let gap: CGFloat = 1
    static let dot: CGFloat = 2

    static var height: CGFloat { barHeight + gap + dot }

    var body: some View {
        VStack(spacing: Self.gap) {
            Rectangle()
                .frame(width: Self.barWidth, height: Self.barHeight)
            Rectangle()
                .frame(width: Self.dot, height: Self.dot)
        }
        .foregroundStyle(.white)
        .frame(height: Self.height)
        .accessibilityHidden(true)
    }
}
