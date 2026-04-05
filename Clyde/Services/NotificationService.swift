import Foundation
import UserNotifications

final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    private var isAuthorized = false
    var onNotificationClicked: ((pid_t) -> Void)?

    func requestPermission() {
        // UNUserNotificationCenter requires a valid app bundle (won't work from bare executable)
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().delegate = self
        Task {
            do {
                let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                await MainActor.run {
                    self.isAuthorized = granted
                }
            } catch {
                // Permission denied or unavailable — notifications will be silently skipped
            }
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
