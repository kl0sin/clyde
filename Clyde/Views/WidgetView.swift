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

    /// Visual identity of one of the three tracked states. Holds its
    /// own colour so the view doesn't have to switch on the case.
    private enum StatusKind {
        case attention
        case working
        case ready

        var color: Color {
            switch self {
            case .attention: return .blue
            case .working:   return .orange
            case .ready:     return .green
            }
        }

        /// Whether this state should pulse when shown as the dominant block.
        var pulses: Bool {
            switch self {
            case .attention, .working: return true
            case .ready:               return false
            }
        }
    }

    /// Pre-computed status snapshot. Builds the dominant state (highest
    /// priority with count > 0) and the two non-dominant ticks in stable
    /// priority order. Pure logic — no SwiftUI dependencies.
    private struct StatusModel {
        let attention: Int
        let working: Int
        let ready: Int

        /// Total live sessions across all states. Zero means "no work
        /// at all" and the view renders the empty/dim style.
        var total: Int { attention + working + ready }

        /// The dominant state to render in the big block. Priority:
        /// attention > working > ready. Returns `.ready` with count 0
        /// when there are no sessions at all (caller treats as empty).
        var dominant: (kind: StatusKind, count: Int) {
            if attention > 0 { return (.attention, attention) }
            if working > 0   { return (.working, working) }
            if ready > 0     { return (.ready, ready) }
            return (.ready, 0)
        }

        /// The two states that are NOT the dominant one, in priority
        /// order (attention before working before ready). Each entry
        /// carries its own count, which may be zero (renders dim).
        var ticks: [(kind: StatusKind, count: Int)] {
            let dominantKind = dominant.kind
            let all: [(StatusKind, Int)] = [
                (.attention, attention),
                (.working, working),
                (.ready, ready),
            ]
            return all.filter { $0.0 != dominantKind }
        }
    }

    private var model: StatusModel {
        // Ghost rows (sessions still visually lingering after exit) don't
        // count toward any of the three states.
        let sessions = viewModel.processMonitor.sessions.filter { !$0.isGhost }
        let attentionPIDs = attentionMonitor.attentionPIDs
        let attention = sessions.filter { attentionPIDs.contains($0.pid) }.count
        let working = sessions.filter { $0.status == .busy && !attentionPIDs.contains($0.pid) }.count
        let ready = sessions.count - working - attention
        return StatusModel(attention: attention, working: working, ready: ready)
    }

    var body: some View {
        let snapshot = model
        let dom = snapshot.dominant
        let isEmpty = snapshot.total == 0

        HStack(spacing: 4) {
            dominantBlock(kind: dom.kind, count: dom.count, isEmpty: isEmpty)
            tickColumn(snapshot: snapshot, isEmpty: isEmpty)
        }
        .frame(width: 66, alignment: .leading)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                isPulsing = true
            }
        }
    }

    /// Big number block on the left. 30 × 30 with the state's tinted
    /// background. Pulses softly when the state is attention or working.
    private func dominantBlock(kind: StatusKind, count: Int, isEmpty: Bool) -> some View {
        let bg: Color = isEmpty ? Color(white: 0.16) : kind.color.opacity(0.20)
        let fg: Color = isEmpty ? Color(white: 0.30) : kind.color
        let shouldPulse = !isEmpty && kind.pulses
        return Text("\(count)")
            .font(.system(size: 14, weight: .heavy, design: .rounded))
            .monospacedDigit()
            .foregroundColor(fg)
            .frame(width: 30, height: 30)
            .background(bg)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .opacity(shouldPulse && isPulsing ? 0.4 : 1.0)
    }

    /// Two stacked tick rows on the right showing the non-dominant counts
    /// in stable priority order (attention, working, ready, minus dominant).
    private func tickColumn(snapshot: StatusModel, isEmpty: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(snapshot.ticks.enumerated()), id: \.offset) { _, tick in
                tickRow(kind: tick.kind, count: tick.count, isEmpty: isEmpty)
            }
        }
        .frame(width: 32, alignment: .leading)
    }

    /// Single tick row: a 14 × 2 coloured bar followed by a digit.
    /// Renders dim grey when count is 0 or the whole widget is empty.
    private func tickRow(kind: StatusKind, count: Int, isEmpty: Bool) -> some View {
        let active = !isEmpty && count > 0
        let barColor: Color = active ? kind.color : Color(white: 0.16)
        let textColor: Color = active ? kind.color : Color(white: 0.30)
        return HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 1)
                .fill(barColor)
                .frame(width: 14, height: 2)
            Text("\(count)")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundColor(textColor)
        }
    }
}
