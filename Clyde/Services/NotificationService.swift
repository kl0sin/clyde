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

    private var isAuthorized = false
    var onNotificationClicked: ((pid_t) -> Void)?

    private enum Keys {
        static let soundEnabled = "soundEnabled"
        static let systemNotificationsEnabled = "systemNotificationsEnabled"
        static let readySound = "selectedSound" // legacy key, kept for compatibility
        static let attentionSound = "attentionSound"
        static let perSessionReadySound = "perSessionReadySound"
        static let perSessionAttentionSound = "perSessionAttentionSound"
    }

    override init() {
        let defaults = UserDefaults.standard
        self.soundEnabled = defaults.object(forKey: Keys.soundEnabled) as? Bool ?? true
        self.systemNotificationsEnabled = defaults.object(forKey: Keys.systemNotificationsEnabled) as? Bool ?? true
        self.readySound = defaults.string(forKey: Keys.readySound) ?? "Glass"
        self.attentionSound = defaults.string(forKey: Keys.attentionSound) ?? "Hero"
        self.perSessionReadySound = (defaults.dictionary(forKey: Keys.perSessionReadySound) as? [String: String]) ?? [:]
        self.perSessionAttentionSound = (defaults.dictionary(forKey: Keys.perSessionAttentionSound) as? [String: String]) ?? [:]
        super.init()
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

    func playReadySound(for session: Session? = nil) {
        guard soundEnabled else { return }
        let name: String
        if let sid = session?.sessionId, let override = perSessionReadySound[sid] {
            name = override
        } else {
            name = readySound
        }
        NSSound(named: NSSound.Name(name))?.play()
    }

    func playAttentionSound(for session: Session? = nil) {
        guard soundEnabled else { return }
        let name: String
        if let sid = session?.sessionId, let override = perSessionAttentionSound[sid] {
            name = override
        } else {
            name = attentionSound
        }
        NSSound(named: NSSound.Name(name))?.play()
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
        guard systemNotificationsEnabled, isAuthorized else { return }
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
