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
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundColor(Color(white: 0.55))
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

    /// Faster pulse for the attention state (0.8s autoreverse).
    @State private var attentionPhase = false
    /// First expanding ring for attention (1.5s, non-autoreverse).
    @State private var attentionRingA = false
    /// Second expanding ring for attention, delayed 0.75s so the two
    /// rings form a continuous outward wave instead of a single beat.
    @State private var attentionRingB = false

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
            // Custom purple ~#bf5af2 — slightly brighter than system .purple
            // and specifically chosen for the "AI thinking" vibe.
            case .working:   return Color(red: 0.749, green: 0.353, blue: 0.949)
            case .ready:     return .green
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
        // Attention: faster pulse to draw the eye.
        withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
            attentionPhase = true
        }
        // Attention rings: two waves that expand outward and fade, with the
        // second offset by 0.75s so they form a continuous ripple.
        withAnimation(.easeOut(duration: 1.5).repeatForever(autoreverses: false)) {
            attentionRingA = true
        }
        withAnimation(.easeOut(duration: 1.5).repeatForever(autoreverses: false).delay(0.75)) {
            attentionRingB = true
        }
    }

    /// Big number block on the left. 30 × 30 with the state's tinted
    /// background.
    ///
    /// Working: a bright dot continuously traces the rounded-rect perimeter,
    /// driven by a `TimelineView(.animation)` with a 2.4s period. The block
    /// itself stays perfectly still so the digit is readable.
    ///
    /// Attention: the digit pulses in opacity and two concentric stroked
    /// rings expand outward in a staggered wave.
    ///
    /// Ready / empty: completely static.
    private func dominantBlock(kind: StatusKind, count: Int, isEmpty: Bool) -> some View {
        let bg: Color = isEmpty ? Color(white: 0.16) : kind.color.opacity(0.20)
        let fg: Color = isEmpty ? Color(white: 0.30) : kind.color

        let isWorking = !isEmpty && kind == .working
        let isAttention = !isEmpty && kind == .attention

        let pulsingOpacity: Double = isAttention ? (attentionPhase ? 1.0 : 0.55) : 1.0

        return ZStack {
            // Attention: two staggered expanding rings behind the block.
            if isAttention {
                attentionRing(color: kind.color, expand: attentionRingA)
                attentionRing(color: kind.color, expand: attentionRingB)
            }

            Text("\(count)")
                .font(.system(size: 14, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .foregroundColor(fg)
                .frame(width: 30, height: 30)
                .background(bg)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .opacity(pulsingOpacity)

            // Working: dot traces the rounded-rect perimeter.
            if isWorking {
                workingTracerDot(color: kind.color)
            }
        }
        .frame(width: 30, height: 30)
    }

    /// One expanding-and-fading ring overlay. Sizing is fixed at 30 × 30
    /// (same as the block) and the `scaleEffect` drives the outward wave.
    private func attentionRing(color: Color, expand: Bool) -> some View {
        RoundedRectangle(cornerRadius: 10)
            .stroke(color, lineWidth: 1.5)
            .frame(width: 30, height: 30)
            .scaleEffect(expand ? 1.55 : 1.0)
            .opacity(expand ? 0.0 : 0.7)
    }

    /// A bright dot travelling along the rounded-rect perimeter of the
    /// 30 × 30 dominant block, driven by a high-frequency TimelineView.
    /// 2.4 s per full loop.
    private func workingTracerDot(color: Color) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let period: TimeInterval = 2.4
            let progress = CGFloat((t / period).truncatingRemainder(dividingBy: 1.0))
            let pos = perimeterPosition(progress)
            return Circle()
                .fill(color)
                .frame(width: 6, height: 6)
                .shadow(color: color, radius: 4)
                .shadow(color: color.opacity(0.5), radius: 8)
                .position(pos)
        }
        .frame(width: 30, height: 30)
        .allowsHitTesting(false)
    }

    /// Linearly interpolates a point along the perimeter of a 30 × 30 box
    /// with 8 pt corner radius. Approximated with eight waypoints (top-
    /// right, right-top, ...) so the dot visits each side segment in equal
    /// time; the slight corner cut is imperceptible at this scale.
    private func perimeterPosition(_ t: CGFloat) -> CGPoint {
        let waypoints: [CGPoint] = [
            CGPoint(x: 8,  y: 0),
            CGPoint(x: 22, y: 0),
            CGPoint(x: 30, y: 8),
            CGPoint(x: 30, y: 22),
            CGPoint(x: 22, y: 30),
            CGPoint(x: 8,  y: 30),
            CGPoint(x: 0,  y: 22),
            CGPoint(x: 0,  y: 8),
            CGPoint(x: 8,  y: 0),
        ]
        let scaled = t * 8
        let idx = min(Int(scaled), 7)
        let local = scaled - CGFloat(idx)
        let from = waypoints[idx]
        let to = waypoints[idx + 1]
        return CGPoint(
            x: from.x + (to.x - from.x) * local,
            y: from.y + (to.y - from.y) * local
        )
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
