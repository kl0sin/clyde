import Foundation
import Combine

/// Records a chronological feed of session lifecycle events for the
/// expanded view's activity timeline. Subscribes to the existing
/// `ProcessMonitor` and `AttentionMonitor` publishers, diffs against
/// its own remembered state, and emits `ActivityEvent` rows.
///
/// Storage is in-memory only — at most `maxEvents` rows are kept,
/// FIFO. The list resets on app launch.
@MainActor
final class ActivityLog: ObservableObject {
    @Published private(set) var events: [ActivityEvent] = []

    private let maxEvents = 50

    /// Last-seen status / attention state per PID. Used to detect
    /// transitions across publish ticks without double-counting.
    private struct Snapshot {
        var status: SessionStatus
        var hadAttention: Bool
        var hadError: String?
        var hadSubagent: String?
        var displayName: String
        /// Last-seen `source` from the SessionStart hook ("startup",
        /// "resume", "compact", "clear", or empty for legacy hooks). Used
        /// to detect auto-compact and /clear, which both emit a fresh
        /// `SessionStart` in the *same* PID — without tracking source we
        /// only emit a lifecycle event when the PID itself changes.
        var lastSource: String
        /// `true` when this snapshot was written from the published
        /// (visible) loop; `false` when written silently for a hidden
        /// automated session. Only a snapshot the user actually saw
        /// announces `.sessionEnded` when it disappears — a session that
        /// was never shown just vanishes without a trace.
        var wasPublished: Bool
    }
    private var snapshots: [pid_t: Snapshot] = [:]
    /// Hash of the last sessions+attention input we processed. Used to
    /// short-circuit reconcile() when nothing relevant has changed (the
    /// monitors emit on every poll, even if their state is identical).
    private var lastReconcileFingerprint: Int = 0

    private weak var processMonitor: ProcessMonitor?
    private weak var attentionMonitor: AttentionMonitor?
    private var cancellables = Set<AnyCancellable>()

    init(processMonitor: ProcessMonitor, attentionMonitor: AttentionMonitor) {
        self.processMonitor = processMonitor
        self.attentionMonitor = attentionMonitor

        // Seed the snapshot map without firing any events for sessions
        // that already exist when the app launches. Uses `trackedSessions`
        // (not the published, filtered `sessions`) so a hidden automated
        // session doesn't look "new" the moment it's revealed.
        let publishedPIDsAtLaunch = Set(processMonitor.sessions.lazy.filter { !$0.isGhost }.map(\.pid))
        for session in processMonitor.trackedSessions where !session.isGhost {
            snapshots[session.pid] = Snapshot(
                status: session.status,
                hadAttention: attentionMonitor.attentionPIDs.contains(session.pid),
                hadError: session.errorReason,
                hadSubagent: session.primarySubagentType,
                displayName: session.displayName,
                lastSource: processMonitor.hookInfoByPID[session.pid]?.source ?? "",
                wasPublished: publishedPIDsAtLaunch.contains(session.pid)
            )
        }

        // Both publishers live on `@MainActor` types and this class is
        // itself `@MainActor`, so delivery is synchronous with the
        // property mutation that triggered it — no `.receive(on:)` hop.
        // That matters here: `reconcile` also reads `processMonitor`'s
        // `trackedSessions` directly (not just the `sessions` argument),
        // and a scheduled hop would let that read race ahead of a second,
        // unrelated mutation before the first tick's callback ran,
        // handing `reconcile` a `sessions` snapshot and a `trackedSessions`
        // read that no longer describe the same moment. The same reasoning
        // applies to `attentionPIDs`: `@Published` delivers a value to its
        // subscribers during `willSet`, before the backing storage is
        // updated, so a sink that discards its argument and re-reads
        // `attentionMonitor.attentionPIDs` synchronously would still see
        // the *old* set. Both sinks below pass the value they were handed
        // straight into `reconcile` rather than re-reading the property.
        processMonitor.$sessions
            .sink { [weak self] sessions in
                self?.reconcile(sessions: sessions, attentionPIDs: self?.attentionMonitor?.attentionPIDs ?? [])
            }
            .store(in: &cancellables)

        attentionMonitor.$attentionPIDs
            .sink { [weak self] attentionPIDs in
                if let sessions = self?.processMonitor?.sessions {
                    self?.reconcile(sessions: sessions, attentionPIDs: attentionPIDs)
                }
            }
            .store(in: &cancellables)
    }

