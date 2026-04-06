import Foundation
import Combine

/// Watches ~/.clyde/events/ for hook events signalling that a Claude session
/// needs user attention (permission prompt, waiting for input, etc.)
@MainActor
final class AttentionMonitor: ObservableObject {
    /// Set of PIDs currently needing attention
    @Published var attentionPIDs: Set<pid_t> = []

    /// Callback fired when a new PID starts needing attention (for sound/notification)
    var onAttentionNeeded: ((pid_t) -> Void)?

    private var pollTimer: Timer?
    private let eventsDir: URL
    private let attentionTimeout: TimeInterval = 60 // Events older than 60s are ignored

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        eventsDir = home.appendingPathComponent(".clyde/events")
        try? FileManager.default.createDirectory(at: eventsDir, withIntermediateDirectories: true)
    }

    func start() {
        stop()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scan() }
        }
        scan()
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func scan() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: eventsDir,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }

        let now = Date()
        var activePIDs: Set<pid_t> = []

        for file in files where file.pathExtension == "json" {
            let pidString = file.deletingPathExtension().lastPathComponent
            guard let pid = pid_t(pidString) else { continue }

            // Check modification time
            let attrs = try? file.resourceValues(forKeys: [.contentModificationDateKey])
            if let mtime = attrs?.contentModificationDate,
               now.timeIntervalSince(mtime) < attentionTimeout {
                activePIDs.insert(pid)
            } else {
                // Clean up expired event files
                try? FileManager.default.removeItem(at: file)
            }
        }

        // Detect newly needing attention
        let newPIDs = activePIDs.subtracting(attentionPIDs)
        for pid in newPIDs {
            onAttentionNeeded?(pid)
        }

        if activePIDs != attentionPIDs {
            attentionPIDs = activePIDs
        }
    }

    /// Mark a PID as handled (clear the attention flag).
    /// Called when session transitions to busy (Claude started processing again).
    func clearAttention(pid: pid_t) {
        let file = eventsDir.appendingPathComponent("\(pid).json")
        try? FileManager.default.removeItem(at: file)
        attentionPIDs.remove(pid)
    }
}
