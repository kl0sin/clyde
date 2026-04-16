import SwiftUI

struct WidgetView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                ClydeAnimationView(
                    state: viewModel.clydeState,
                    pixelSize: 1.75
                )
                .frame(width: 28, height: 28)

                CompactStatusView(viewModel: viewModel)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Explicit drag handle — the panel has isMovableByWindowBackground
        // disabled so clicks in the session list don't move the window,
        // but the collapsed widget should still be freely draggable.
        .background(WindowDragArea())
        .background(Color.black.opacity(0.001)) // Capture hit tests in corners
        .background(
            ZStack {
                // Material underlay — gives the slight blur on whatever is
                // behind the widget.
                RoundedRectangle(cornerRadius: 12)
                    .fill(.ultraThinMaterial)
                    .environment(\.colorScheme, .dark)

                // Solid dark overlay so the widget reads consistently on
                // any background (white desktop, photo wallpaper, etc.).
                // Without this the ultraThinMaterial washes out to grey on
                // light backgrounds and the text disappears.
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(nsColor: NSColor(red: 0.08, green: 0.08, blue: 0.1, alpha: 0.88)))

                // Subtle top highlight for depth.
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
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.toggleExpanded()
        }
        .contextMenu {
            Button(action: { viewModel.toggleExpanded() }) {
                Label("Open", systemImage: "rectangle.expand.vertical")
            }
            Button(action: { NotificationCenter.default.post(name: .clydeOpenSettings, object: nil) }) {
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

    // Attention state animation lives inside `pulsingDominantBlock`
    // (a TimelineView-driven sine wave shared with the working state).
    // No additional @State needed.

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
    }

    /// Big number block on the left. 30 × 30 with the state's tinted
    /// background.
    ///
    /// Working: scale + border alpha + glow alpha all drive off a
    /// single TimelineView-backed sine wave (1.6 s period). Block
    /// pulses 1.0 → 1.06, border alpha pulses 0.50 → 0.95, glow alpha
    /// pulses 0.10 → 0.55. No motion in space — the block "beats" in
    /// place. Faithful to the mockup we picked.
    ///
    /// Attention: the digit pulses in opacity and two concentric stroked
    /// rings expand outward in a staggered wave.
    ///
    /// Ready / empty: completely static.
    @ViewBuilder
    private func dominantBlock(kind: StatusKind, count: Int, isEmpty: Bool) -> some View {
        if !isEmpty && (kind == .working || kind == .attention) {
            pulsingDominantBlock(kind: kind, count: count)
        } else {
            let bg: Color = isEmpty ? Color(white: 0.16) : kind.color.opacity(0.20)
            let fg: Color = isEmpty ? Color(white: 0.30) : kind.color
            Text("\(count)")
                .font(.system(size: 14, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .foregroundStyle(fg)
                .frame(width: 30, height: 30)
                .background(bg)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    /// Pulsing dominant block, used for both `working` and `attention`
    /// states. Wrapped in a TimelineView so the scale + glow + border
    /// alpha are guaranteed to tick frame by frame, independent of
    /// SwiftUI's `withAnimation` system. Color comes from `kind.color`
    /// — purple for working, blue for attention.
    private func pulsingDominantBlock(kind: StatusKind, count: Int) -> some View {
        let color = kind.color
        let bg = color.opacity(0.20)

        return TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let period: TimeInterval = 1.6
            // Sine wave 0…1, period 1.6 s.
            let phase = (sin(t * .pi * 2 / period) + 1) / 2
            let scale = 1.0 + phase * 0.06            // 1.00 … 1.06
            let borderAlpha = 0.50 + phase * 0.45     // 0.50 … 0.95
            let glowAlpha = 0.08 + phase * 0.22       // 0.08 … 0.30

            ZStack {
                // Outer glow that breathes with the beat.
                RoundedRectangle(cornerRadius: 8)
                    .fill(color)
                    .frame(width: 34, height: 34)
                    .blur(radius: 12)
                    .opacity(glowAlpha)
                    .scaleEffect(scale)

                // Digit on the standard tinted bg, scaled with the beat.
                Text("\(count)")
                    .font(.system(size: 14, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(color)
                    .frame(width: 30, height: 30)
                    .background(bg)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .scaleEffect(scale)

                // Constant 1 pt border whose alpha pulses with the beat.
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(color, lineWidth: 1)
                    .frame(width: 30, height: 30)
                    .opacity(borderAlpha)
                    .scaleEffect(scale)
            }
            .frame(width: 30, height: 30)
        }
        .frame(width: 30, height: 30)
        .allowsHitTesting(false)
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
                .foregroundStyle(textColor)
        }
    }
}
