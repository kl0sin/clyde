import SwiftUI
import AppKit

/// The advisory chip and its detail card, shared by every panel mode.
///
/// They started as private helpers inside `SummaryBar` and
/// `ExpandedView`. Compact needed the same pair, and a third copy of a
/// thing this small is how two modes end up drawing the same warning
/// two different ways.
struct AdvisoryChip: View {
    let issue: HookInstaller.HealthIssue
    let onTap: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 8))
            Text(issue.chipLabel)
                .font(.system(size: 10))
        }
        .foregroundStyle(Color(red: 0.95, green: 0.75, blue: 0.35))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: Radius.small)
                .fill(Color(red: 0.95, green: 0.75, blue: 0.35).opacity(0.12))
        )
        // Without this the tap only lands on the drawn pixels — the
        // gaps are not part of the chip as far as hit-testing goes,
        // which reads as a chip that ignores clicks at random.
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .opacity(isHovered ? 0.85 : 1)
        .onTapGesture(perform: onTap)
        .help(issue.bannerMessage)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(issue.bannerTitle ?? issue.chipLabel)
        .accessibilityHint(issue.bannerMessage)
    }
}

/// The detail behind the chip, drawn inside the panel so it carries the
/// app's own radius, spacing and colours rather than a system popover's.
struct AdvisoryDetail: View {
    let issue: HookInstaller.HealthIssue
    let onClose: () -> Void

    @ViewBuilder
    private func advisoryButton(_ title: String, url: URL, prominent: Bool) -> some View {
        Button(title) {
            NSWorkspace.shared.open(url)
            onClose()
        }
        .buttonStyle(.plain)
        .font(.system(size: 11, weight: prominent ? .medium : .regular))
        .foregroundStyle(prominent ? TextColor.primary : TextColor.secondary)
        .padding(.horizontal, Spacing.xs)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: Radius.small)
                .fill(Color.white.opacity(prominent ? 0.12 : 0.07))
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.xxs) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Color(red: 0.95, green: 0.75, blue: 0.35))
                Text(issue.bannerTitle ?? issue.chipLabel)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(TextColor.primary)
                Spacer(minLength: Spacing.sm)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(TextColor.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }

            Text(issue.bannerMessage)
                .font(.system(size: 11))
                .foregroundStyle(TextColor.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Both doors, and which of them is already open. The
            // shortcut needs two grants in two different panes; telling
            // someone about the second only after they have granted the
            // first reads as the app moving the goalposts, and showing
            // both without saying which is done makes the finished one
            // look like work.
            if issue.isShortcutPermission {
                ShortcutPermissionActions(onOpen: onClose)
                    .padding(.top, 2)
            } else if let url = issue.bannerActionURL, let title = issue.bannerActionTitle {
                advisoryButton(title, url: url, prominent: true)
                    .padding(.top, 2)
            }
        }
        .padding(Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Radius.medium)
                .fill(Color(white: 0.13))
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.medium)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
    }
}

/// The two permissions ⌃⌘C needs, each saying whether it is already
/// granted.
///
/// The state is read at render time rather than stored: both checks are
/// a single syscall, and the advisory is redrawn every fifteen seconds
/// while it is up, which is what makes a tick appear shortly after the
/// user grants one without them having to work out whether Clyde
/// noticed.
struct ShortcutPermissionActions: View {
    var onOpen: () -> Void = {}

    var body: some View {
        HStack(spacing: Spacing.xxs) {
            ForEach(ShortcutPermission.allCases, id: \.title) { permission in
                let granted = permission.isGranted
                Button {
                    // `reveal` rather than opening the URL: Input
                    // Monitoring's pane lists only applications that
                    // have asked, so the ask has to happen first or the
                    // button leads somewhere with no Clyde in it.
                    permission.reveal()
                    onOpen()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: granted ? "checkmark" : "arrow.up.forward.app")
                            .font(.system(size: 9, weight: .semibold))
                        Text(permission.title)
                            .font(.system(size: 11, weight: granted ? .regular : .medium))
                    }
                    // Granted reads as settled rather than as a second
                    // thing to do: the green the app already uses for a
                    // session that needs nothing.
                    .foregroundStyle(granted
                                     ? SessionTheme.readyColor.opacity(0.9)
                                     : TextColor.primary)
                    .padding(.horizontal, Spacing.xs)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: Radius.small)
                            .fill(granted
                                  ? SessionTheme.readyColor.opacity(0.14)
                                  : Color.white.opacity(0.12))
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(granted
                                    ? "\(permission.title) is granted"
                                    : "Open \(permission.title) settings")
            }
        }
    }
}
