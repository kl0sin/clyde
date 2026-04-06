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

    private var isAuthorized = false
    var onNotificationClicked: ((pid_t) -> Void)?

    private enum Keys {
        static let soundEnabled = "soundEnabled"
        static let systemNotificationsEnabled = "systemNotificationsEnabled"
        static let readySound = "selectedSound" // legacy key, kept for compatibility
        static let attentionSound = "attentionSound"
    }

    override init() {
        let defaults = UserDefaults.standard
        self.soundEnabled = defaults.object(forKey: Keys.soundEnabled) as? Bool ?? true
        self.systemNotificationsEnabled = defaults.object(forKey: Keys.systemNotificationsEnabled) as? Bool ?? true
        self.readySound = defaults.string(forKey: Keys.readySound) ?? "Glass"
        self.attentionSound = defaults.string(forKey: Keys.attentionSound) ?? "Hero"
        super.init()
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

    func playReadySound() {
        guard soundEnabled else { return }
        NSSound(named: NSSound.Name(readySound))?.play()
    }

    func playAttentionSound() {
        guard soundEnabled else { return }
        NSSound(named: NSSound.Name(attentionSound))?.play()
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
