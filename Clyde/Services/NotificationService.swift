import Foundation
import UserNotifications
import AppKit

final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    private var isAuthorized = false
    var onNotificationClicked: ((pid_t) -> Void)?

    var soundEnabled: Bool = UserDefaults.standard.object(forKey: "soundEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(soundEnabled, forKey: "soundEnabled") }
    }

    var selectedSound: String = UserDefaults.standard.string(forKey: "selectedSound") ?? "Glass" {
        didSet { UserDefaults.standard.set(selectedSound, forKey: "selectedSound") }
    }

    var attentionSound: String = UserDefaults.standard.string(forKey: "attentionSound") ?? "Hero" {
        didSet { UserDefaults.standard.set(attentionSound, forKey: "attentionSound") }
    }

    func requestPermission() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().delegate = self
        Task {
            do {
                let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                await MainActor.run {
                    self.isAuthorized = granted
                }
            } catch {}
        }
    }

    func playReadySound() {
        guard soundEnabled else { return }
        NSSound(named: NSSound.Name(selectedSound))?.play()
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
        guard isAuthorized else { return }
        let content = buildNotificationContent(for: session)
        let request = UNNotificationRequest(
            identifier: "session-\(session.pid)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let pid = response.notification.request.content.userInfo["pid"] as? pid_t {
            onNotificationClicked?(pid)
        }
        completionHandler()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
