import Foundation
import UserNotifications
import AppKit
import Combine

/// Plays sounds and sends system notifications when Claude sessions change state.
/// State is backed by UserDefaults; views observe via @Published.
@MainActor
final class NotificationService: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published var soundEnabled: Bool {
        didSet { UserDefaults.standard.set(soundEnabled, forKey: Keys.soundEnabled) }
    }

    @Published var systemNotificationsEnabled: Bool {
        didSet { UserDefaults.standard.set(systemNotificationsEnabled, forKey: Keys.systemNotificationsEnabled) }
    }

    @Published var readySound: String {
        didSet { UserDefaults.standard.set(readySound, forKey: Keys.readySound) }
    }

    @Published var attentionSound: String {
        didSet { UserDefaults.standard.set(attentionSound, forKey: Keys.attentionSound) }
    }

    /// Per-session sound overrides keyed by Claude `session_id`. When a key
    /// is present, the corresponding sound is played for that session
    /// instead of the global default.
    @Published private(set) var perSessionReadySound: [String: String] = [:]
    @Published private(set) var perSessionAttentionSound: [String: String] = [:]

    /// When set, suppresses all sounds and system notifications until the
    /// given date. Expires automatically via a scheduled timer that clears
    /// the value and re-publishes. Persisted to UserDefaults so a restart
    /// doesn't lose the active snooze.
    @Published private(set) var snoozeUntil: Date?

    /// True while the app is inside an active snooze window.
    var isSnoozed: Bool {
        guard let snoozeUntil else { return false }
        return snoozeUntil > Date()
    }

    private var snoozeWakeTimer: Timer?

    private var isAuthorized = false
    var onNotificationClicked: ((pid_t) -> Void)?

    private enum Keys {
        static let soundEnabled = "soundEnabled"
        static let systemNotificationsEnabled = "systemNotificationsEnabled"
        static let readySound = "selectedSound" // legacy key, kept for compatibility
        static let attentionSound = "attentionSound"
        static let perSessionReadySound = "perSessionReadySound"
        static let perSessionAttentionSound = "perSessionAttentionSound"
        static let snoozeUntil = "snoozeUntil"
    }

    override init() {
        let defaults = UserDefaults.standard
        self.soundEnabled = defaults.object(forKey: Keys.soundEnabled) as? Bool ?? true
        self.systemNotificationsEnabled = defaults.object(forKey: Keys.systemNotificationsEnabled) as? Bool ?? true
        self.readySound = defaults.string(forKey: Keys.readySound) ?? "Glass"
        self.attentionSound = defaults.string(forKey: Keys.attentionSound) ?? "Hero"
        self.perSessionReadySound = (defaults.dictionary(forKey: Keys.perSessionReadySound) as? [String: String]) ?? [:]
        self.perSessionAttentionSound = (defaults.dictionary(forKey: Keys.perSessionAttentionSound) as? [String: String]) ?? [:]
        // Load an already-active snooze if the app was restarted mid-nap.
        if let saved = defaults.object(forKey: Keys.snoozeUntil) as? Date, saved > Date() {
            self.snoozeUntil = saved
        }
        super.init()
        // Kick the expiry timer if we restored an active snooze.
        if snoozeUntil != nil { scheduleWakeTimer() }
    }

    deinit {
        // UNUserNotificationCenter retains its delegate. If a future
        // version of Clyde ever recreates NotificationService (tests,
        // hot-reload, etc.), failing to clear the delegate would leak
        // this instance and its Combine subscribers. Cheap to do, so
        // we do it.
        if UNUserNotificationCenter.current().delegate === self {
            UNUserNotificationCenter.current().delegate = nil
        }
    }

    // MARK: - Snooze API

    /// Begin a snooze window of the given duration (in minutes).
    func snooze(minutes: Int) {
        let deadline = Date().addingTimeInterval(TimeInterval(minutes * 60))
        snoozeUntil = deadline
        UserDefaults.standard.set(deadline, forKey: Keys.snoozeUntil)
        scheduleWakeTimer()
        ClydeLog.general.info("Snoozed for \(minutes) minutes")
    }

    /// End an active snooze immediately.
    func clearSnooze() {
        snoozeUntil = nil
        snoozeWakeTimer?.invalidate()
        snoozeWakeTimer = nil
        UserDefaults.standard.removeObject(forKey: Keys.snoozeUntil)
        ClydeLog.general.info("Snooze cleared")
    }

    /// Number of whole minutes left in the current snooze, or 0 if not snoozed.
    var minutesRemaining: Int {
        guard let snoozeUntil else { return 0 }
        let seconds = snoozeUntil.timeIntervalSinceNow
        return seconds > 0 ? Int(ceil(seconds / 60.0)) : 0
    }

    private func scheduleWakeTimer() {
        snoozeWakeTimer?.invalidate()
        guard let deadline = snoozeUntil else { return }
        let interval = max(0.1, deadline.timeIntervalSinceNow)
        snoozeWakeTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.clearSnooze() }
        }
    }

    /// Set or clear a per-session ready sound. Pass nil to remove.
    func setReadySound(_ sound: String?, forSessionId sessionId: String) {
        if let sound, !sound.isEmpty {
            perSessionReadySound[sessionId] = sound
        } else {
            perSessionReadySound.removeValue(forKey: sessionId)
        }
        UserDefaults.standard.set(perSessionReadySound, forKey: Keys.perSessionReadySound)
    }

    /// Set or clear a per-session attention sound. Pass nil to remove.
    func setAttentionSound(_ sound: String?, forSessionId sessionId: String) {
        if let sound, !sound.isEmpty {
            perSessionAttentionSound[sessionId] = sound
        } else {
            perSessionAttentionSound.removeValue(forKey: sessionId)
        }
        UserDefaults.standard.set(perSessionAttentionSound, forKey: Keys.perSessionAttentionSound)
    }

    func requestPermission() {
        guard Bundle.main.bundleIdentifier != nil else {
            ClydeLog.general.info("Skipping notification permission (no bundle id)")
            return
        }
        UNUserNotificationCenter.current().delegate = self
        Task {
            do {
                let granted = try await UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .sound])
                await MainActor.run { self.isAuthorized = granted }
            } catch {
                ClydeLog.general.error("Notification permission error: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Default fallbacks used when a configured sound name resolves to nil
    /// (deleted system sound, typo in UserDefaults, etc.).
    private static let fallbackReadySound = "Glass"
    private static let fallbackAttentionSound = "Hero"

    func playReadySound(for session: Session? = nil) {
        guard soundEnabled, !isSnoozed else { return }
        let name: String
        if let sid = session?.sessionId, let override = perSessionReadySound[sid] {
            name = override
        } else {
            name = readySound
        }
        playSound(named: name, fallback: Self.fallbackReadySound)
    }

    func playAttentionSound(for session: Session? = nil) {
        guard soundEnabled, !isSnoozed else { return }
        let name: String
        if let sid = session?.sessionId, let override = perSessionAttentionSound[sid] {
            name = override
        } else {
            name = attentionSound
        }
        playSound(named: name, fallback: Self.fallbackAttentionSound)
    }

    /// Plays a named NSSound, logging and falling back to a known-good
    /// sound if the requested one is missing or fails to start.
    private func playSound(named name: String, fallback: String) {
        if let sound = NSSound(named: NSSound.Name(name)) {
            if sound.play() { return }
            ClydeLog.general.warning("NSSound '\(name, privacy: .public)' refused to play; trying fallback")
        } else {
            ClydeLog.general.warning("NSSound '\(name, privacy: .public)' not found; trying fallback")
        }
        if let fb = NSSound(named: NSSound.Name(fallback)) {
            _ = fb.play()
        }
    }

    func buildNotificationContent(for session: Session) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "Clyde"
        content.body = "\(session.displayName) is ready"
        content.sound = .default
        content.userInfo = ["pid": session.pid]
        return content
    }

    func sendNotification(for session: Session) {
        guard systemNotificationsEnabled, isAuthorized, !isSnoozed else { return }
        let content = buildNotificationContent(for: session)
        let request = UNNotificationRequest(
            identifier: "session-\(session.pid)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Delegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let pid = response.notification.request.content.userInfo["pid"] as? pid_t {
            Task { @MainActor in self.onNotificationClicked?(pid) }
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
