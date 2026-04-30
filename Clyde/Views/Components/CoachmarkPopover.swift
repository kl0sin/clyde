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

extension View {
    /// Attaches a coachmark popover to this view. The popover is
    /// presented when `controller.currentStep == step` and this
    /// view's `identity` wins the first-claim-wins race (handled by
    /// `controller.shouldAnchor`).
    ///
    /// `identity` defaults to a per-call `UUID()` — fine for
    /// single-anchor steps (snooze, collapse, emptyState). Pass a
    /// stable per-row identity for steps anchored inside `ForEach`
    /// lists (sessionRow, toolPlan).
    func coachmarkAnchor(
        _ step: CoachmarkStep,
        identity: AnyHashable = AnyHashable(UUID())
    ) -> some View {
        modifier(CoachmarkAnchorModifier(step: step, identity: identity))
    }
}

private struct CoachmarkAnchorModifier: ViewModifier {
    let step: CoachmarkStep
    let identity: AnyHashable

    @EnvironmentObject private var controller: CoachmarkController

    func body(content: Content) -> some View {
        content.popover(
            isPresented: Binding(
                get: { controller.shouldAnchor(step, identity: identity) },
                set: { isShown in
                    if !isShown && controller.currentStep == step {
                        controller.skip()
                    }
                }
            ),
            arrowEdge: .trailing
        ) {
            CoachmarkPopover(
                step: step,
                onAdvance: { controller.advance() },
                onSkip: { controller.skip() }
            )
        }
    }
}
