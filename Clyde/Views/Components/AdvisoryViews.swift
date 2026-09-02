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

            // Both doors, when the issue has two. The shortcut needs
            // two grants in two different panes, and telling someone
            // about the second only after they have granted the first
            // reads as the app moving the goalposts.
            HStack(spacing: Spacing.xxs) {
                if let url = issue.bannerActionURL, let title = issue.bannerActionTitle {
                    advisoryButton(title, url: url, prominent: true)
                }
                if let url = issue.bannerSecondaryActionURL,
                   let title = issue.bannerSecondaryActionTitle {
                    advisoryButton(title, url: url, prominent: false)
                }
            }
            .padding(.top, 2)
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
