import SwiftUI

// MARK: - Activity Timeline (collapsible)

struct ActivityTimelineView: View {
    @ObservedObject var log: ActivityLog
    @State private var expanded: Bool = false

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

    private var header: some View {
        Button(action: {
            withAnimation(.easeInOut(duration: 0.22)) { expanded.toggle() }
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
                Spacer()
                Image(systemName: expanded ? "chevron.down" : "chevron.up")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color(white: 0.45))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
