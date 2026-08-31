import Foundation
import Combine

/// Watches `~/.clyde/permissions/` for questions the hook is waiting on,
/// and writes the answers back.
///
/// Modelled on `AttentionMonitor`: a directory watcher for an immediate
/// reaction, plus a slow timer, because a request expiring produces no
/// filesystem event — the window simply passes.
@MainActor
final class PermissionRequestStore: ObservableObject {

    /// Live requests, newest first. Expired ones are dropped: by then
    /// the hook has given up and the terminal is asking.
    @Published private(set) var pending: [PermissionRequest] = []

    private let directory: URL
    /// Whether the user has turned panel answering on. Read on every
    /// scan rather than captured, so flipping the switch takes effect
    /// without a restart.
    private let isEnabled: () -> Bool
    private var expiryTimer: Timer?
    private var dirSource: DispatchSourceFileSystemObject?

    /// The default: Clyde does not answer permission requests until the
    /// user says so. Off means the hook never waits for anything.
    static let settingKey = "answerPermissionsInPanel"

    init(directory: URL = AppPaths.permissionsDir,
         isEnabled: @escaping () -> Bool = {
             UserDefaults.standard.bool(forKey: PermissionRequestStore.settingKey)
         }) {
        self.directory = directory
        self.isEnabled = isEnabled
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        // Held outside the main actor; cancelling the source closes its
        // descriptor through the cancel handler.
        expiryTimer?.invalidate()
        dirSource?.cancel()
    }

    func start() {
        stop()
        startDirectoryWatcher()
        // A request goes stale on a clock, not on a file change, and the
        // window is measured in seconds — so this ticks faster than the
        // other monitors in the app.
        expiryTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.scan() }
        }
        scan()
    }

    func stop() {
        expiryTimer?.invalidate()
        expiryTimer = nil
        dirSource?.cancel()
        dirSource = nil
        // Nobody should wait on a Clyde that is not there.
        withdrawReadiness()
    }

    /// Re-read the directory. Cheap: a handful of small files at most,
    /// and usually none at all.
    func scan() {
        guard isEnabled() else {
            withdrawReadiness()
            if !pending.isEmpty { pending = [] }
            return
        }
        // The hook reads this file's age to decide whether waiting is
        // worth it, so it has to keep being touched while Clyde is
        // alive — a stale one means "gone".
        publishReadiness()

        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        // An answer nobody collected — the hook died mid-window, or the
        // window had already closed — is litter in a directory the user
        // never sees. The hook deletes its own; this covers the rest.
        let now = Date()
        for file in files where file.pathExtension == "decision" {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? now
            if now.timeIntervalSince(modified) > 60 {
                try? FileManager.default.removeItem(at: file)
            }
        }

        let requests = files
            .filter { $0.pathExtension == "request" }
            .compactMap { PermissionRequest(fileURL: $0) }
            .filter(\.isLive)
            .sorted { $0.expiresAt > $1.expiresAt }
        if requests != pending {
            pending = requests
        }
    }

    /// Answer one request. The waiting hook picks the file up, deletes
    /// it and returns the decision; if it has already given up, the
    /// file is harmless — it names a request id that will never recur.
    func answer(_ request: PermissionRequest, with decision: PermissionDecision) {
        let url = directory.appendingPathComponent("\(request.id).decision")
        let body = ["behavior": decision.rawValue]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        do {
            try data.write(to: url, options: .atomic)
            ClydeLog.hooks.info("Answered permission request \(request.toolName, privacy: .public) with \(decision.rawValue, privacy: .public)")
        } catch {
            // The terminal still has the question; nothing is lost but
            // the shortcut.
            ClydeLog.hooks.error("Could not write permission decision: \(error.localizedDescription, privacy: .public)")
            return
        }
        // Leave the panel at once rather than waiting for the next scan:
        // a question that lingers after it is answered invites a second
        // click on something nobody is listening for any more.
        pending.removeAll { $0.id == request.id }
    }

    private func publishReadiness() {
        let marker = directory.appendingPathComponent("ready")
        if FileManager.default.fileExists(atPath: marker.path) {
            try? FileManager.default.setAttributes([.modificationDate: Date()],
                                                   ofItemAtPath: marker.path)
        } else {
            FileManager.default.createFile(atPath: marker.path, contents: Data())
        }
    }

    private func withdrawReadiness() {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("ready"))
    }

    private func startDirectoryWatcher() {
        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: .write, queue: .main)
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
