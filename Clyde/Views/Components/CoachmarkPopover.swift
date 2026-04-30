import SwiftUI

/// Content of a single coachmark popover. The system `.popover`
/// modifier hosts this view; we draw the title, body, footer with
/// counter / skip / advance.
///
/// `step.isFinal` swaps the primary button label from "Got it ›" to
/// "Done ✓".
struct CoachmarkPopover: View {
    let step: CoachmarkStep
    let onAdvance: () -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(step.title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            Text(step.body)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .center) {
                if let counter = step.counterText {
                    Text(counter)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .accessibilityLabel("Step \(counter)")
                }

                Spacer()

                Button("Skip tour", action: onSkip)
                    .buttonStyle(.link)
                    .accessibilityLabel("Skip the welcome tour")

                Button(step.isFinal ? "Done ✓" : "Got it ›", action: onAdvance)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
        .padding(14)
        .frame(width: 260)
    }
}
