import SwiftUI

// MARK: - Activity Timeline (collapsible)

struct ActivityTimelineView: View {
    @ObservedObject var log: ActivityLog
    /// Hidden when the history store failed to open — see
    /// `AppViewModel.historyAvailable`.
    var showsReview: Bool = false
    @State private var expanded: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            header
            if expanded {
                content
            }
        }
        .background(Color.white.opacity(0.02))
        .overlay(
            Rectangle().frame(height: 1).foregroundStyle(Color(white: 0.18)),
            alignment: .top
        )
    }

    /// The panel's route into the review window, which the design spec
    /// asks for and which was until now reachable only from the menu bar
    /// menu — the least-visited surface in the app, holding its headline
    /// feature. The row keeps one job per control: the wide area toggles
    /// the timeline, the trailing button opens the history.
    private var header: some View {
        HStack(spacing: 0) {
            Button(action: {
                if reduceMotion {
                    expanded.toggle()
                } else {
                    withAnimation(.easeInOut(duration: 0.22)) { expanded.toggle() }
                }
            }) {
                HStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color(white: 0.5))
                    Text("Activity")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color(white: 0.7))
                    if !log.events.isEmpty {
                        Text("\(log.events.count)")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color(white: 0.45))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color(white: 0.18))
                            .clipShape(Capsule())
                    }
                    Spacer(minLength: 4)
                    Image(systemName: expanded ? "chevron.down" : "chevron.up")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color(white: 0.45))
                }
                .padding(.leading, 14)
                .padding(.trailing, showsReview ? 8 : 14)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Activity timeline")
            .accessibilityValue(timelineAccessibilityValue)
            .accessibilityHint(expanded ? "Tap to collapse" : "Tap to expand")
            .accessibilityAddTraits(.isButton)

            if showsReview {
                Button(action: {
                    NotificationCenter.default.post(name: .clydeOpenReview, object: nil)
                }) {
                    Image(systemName: "calendar")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color(white: 0.5))
                        .padding(.trailing, 14)
                        .padding(.leading, 4)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Session review")
                .accessibilityLabel("Open session review")
                .accessibilityHint("Shows how long Claude worked, by day and project")
            }
        }
    }

    private var timelineAccessibilityValue: String {
        let count = log.events.count
        if count == 0 { return "No events" }
        return count == 1 ? "1 event" : "\(count) events"
    }

    private func eventAccessibilityLabel(_ event: ActivityEvent) -> String {
        let timeText = event.timestamp.formatted(date: .omitted, time: .shortened)
        switch event.kind {
        case .sessionStarted:
            return "\(event.sessionDisplayName): session started at \(timeText)"
        case .sessionResumed:
            return "\(event.sessionDisplayName): session resumed at \(timeText)"
        case .sessionCompacted:
            return "\(event.sessionDisplayName): context compacted at \(timeText)"
        case .promptSubmitted:
            return "\(event.sessionDisplayName): prompt submitted at \(timeText)"
        case .permissionRequested:
            return "\(event.sessionDisplayName): permission requested at \(timeText)"
        case .permissionResolved:
            return "\(event.sessionDisplayName): permission resolved at \(timeText)"
        case .errorOccurred(let reason):
            return "\(event.sessionDisplayName): error at \(timeText): \(reason)"
        case .subagentStarted(let agentType):
            return "\(event.sessionDisplayName): subagent \(agentType) started at \(timeText)"
        case .subagentStopped:
            return "\(event.sessionDisplayName): subagent finished at \(timeText)"
        case .sessionReady:
            return "\(event.sessionDisplayName): ready at \(timeText)"
        case .sessionEnded:
            return "\(event.sessionDisplayName): session ended at \(timeText)"
        }
    }

    @ViewBuilder
    private var content: some View {
        if log.events.isEmpty {
            Text("No activity yet")
                .font(.system(size: 11))
                .foregroundStyle(Color(white: 0.4))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        } else {
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button(action: { log.clear() }) {
                        Text("Clear")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(Color(white: 0.45))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 4)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(log.events) { event in
                            row(for: event)
                        }
                    }
                }
                .frame(maxHeight: 160)
            }
            .padding(.bottom, 4)
        }
    }

    private func row(for event: ActivityEvent) -> some View {
        HStack(spacing: 8) {
            Image(systemName: event.kind.symbol)
                .font(.system(size: 10))
                .foregroundStyle(color(for: event.kind))
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 1) {
                Text(event.kind.label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                Text(event.sessionDisplayName)
                    .font(.system(size: 9, weight: .regular, design: .monospaced))
                    .foregroundStyle(Color(white: 0.45))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Text(timeAgo(event.timestamp))
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(Color(white: 0.4))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(eventAccessibilityLabel(event))
    }

    private func color(for kind: ActivityEvent.Kind) -> Color {
        switch kind {
        case .sessionStarted:      return SessionTheme.processingColor
        case .sessionResumed:      return SessionTheme.processingColor
        case .sessionCompacted:    return Color(white: 0.6)
        case .promptSubmitted:     return SessionTheme.processingColor
        case .permissionRequested: return SessionTheme.attentionColor
        case .permissionResolved:  return SessionTheme.processingColor
        case .errorOccurred:       return SessionTheme.errorColor
        case .subagentStarted:     return SessionTheme.processingColor
        case .subagentStopped:     return SessionTheme.processingColor
        case .sessionReady:        return SessionTheme.readyColor
        case .sessionEnded:        return Color(white: 0.5)
        }
    }

    private func timeAgo(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 5 { return "now" }
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        return "\(hours)h"
    }
}
