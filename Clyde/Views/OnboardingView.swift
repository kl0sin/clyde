import SwiftUI
import AppKit

struct OnboardingView: View {
    let onGetStarted: () -> Void
    let onOpenSettings: () -> Void

    /// Adaptive window size: prefers 420×500 but shrinks to fit small
    /// displays. Computed once when the view is first laid out.
    private static var preferredSize: CGSize {
        let target = CGSize(width: 420, height: 500)
        guard let visible = NSScreen.main?.visibleFrame else { return target }
        // Leave a 40pt margin so the window has breathing room.
        let maxW = max(320, visible.width - 80)
        let maxH = max(420, visible.height - 80)
        return CGSize(
            width: min(target.width, maxW),
            height: min(target.height, maxH)
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            // Hero — mascot + title
            VStack(spacing: 16) {
                ClydeAnimationView(state: .idle, pixelSize: 4)
                    .frame(width: 64, height: 64)

                Text("Meet Clyde")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Text("Your Claude Code session companion")
                    .font(.system(size: 13))
                    .foregroundStyle(Color(white: 0.6))
            }
            .padding(.top, 32)
            .padding(.bottom, 28)

            // Feature list
            VStack(alignment: .leading, spacing: 14) {
                featureRow(
                    icon: "bolt.circle.fill",
                    color: .orange,
                    title: "Every session, live",
                    description: "Working, done, or waiting on you — at a glance"
                )
                featureRow(
                    icon: "list.bullet.rectangle.fill",
                    color: .purple,
                    title: "What Claude is actually doing",
                    description: "The running tool, plan progress and subagents"
                )
                featureRow(
                    icon: "hand.tap.fill",
                    color: .blue,
                    title: "Attention alerts",
                    description: "Sound and banner when Claude asks for permission"
                )
                featureRow(
                    icon: "calendar",
                    color: .pink,
                    title: "Where the day went",
                    description: "Time, turns and projects — kept on this Mac"
                )
                featureRow(
                    icon: "keyboard",
                    color: .green,
                    title: "Press ⌃⌘C from anywhere",
                    description: "Toggles this panel. Needs accessibility and input monitoring access."
                )
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 14)

            // Kept out of the feature list on purpose: it is a matter of
            // trust rather than a feature, and a fifth row risks
            // overflowing the adaptive window on short displays.
            Text("Clyde installs a Claude Code hook at ~/.claude/hooks/ — manage it in Settings.")
                .font(.system(size: 10))
                .foregroundStyle(Color(white: 0.45))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 32)
                .padding(.bottom, 20)

            Spacer(minLength: 0)

            // Buttons
            HStack(spacing: 10) {
                Button(action: onOpenSettings) {
                    Text("Open Settings")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color(white: 0.8))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color(white: 0.18))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open Settings")
                .accessibilityHint("Opens Clyde's settings and closes this welcome window")

                Button(action: onGetStarted) {
                    Text("Get started")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            LinearGradient(
                                colors: [Color(red: 0.35, green: 0.7, blue: 1.0), Color(red: 0.25, green: 0.55, blue: 0.95)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                .accessibilityLabel("Get started")
                .accessibilityHint("Closes this welcome window")
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .frame(width: Self.preferredSize.width, height: Self.preferredSize.height)
        .background(
            ZStack {
                Color(nsColor: NSColor(red: 0.09, green: 0.09, blue: 0.11, alpha: 1))
                LinearGradient(
                    colors: [Color.white.opacity(0.04), Color.clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        )
        .accessibilityAddTraits(.isModal)
    }

    private func featureRow(icon: String, color: Color, title: String, description: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(color)
                .frame(width: 22, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Text(description)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(white: 0.55))
                    // Wrap rather than truncate. Without this the row
                    // silently ellipsised any copy longer than the
                    // window width, which is how the first draft of
                    // this list shipped three cut-off sentences.
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(description)")
    }
}
