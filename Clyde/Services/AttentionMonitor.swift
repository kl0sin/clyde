import Foundation
import Combine

/// Watches ~/.clyde/events/ for hook events signalling that a Claude session
/// needs user attention (permission prompt, waiting for input, etc.)
@MainActor
final class AttentionMonitor: ObservableObject {
    /// Set of PIDs currently needing attention
    @Published private(set) var attentionPIDs: Set<pid_t> = []

    /// Callback fired when a new PID starts needing attention (for sound/notification)
    var onAttentionNeeded: ((pid_t) -> Void)?

    private var pollTimer: Timer?
    private var dirSource: DispatchSourceFileSystemObject?
    private var dirFD: Int32 = -1
    private let eventsDir: URL
    private let timeout: TimeInterval

    init(eventsDir: URL = AppPaths.eventsDir, timeout: TimeInterval = AppConstants.attentionEventTimeout) {
        self.eventsDir = eventsDir
        self.timeout = timeout
        try? FileManager.default.createDirectory(at: eventsDir, withIntermediateDirectories: true)
    }

    deinit {
        pollTimer?.invalidate()
    }

    func start() {
        stop()
        // FSEvents-style watcher: react instantly when the hook writes a file.
        startDirectoryWatcher()
        // Backup periodic scan handles file expiry (no FS event for stale mtime).
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scan() }
        }
        scan()
        ClydeLog.hooks.info("AttentionMonitor started, watching \(self.eventsDir.path, privacy: .public)")
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        dirSource?.cancel()
        dirSource = nil
    }

    private func startDirectoryWatcher() {
        try? FileManager.default.createDirectory(at: eventsDir, withIntermediateDirectories: true)
        let fd = open(eventsDir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        dirFD = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend, .attrib],
            queue: DispatchQueue.main
        )
        source.setEventHandler { [weak self] in
            self?.scan()
        }
        source.setCancelHandler { [weak self] in
            if let fd = self?.dirFD, fd >= 0 {
                close(fd)
                self?.dirFD = -1
            }
        }
        source.resume()
        dirSource = source
    }

    private func scan() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: eventsDir,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else {
            return
        }

        let now = Date()
        var activePIDs: Set<pid_t> = []

        for file in files where file.pathExtension == "json" {
            // The file is keyed by session_id (UUID); the live PID is inside.
            // Fall back to the legacy <pid>.json filename format if needed.
            guard let pid = extractPID(from: file) else {
                try? FileManager.default.removeItem(at: file)
                continue
            }

            let attrs = try? file.resourceValues(forKeys: [.contentModificationDateKey])
            if let mtime = attrs?.contentModificationDate,
               now.timeIntervalSince(mtime) < timeout {
                activePIDs.insert(pid)
            } else {
                try? FileManager.default.removeItem(at: file)
            }
        }

        // Detect newly needing attention
        let newPIDs = activePIDs.subtracting(attentionPIDs)
        for pid in newPIDs {
            ClydeLog.hooks.info("Session \(pid) needs attention")
            onAttentionNeeded?(pid)
        }

        if activePIDs != attentionPIDs {
            attentionPIDs = activePIDs
        }
    }

    /// Mark a PID as handled (clear the attention flag).
    /// Called when session transitions to busy (Claude started processing again) or
    /// when user focuses the session terminal.
    func clearAttention(pid: pid_t) {
        // Find every file (session_id-keyed or legacy pid-keyed) whose payload
        // points at this PID and remove it.
        if let files = try? FileManager.default.contentsOfDirectory(
            at: eventsDir,
            includingPropertiesForKeys: nil
        ) {
            for file in files where file.pathExtension == "json" {
                if extractPID(from: file) == pid {
                    try? FileManager.default.removeItem(at: file)
                }
            }
        }
        if attentionPIDs.contains(pid) {
            attentionPIDs.remove(pid)
        }
    }

    /// Extract the live PID from an event file. Reads `pid` field from the JSON
    /// body; falls back to parsing the filename for legacy `<pid>.json` files.
    private func extractPID(from file: URL) -> pid_t? {
        if let data = try? Data(contentsOf: file),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let pidValue = json["pid"] as? Int {
            return pid_t(pidValue)
        }
        let stem = file.deletingPathExtension().lastPathComponent
        return pid_t(stem)
    }
}