    /// Drop the entire history. Surfaced via the timeline UI's "clear" button.
    func clear() {
        events.removeAll()
    }

    // MARK: - Diffing

    /// `sessions` is the published, filtered list — it hides automated
    /// (headless) sessions unless the "Show automated sessions" toggle is
    /// on. `trackedSessions` is everything the monitor actually knows
    /// about. The trail speaks only about `live` (the published sessions,
    /// what the user can see), but remembers `trackedLive` too, so
    /// flipping the toggle reveals or hides a session without the trail
    /// mistaking that for it starting or ending.
    private func reconcile(sessions: [Session], attentionPIDs: Set<pid_t>) {
        let live = sessions.filter { !$0.isGhost }
        let livePIDs = Set(live.map(\.pid))
        let trackedLive = (processMonitor?.trackedSessions ?? []).filter { !$0.isGhost }
        let trackedLivePIDs = Set(trackedLive.map(\.pid))

        // Cheap fingerprint of inputs that could trigger an event. Hashed
        // over `trackedLive` — everything the monitor knows about, not just
        // `live` (the published subset) — so a hidden session's status,
        // attention, error, subagent, or hook-source change still moves the
        // fingerprint and the diff below runs to keep its snapshot current.
        // Skip that and a hidden automated session going idle→busy while
        // hidden leaves a stale snapshot; showing it later replays that
        // transition as a phantom event. Emission below still only speaks
        // about `live`.
        var hasher = Hasher()
        for s in trackedLive {
            hasher.combine(s.pid)
            hasher.combine(s.status)
            hasher.combine(attentionPIDs.contains(s.pid))
            hasher.combine(s.errorReason)
            hasher.combine(s.primarySubagentType)
            // Include hook source so an in-PID auto-compact / /clear
            // transition (which keeps every other field unchanged)
            // doesn't get short-circuited away by the fingerprint check.
            hasher.combine(processMonitor?.hookInfoByPID[s.pid]?.source ?? "")
        }
        let fingerprint = hasher.finalize()
        if fingerprint == lastReconcileFingerprint && snapshots.keys.allSatisfy(trackedLivePIDs.contains) {
            return
        }
        lastReconcileFingerprint = fingerprint

        // Newly seen sessions — use hook source to distinguish
        // startup vs resume vs compact.
        for session in live where snapshots[session.pid] == nil {
            let source = processMonitor?.hookInfoByPID[session.pid]?.source ?? ""
            let kind: ActivityEvent.Kind
            switch source {
            case "resume": kind = .sessionResumed
            case "compact", "clear": kind = .sessionCompacted
            default: kind = .sessionStarted
            }
            append(.init(
                timestamp: Date(),
                kind: kind,
                sessionDisplayName: session.displayName,
                sessionPID: session.pid
            ))
        }

        // Status / attention transitions
        for session in live {
            let hadAttention = attentionPIDs.contains(session.pid)
            let prev = snapshots[session.pid]
            let currentSource = processMonitor?.hookInfoByPID[session.pid]?.source ?? ""

            if let prev {
                // Auto-compact and /clear both fire a fresh SessionStart
                // in the same PID, flipping `source` from "startup"/"resume"
                // to "compact"/"clear". Surface that as its own timeline
                // entry — without this, the user only sees a quiet status
                // flicker even though Claude just wiped its context.
                if currentSource != prev.lastSource,
                   currentSource == "compact" || currentSource == "clear" {
                    append(.init(
                        timestamp: Date(),
                        kind: .sessionCompacted,
                        sessionDisplayName: session.displayName,
                        sessionPID: session.pid
                    ))
                }

                if prev.status == .idle && session.status == .busy {
                    append(.init(
                        timestamp: Date(),
                        kind: .promptSubmitted,
                        sessionDisplayName: session.displayName,
                        sessionPID: session.pid
                    ))
                } else if prev.status == .busy && session.status == .idle && !hadAttention {
                    append(.init(
                        timestamp: Date(),
                        kind: .sessionReady,
                        sessionDisplayName: session.displayName,
                        sessionPID: session.pid
                    ))
                }

                if !prev.hadAttention && hadAttention {
                    append(.init(
                        timestamp: Date(),
                        kind: .permissionRequested,
                        sessionDisplayName: session.displayName,
                        sessionPID: session.pid
                    ))
                } else if prev.hadAttention && !hadAttention && session.status == .busy {
                    // Attention cleared while still busy → user resolved
                    // the prompt and Claude is processing the answer.
                    append(.init(
                        timestamp: Date(),
                        kind: .permissionResolved,
                        sessionDisplayName: session.displayName,
                        sessionPID: session.pid
                    ))
                }

                // Error appeared (StopFailure with reason)
                if prev.hadError == nil, let reason = session.errorReason {
                    append(.init(
                        timestamp: Date(),
                        kind: .errorOccurred(reason: session.errorDisplayText ?? reason),
                        sessionDisplayName: session.displayName,
                        sessionPID: session.pid
                    ))
                }

                // Subagent lifecycle
                if prev.hadSubagent == nil, let agentType = session.primarySubagentType {
                    append(.init(
                        timestamp: Date(),
                        kind: .subagentStarted(agentType: agentType),
                        sessionDisplayName: session.displayName,
                        sessionPID: session.pid
                    ))
                } else if prev.hadSubagent != nil && session.primarySubagentType == nil {
                    append(.init(
                        timestamp: Date(),
                        kind: .subagentStopped,
                        sessionDisplayName: session.displayName,
                        sessionPID: session.pid
                    ))
                }
            }

            snapshots[session.pid] = Snapshot(
                status: session.status,
                hadAttention: hadAttention,
                hadError: session.errorReason,
                hadSubagent: session.primarySubagentType,
                displayName: session.displayName,
                lastSource: currentSource,
                wasPublished: true
            )
        }

        // Automated sessions hidden by the toggle — seed/refresh their
        // snapshots silently so a later reveal doesn't look like a start.
        // Restricted to `isHeadless` so a transient publish race (tracked
        // and published lists briefly out of step across ticks) can't get
        // mistaken for a hide and swallow a real session's start event.
        for session in trackedLive where session.isHeadless && !livePIDs.contains(session.pid) {
            // Once a session has been shown, hiding it again must not
            // erase that: `wasPublished` only ever turns on, here.
            let previouslyPublished = snapshots[session.pid]?.wasPublished ?? false
            snapshots[session.pid] = Snapshot(
                status: session.status,
                hadAttention: attentionPIDs.contains(session.pid),
                hadError: session.errorReason,
                hadSubagent: session.primarySubagentType,
                displayName: session.displayName,
                lastSource: processMonitor?.hookInfoByPID[session.pid]?.source ?? "",
                wasPublished: previouslyPublished
            )
        }

        // Sessions that disappeared. A session the user never saw (hidden
        // by the toggle the whole time it ran) just vanishes — only a
        // snapshot that was ever published announces `.sessionEnded`.
        let knownPIDs = Set(snapshots.keys)
        for goneP in knownPIDs.subtracting(trackedLivePIDs) {
            if let snapshot = snapshots[goneP], snapshot.wasPublished {
                append(.init(
                    timestamp: Date(),
                    kind: .sessionEnded,
                    sessionDisplayName: snapshot.displayName,
                    sessionPID: goneP
                ))
            }
            snapshots.removeValue(forKey: goneP)
        }
    }

    private func append(_ event: ActivityEvent) {
        events.insert(event, at: 0)
        if events.count > maxEvents {
            events.removeLast(events.count - maxEvents)
        }
    }
}
