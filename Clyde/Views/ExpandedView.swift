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
                snoozeRemainingMinutes: appViewModel.notificationService.snoozeRemainingMinutes,
                onSnooze: {
                    if appViewModel.notificationService.isSnoozed {
                        appViewModel.notificationService.clearSnooze()
                    } else {
                        appViewModel.notificationService.snooze(minutes: 30)
                    }
                },
                onSettings: { NotificationCenter.default.post(name: .clydeOpenSettings, object: nil) },
                onCollapse: { appViewModel.toggleExpanded() }
            )

            if let issue = appViewModel.hookHealthIssue {
                HookHealthBanner(
                    issue: issue,
                    onOpenSettings: { NotificationCenter.default.post(name: .clydeOpenSettings, object: nil) },
                    onDismiss: { appViewModel.dismissCurrentBanner() }
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
                    notificationService: appViewModel.notificationService,
                    expandedSubagentSessions: appViewModel.expandedSubagentSessions,
                    onToggleSubagentExpansion: { id in appViewModel.toggleSubagentExpansion(id) }
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
            // The NSPanel itself has `hasShadow = true` which gives the
            // window a system shadow already. We deliberately do NOT
            // add a SwiftUI `.shadow` here — earlier versions stacked
            // an internal shadow with `y: 4` on top of the system
            // shadow, which made the bottom edge of the expanded panel
            // visually heavier than the top edge and produced an
            // asymmetric gap to the widget depending on whether the
            // panel opened above or below it.
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.ultraThinMaterial)
                    .environment(\.colorScheme, .dark)
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(nsColor: NSColor(red: 0.08, green: 0.08, blue: 0.1, alpha: 0.85)))
            }
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
    let onDismiss: () -> Void

    var body: some View {
        if issue.isActionable {
            Button(action: onOpenSettings) {
                bannerContent(showAffordance: true)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityHint("Click to open Settings")
            .accessibilityAddTraits(.isButton)
        } else {
            // Informational banner — no in-app action would help
            // (e.g. `cleat config --enable hooks` runs interactively
            // in the user's terminal, not from inside Clyde). Render
            // as a static row so we don't promise an interaction we
            // can't deliver.
            bannerContent(showAffordance: false)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(accessibilityLabel)
        }
    }

    private var accessibilityLabel: String {
        if let title = issue.bannerTitle {
            return "\(title). \(issue.bannerMessage)"
        }
        return issue.bannerMessage
    }

    private func bannerContent(showAffordance: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13))
                .foregroundStyle(.orange)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 6) {
                if let title = issue.bannerTitle {
                    // Title/body split — short headline above, full
                    // sentence underneath. Reads cleaner than a single
                    // 3-line wall of text for advisories that have
                    // both a "what's wrong" and a "what to do".
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(issue.bannerMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(Color(white: 0.82))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(issue.bannerMessage)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let command = issue.bannerCommand {
                    // Discrete command chip — proper rendered
                    // background, copy button, and a brief ✓ on
                    // tap. Lives below the prose because inline
                    // backgrounds in SwiftUI Text don't render
                    // reliably (per-glyph gaps, no padding).
                    CopyableCommandChip(command: command)
                        .padding(.top, 2)
                }
                if showAffordance {
                    Text("Click to open Settings")
                        .font(.system(size: 9))
                        .foregroundStyle(Color(white: 0.55))
                }
            }
            Spacer(minLength: 4)
            if showAffordance {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color(white: 0.5))
                    .padding(.top, 3)
            } else if issue.isDismissable {
                // Dismiss button for advisories the user can defer.
                // Subtle styling — same family as the chevron above
                // so it reads as a peer affordance, not a competing
                // CTA. The flag is auto-cleared on issue resolution
                // so the banner reappears if the underlying state
                // toggles back later (see AppViewModel.ensureHookHealthy).
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color(white: 0.55))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Dismiss")
                .accessibilityLabel("Dismiss banner")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.10))
        .overlay(
            // Hairline at the bottom separates the banner from the
            // first session row, picking up the same orange tint as
            // the leading rule below for visual consistency.
            Rectangle().frame(height: 1).foregroundStyle(Color.orange.opacity(0.30)),
            alignment: .bottom
        )
        .overlay(
            // Thick leading rule echoes the macOS / web convention
            // for advisory callouts. Plays the role the SF symbol's
            // colour alone can't — anchors the banner against the
            // rest of the panel as a distinct affordance.
            Rectangle().frame(width: 2).foregroundStyle(Color.orange.opacity(0.55)),
            alignment: .leading
        )
        .contentShape(Rectangle())
    }
}

/// Discrete copyable chip rendered below a banner's body text when
/// `HealthIssue.bannerCommand` is non-nil. The chip is a real
/// SwiftUI Button (not AttributedString-rendered inline code) so we
/// get a proper rounded background, padding, and per-tap feedback
/// that SwiftUI's `Text` background attributes can't deliver
/// reliably on macOS.
struct CopyableCommandChip: View {
    let command: String

    @State private var copied = false

    var body: some View {
        Button(action: copy) {
            HStack(spacing: 6) {
                Text(command)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color(red: 1.0, green: 0.92, blue: 0.78))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(copied
                        ? Color(red: 0.55, green: 0.85, blue: 0.55)
                        : Color(white: 0.7))
                    .frame(width: 12)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.black.opacity(0.45))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(copied ? "Copied" : "Click to copy")
        .accessibilityLabel(copied ? "Copied \(command)" : "Copy command \(command)")
    }

    private func copy() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(command, forType: .string)
        // Brief visual confirmation. ~1.4s is long enough for the
        // user to register the change without the indicator feeling
        // sticky if they're clicking around.
        withAnimation(.easeInOut(duration: 0.15)) { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            withAnimation(.easeInOut(duration: 0.2)) { copied = false }
        }
    }
}
