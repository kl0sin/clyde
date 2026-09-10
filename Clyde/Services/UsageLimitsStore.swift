import Foundation
import Combine

/// Watches `~/.clyde/usage/` for the snapshot the status-line wrapper
/// writes, and publishes the parsed windows.
///
/// Modelled on `PermissionRequestStore`: a directory watcher for the
/// immediate reaction — the wrapper renames a temp file into place,
/// which the directory sees — plus a slow timer, because a window
/// expiring produces no filesystem event.
@MainActor
final class UsageLimitsStore: ObservableObject {

    /// The last snapshot, minus any window whose reset has passed. Nil
    /// when the feature is off, nothing has been written yet, or the
    /// payload carried no `rate_limits` (an API key, a session before
    /// its first response).
    @Published private(set) var limits: UsageLimits?

    private let directory: URL
    private let isEnabled: () -> Bool
    private var dirSource: DispatchSourceFileSystemObject?
    private var expiryTimer: Timer?

    init(directory: URL = AppPaths.usageDir,
         isEnabled: @escaping () -> Bool = {
             UserDefaults.standard.bool(forKey: UsageLimitsInstaller.settingKey)
         }) {
        self.directory = directory
        self.isEnabled = isEnabled
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        expiryTimer?.invalidate()
        dirSource?.cancel()
    }

    func start() {
        stop()
        startDirectoryWatcher()
        // A window ends on a clock. Thirty seconds keeps a spent window
        // from lingering long after Claude Code would have dropped it.
        expiryTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.scan() }
        }
        scan()
    }

    func stop() {
        expiryTimer?.invalidate()
        expiryTimer = nil
        dirSource?.cancel()
        dirSource = nil
    }

    func scan(now: Date = Date()) {
        guard isEnabled() else {
            if limits != nil { limits = nil }
            return
        }
        let file = directory.appendingPathComponent("statusline.json")
        guard let data = try? Data(contentsOf: file),
              let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                  .contentModificationDate,
              let parsed = UsageLimits.parse(data, modifiedAt: modified) else {
            if limits != nil { limits = nil }
            return
        }
        let live = parsed.droppingExpiredWindows(now: now)
        let next: UsageLimits? = live.hasAnyWindow ? live : nil
        if next != limits { limits = next }
    }

    private func startDirectoryWatcher() {
        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else {
            ClydeLog.hooks.error("Failed to open usage dir for watching")
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: DispatchQueue.main
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in self?.scan() }
        }
        // Capture the descriptor rather than reading it back from a
        // property — that spelling leaked one descriptor per restart in
        // ProcessMonitor.
        source.setCancelHandler { close(fd) }
        source.resume()
        dirSource = source
    }
}
