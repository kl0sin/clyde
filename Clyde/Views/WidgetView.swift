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

    /// Slow ambient breathing for the working state (1.5s autoreverse).
    @State private var workingPhase = false
    /// Faster pulse for the attention state (0.8s autoreverse).
    @State private var attentionPhase = false
    /// Continuously expanding ring for attention (1.5s, non-autoreverse).
    @State private var attentionRingExpand = false

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
        // Smooth crossfade when the dominant state changes (e.g. ready → working).
        .animation(.easeInOut(duration: 0.35), value: dom.kind)
        .onAppear { startAmbientAnimations() }
    }

    private func startAmbientAnimations() {
        // Working: slow gentle breathing (opacity + tiny scale).
        withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
            workingPhase = true
        }
        // Attention: faster pulse to draw the eye.
        withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
            attentionPhase = true
        }
        // Attention ring: a wave that expands outward and fades, then resets.
        withAnimation(.easeOut(duration: 1.5).repeatForever(autoreverses: false)) {
            attentionRingExpand = true
        }
    }

    /// Big number block on the left. 30 × 30 with the state's tinted
    /// background. Working "breathes", attention pulses faster and gets a
    /// glow ring; ready and empty are static.
    private func dominantBlock(kind: StatusKind, count: Int, isEmpty: Bool) -> some View {
        let bg: Color = isEmpty ? Color(white: 0.16) : kind.color.opacity(0.20)
        let fg: Color = isEmpty ? Color(white: 0.30) : kind.color

        let isWorking = !isEmpty && kind == .working
        let isAttention = !isEmpty && kind == .attention

        // Per-state animated values, all driven by the three @State phases.
        let scale: CGFloat = isWorking ? (workingPhase ? 1.03 : 1.0) : 1.0
        let opacity: Double = {
            if isWorking { return workingPhase ? 1.0 : 0.7 }
            if isAttention { return attentionPhase ? 1.0 : 0.55 }
            return 1.0
        }()

        return ZStack {
            // Attention ring: stroked rounded-rect that grows and fades out,
            // then loops. Sits behind the block. Only rendered for attention.
            if isAttention {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(kind.color, lineWidth: 1.5)
                    .frame(width: 30, height: 30)
                    .scaleEffect(attentionRingExpand ? 1.55 : 1.0)
                    .opacity(attentionRingExpand ? 0.0 : 0.7)
            }

            Text("\(count)")
                .font(.system(size: 14, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .foregroundColor(fg)
                .frame(width: 30, height: 30)
                .background(bg)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .scaleEffect(scale)
                .opacity(opacity)
        }
        .frame(width: 30, height: 30)
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
