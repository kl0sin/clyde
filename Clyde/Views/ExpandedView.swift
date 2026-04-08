import SwiftUI
import AppKit

// MARK: - Expanded View

struct ExpandedView: View {
    @ObservedObject var appViewModel: AppViewModel
    @ObservedObject var sessionViewModel: SessionListViewModel

    var body: some View {
        VStack(spacing: 0) {
            ExpandedHeader(
                clydeState: appViewModel.clydeState,
                attentionCount: sessionViewModel.attentionCount,
                workingCount: sessionViewModel.busyCount,
                readyCount: sessionViewModel.idleCount,
                isSnoozed: appViewModel.notificationService.isSnoozed,
                onSnooze: {
                    if appViewModel.notificationService.isSnoozed {
                        appViewModel.notificationService.clearSnooze()
                    } else {
                        appViewModel.notificationService.snooze(minutes: 30)
                    }
                },
                onSettings: { appViewModel.showSettings = true },
                onCollapse: { appViewModel.toggleExpanded() }
            )

            if let issue = appViewModel.hookHealthIssue {
                HookHealthBanner(
                    issue: issue,
                    onOpenSettings: { appViewModel.showSettings = true }
                )
            }

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
                    },
                    onReset: { session in
                        appViewModel.resetSession(session)
                    },
                    onMove: { source, destination in
                        sessionViewModel.moveSession(from: source, to: destination)
                    },
                    notificationService: appViewModel.notificationService
                )
            }

            Spacer(minLength: 0)

            ActivityTimelineView(log: appViewModel.activityLog)

            SummaryBar(
                sessionCount: sessionViewModel.sessionCount,
                busyCount: sessionViewModel.busyCount,
                idleCount: sessionViewModel.idleCount,
                clydeState: appViewModel.clydeState
            )
        }
        .background(
            // Background ZStack carries its own shadow so the shadow is
            // recomputed only when the container size changes — not on
            // every list redraw the way a top-level `.shadow` would.
            ZStack {
                // Glassmorphism base
                RoundedRectangle(cornerRadius: 12)
                    .fill(.ultraThinMaterial)
                    .environment(\.colorScheme, .dark)
                // Dark overlay for readability
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(nsColor: NSColor(red: 0.08, green: 0.08, blue: 0.1, alpha: 0.85)))
            }
            .shadow(color: .black.opacity(0.4), radius: 16, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5)
        )
    }
}

private struct HookHealthBanner: View {
    let issue: HookInstaller.HealthIssue
    let onOpenSettings: () -> Void

    var body: some View {
        Button(action: onOpenSettings) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(issue.bannerMessage)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.leading)
                    Text("Click to open Settings")
                        .font(.system(size: 9))
                        .foregroundStyle(Color(white: 0.6))
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color(white: 0.5))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.orange.opacity(0.12))
            .overlay(
                Rectangle().frame(height: 1).foregroundStyle(Color.orange.opacity(0.25)),
                alignment: .bottom
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
