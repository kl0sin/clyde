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
        // that already exist when the app launches.
        for session in processMonitor.sessions where !session.isGhost {
            snapshots[session.pid] = Snapshot(
                status: session.status,
                hadAttention: attentionMonitor.attentionPIDs.contains(session.pid),
                hadError: session.errorReason,
                hadSubagent: session.subagentType,
                displayName: session.displayName
            )
        }

        processMonitor.$sessions
            .receive(on: RunLoop.main)
            .sink { [weak self] sessions in
                self?.reconcile(sessions: sessions)
            }
            .store(in: &cancellables)

        attentionMonitor.$attentionPIDs
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                if let sessions = self?.processMonitor?.sessions {
                    self?.reconcile(sessions: sessions)
                }
            }
            .store(in: &cancellables)
    }

    /// Drop the entire history. Surfaced via the timeline UI's "clear" button.
    func clear() {
        events.removeAll()
    }

    // MARK: - Diffing

    private func reconcile(sessions: [Session]) {
        let attentionPIDs = attentionMonitor?.attentionPIDs ?? []
        let live = sessions.filter { !$0.isGhost }
        let livePIDs = Set(live.map(\.pid))

        // Cheap fingerprint of inputs that could trigger an event. If nothing
        // observable changed since the previous tick, skip the diff entirely.
        var hasher = Hasher()
        for s in live {
            hasher.combine(s.pid)
            hasher.combine(s.status)
            hasher.combine(attentionPIDs.contains(s.pid))
            hasher.combine(s.errorReason)
            hasher.combine(s.subagentType)
        }
        let fingerprint = hasher.finalize()
        if fingerprint == lastReconcileFingerprint && snapshots.keys.allSatisfy(livePIDs.contains) {
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

            if let prev {
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
                if prev.hadSubagent == nil, let agentType = session.subagentType {
                    append(.init(
                        timestamp: Date(),
                        kind: .subagentStarted(agentType: agentType),
                        sessionDisplayName: session.displayName,
                        sessionPID: session.pid
                    ))
                } else if prev.hadSubagent != nil && session.subagentType == nil {
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
                hadSubagent: session.subagentType,
                displayName: session.displayName
            )
        }

        // Sessions that disappeared
        let knownPIDs = Set(snapshots.keys)
        for goneP in knownPIDs.subtracting(livePIDs) {
            if let snapshot = snapshots[goneP] {
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
