import SwiftUI

struct WidgetView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                ClydeAnimationView(
                    state: viewModel.clydeState,
                    pixelSize: 1.4
                )
                .frame(width: 22, height: 22)

                Text("Clyde")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                    .fixedSize()

                RoundedRectangle(cornerRadius: 0.5)
                    .fill(Color.white.opacity(0.12))
                    .frame(width: 1, height: 14)

                CompactStatusView(viewModel: viewModel)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.001)) // Capture hit tests in corners
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.ultraThinMaterial)
                    .environment(\.colorScheme, .dark)

                RoundedRectangle(cornerRadius: 12)
                    .fill(
                        LinearGradient(
                            colors: [Color.white.opacity(0.06), Color.clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.toggleExpanded()
        }
        .contextMenu {
            Button(action: { viewModel.toggleExpanded() }) {
                Label("Open", systemImage: "rectangle.expand.vertical")
            }
            Button(action: { viewModel.showSettings = true; viewModel.isCollapsed = false }) {
                Label("Settings", systemImage: "gearshape")
            }
            Divider()
            Button(action: { NSApplication.shared.terminate(nil) }) {
                Label("Quit Clyde", systemImage: "power")
            }
        }
    }
}

/// Compact status display: a single dominant-state badge.
/// Priority: attention > working > ready. The Clyde animation carries the
/// rest of the context (waving for attention, antenna pulse for busy).
private struct CompactStatusView: View {
    @ObservedObject var viewModel: AppViewModel
    @ObservedObject var attentionMonitor: AttentionMonitor
    @State private var isPulsing = false

    init(viewModel: AppViewModel) {
        self.viewModel = viewModel
        self.attentionMonitor = viewModel.attentionMonitor
    }

    private struct Badge {
        let count: Int
        let label: String
        let color: Color
        let pulse: Bool
    }

    private var badge: Badge? {
        // Ghost rows (sessions still visually lingering after exit) don't
        // count toward the dominant-state badge.
        let sessions = viewModel.processMonitor.sessions.filter { !$0.isGhost }
        let attentionPIDs = attentionMonitor.attentionPIDs
        let attention = sessions.filter { attentionPIDs.contains($0.pid) }.count
        let processing = sessions.filter { $0.status == .busy && !attentionPIDs.contains($0.pid) }.count
        let ready = sessions.count - processing - attention

        if attention > 0 {
            return Badge(count: attention, label: "needs input", color: .blue, pulse: true)
        }
        if processing > 0 {
            return Badge(count: processing, label: "working", color: .orange, pulse: true)
        }
        if ready > 0 {
            return Badge(count: ready, label: "ready", color: .green, pulse: false)
        }
        return nil
    }

    var body: some View {
        Group {
            if let badge {
                HStack(spacing: 5) {
                    Circle()
                        .fill(badge.color)
                        .frame(width: 6, height: 6)
                        .opacity(badge.pulse && isPulsing ? 0.4 : 1.0)
                    Text("\(badge.count) \(badge.label)")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(badge.color)
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(badge.color.opacity(0.15))
                .clipShape(Capsule())
            } else {
                Text("idle")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundColor(Color(white: 0.5))
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                isPulsing = true
            }
        }
    }
}
