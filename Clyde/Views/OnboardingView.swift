import SwiftUI

struct OnboardingView: View {
    let onGetStarted: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Hero — mascot + title
            VStack(spacing: 16) {
                ClydeAnimationView(state: .idle, pixelSize: 4)
                    .frame(width: 64, height: 64)

                Text("Meet Clyde")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundColor(.white)

                Text("Your Claude Code session companion")
                    .font(.system(size: 13))
                    .foregroundColor(Color(white: 0.6))
            }
            .padding(.top, 32)
            .padding(.bottom, 28)

            // Feature list
            VStack(alignment: .leading, spacing: 14) {
                featureRow(
                    icon: "bolt.circle.fill",
                    color: .orange,
                    title: "Real-time session tracking",
                    description: "See when Claude is working, ready, or needs your input"
                )
                featureRow(
                    icon: "hand.tap.fill",
                    color: .blue,
                    title: "Attention alerts",
                    description: "Sound and banner when Claude asks for permission"
                )
                featureRow(
                    icon: "keyboard",
                    color: .green,
                    title: "Press ⌃⌘C from anywhere",
                    description: "Toggle the expanded view with a global shortcut"
                )
                featureRow(
                    icon: "gearshape.fill",
                    color: Color(white: 0.7),
                    title: "Hook auto-installed",
                    description: "Claude Code hook at ~/.claude/hooks/. Manage it in Settings."
                )
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 28)

            Spacer(minLength: 0)

            // Buttons
            HStack(spacing: 10) {
                Button(action: onOpenSettings) {
                    Text("Open Settings")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Color(white: 0.8))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color(white: 0.18))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)

                Button(action: onGetStarted) {
                    Text("Get started")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
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
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .frame(width: 420, height: 500)
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
    }

    private func featureRow(icon: String, color: Color, title: String, description: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundColor(color)
                .frame(width: 22, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                Text(description)
                    .font(.system(size: 11))
                    .foregroundColor(Color(white: 0.55))
            }

            Spacer(minLength: 0)
        }
    }
}
