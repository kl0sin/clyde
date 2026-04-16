import Foundation
import os

/// Sends push notifications to external services (ntfy, Pushover, webhook)
/// when Claude Code sessions change state. Independent of the local
/// ``NotificationService`` — snooze does not suppress push delivery.
@MainActor
final class PushService: ObservableObject {

    // MARK: - Provider model

    enum Provider: String, Codable, CaseIterable, Identifiable {
        case none
        case ntfy
        case pushover
        case webhook

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .none:     return "Off"
            case .ntfy:     return "ntfy"
            case .pushover: return "Pushover"
            case .webhook:  return "Webhook"
            }
        }
    }

    enum Priority: String {
        case normal
        case high
    }

    struct PushError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // MARK: - Published config

    @Published var provider: Provider {
        didSet { save() }
    }

    // ntfy
    @Published var ntfyServer: String {
        didSet { save() }
    }
    @Published var ntfyTopic: String {
        didSet { save() }
    }
    @Published var ntfyToken: String {
        didSet { save() }
    }

    // Pushover
    @Published var pushoverUserKey: String {
        didSet { save() }
    }
    @Published var pushoverAppToken: String {
        didSet { save() }
    }

    // Webhook
    @Published var webhookURL: String {
        didSet { save() }
    }
    @Published var webhookMethod: String {
        didSet { save() }
    }

    // Triggers
    @Published var notifyOnIdle: Bool {
        didSet { save() }
    }
    @Published var notifyOnAttention: Bool {
        didSet { save() }
    }

    // MARK: - State

    /// Result of the last test push (transient, not persisted).
    @Published var lastTestResult: Result<String, PushError>?

    private let session = URLSession.shared

    // MARK: - Persistence keys

    private enum Keys {
        static let provider           = "pushProvider"
        static let ntfyServer         = "pushNtfyServer"
        static let ntfyTopic          = "pushNtfyTopic"
        static let ntfyToken          = "pushNtfyToken"
        static let pushoverUserKey    = "pushPushoverUserKey"
        static let pushoverAppToken   = "pushPushoverAppToken"
        static let webhookURL         = "pushWebhookURL"
        static let webhookMethod      = "pushWebhookMethod"
        static let notifyOnIdle       = "pushNotifyOnIdle"
        static let notifyOnAttention  = "pushNotifyOnAttention"
    }

    // MARK: - Init

    init() {
        let defaults = UserDefaults.standard
        self.provider          = Provider(rawValue: defaults.string(forKey: Keys.provider) ?? "") ?? .none
        self.ntfyServer        = defaults.string(forKey: Keys.ntfyServer) ?? "https://ntfy.sh"
        self.ntfyTopic         = defaults.string(forKey: Keys.ntfyTopic) ?? ""
        self.ntfyToken         = defaults.string(forKey: Keys.ntfyToken) ?? ""
        self.pushoverUserKey   = defaults.string(forKey: Keys.pushoverUserKey) ?? ""
        self.pushoverAppToken  = defaults.string(forKey: Keys.pushoverAppToken) ?? ""
        self.webhookURL        = defaults.string(forKey: Keys.webhookURL) ?? ""
        self.webhookMethod     = defaults.string(forKey: Keys.webhookMethod) ?? "POST"
        self.notifyOnIdle      = defaults.object(forKey: Keys.notifyOnIdle) as? Bool ?? true
        self.notifyOnAttention = defaults.object(forKey: Keys.notifyOnAttention) as? Bool ?? true
    }

    private func save() {
        let defaults = UserDefaults.standard
        defaults.set(provider.rawValue,  forKey: Keys.provider)
        defaults.set(ntfyServer,         forKey: Keys.ntfyServer)
        defaults.set(ntfyTopic,          forKey: Keys.ntfyTopic)
        defaults.set(ntfyToken,          forKey: Keys.ntfyToken)
        defaults.set(pushoverUserKey,    forKey: Keys.pushoverUserKey)
        defaults.set(pushoverAppToken,   forKey: Keys.pushoverAppToken)
        defaults.set(webhookURL,         forKey: Keys.webhookURL)
        defaults.set(webhookMethod,      forKey: Keys.webhookMethod)
        defaults.set(notifyOnIdle,       forKey: Keys.notifyOnIdle)
        defaults.set(notifyOnAttention,  forKey: Keys.notifyOnAttention)
    }

    /// True when the provider is configured with enough data to send.
    var isConfigured: Bool {
        switch provider {
        case .none:
            return false
        case .ntfy:
            return !ntfyTopic.trimmingCharacters(in: .whitespaces).isEmpty
        case .pushover:
            return !pushoverUserKey.trimmingCharacters(in: .whitespaces).isEmpty
                && !pushoverAppToken.trimmingCharacters(in: .whitespaces).isEmpty
        case .webhook:
            return !webhookURL.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    // MARK: - Session event hooks

    func notifySessionIdle(_ session: Session) {
        guard notifyOnIdle, isConfigured else { return }
        let project = session.projectName
        sendPush(
            title: "Session ready",
            message: "\(session.displayName) is ready\(project.map { " (\($0))" } ?? "")",
            priority: .normal
        )
    }

    func notifyAttentionNeeded(_ session: Session) {
        guard notifyOnAttention, isConfigured else { return }
        let project = session.projectName
        sendPush(
            title: "Action required",
            message: "\(session.displayName) needs input\(project.map { " (\($0))" } ?? "")",
            priority: .high
        )
    }

    // MARK: - Send

    func sendPush(title: String, message: String, priority: Priority) {
        Task.detached(priority: .utility) { [provider, self] in
            do {
                switch provider {
                case .none:
                    return
                case .ntfy:
                    try await self.sendNtfy(title: title, message: message, priority: priority)
                case .pushover:
                    try await self.sendPushover(title: title, message: message, priority: priority)
                case .webhook:
                    try await self.sendWebhook(title: title, message: message, priority: priority)
                }
                ClydeLog.general.info("Push sent via \(provider.rawValue, privacy: .public): \(title, privacy: .public)")
            } catch {
                ClydeLog.general.error("Push failed via \(provider.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Send a test notification and return the result.
    func testPush() async -> Result<String, PushError> {
        guard isConfigured else {
            return .failure(PushError(message: "Provider not configured"))
        }
        do {
            switch provider {
            case .none:
                return .failure(PushError(message: "No provider selected"))
            case .ntfy:
                try await sendNtfy(title: "Clyde test", message: "Push notifications are working!", priority: .normal)
            case .pushover:
                try await sendPushover(title: "Clyde test", message: "Push notifications are working!", priority: .normal)
            case .webhook:
                try await sendWebhook(title: "Clyde test", message: "Push notifications are working!", priority: .normal)
            }
            return .success("Notification sent via \(provider.displayName)")
        } catch {
            return .failure(PushError(message: error.localizedDescription))
        }
    }

    // MARK: - ntfy

    private func sendNtfy(title: String, message: String, priority: Priority) async throws {
        let server = await ntfyServer.trimmingCharacters(in: .whitespacesAndNewlines)
        let topic = await ntfyTopic.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = await ntfyToken.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let url = URL(string: "\(server)/\(topic)") else {
            throw PushError(message: "Invalid ntfy URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = message.data(using: .utf8)
        request.setValue(title, forHTTPHeaderField: "Title")
        request.setValue(priority == .high ? "5" : "3", forHTTPHeaderField: "Priority")
        request.setValue("robot", forHTTPHeaderField: "Tags")

        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw PushError(message: "ntfy returned HTTP \(code)")
        }
    }

    // MARK: - Pushover

    private func sendPushover(title: String, message: String, priority: Priority) async throws {
        let userKey = await pushoverUserKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let appToken = await pushoverAppToken.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let url = URL(string: "https://api.pushover.net/1/messages.json") else {
            throw PushError(message: "Invalid Pushover URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let pushoverPriority = priority == .high ? "1" : "0"
        let params = [
            "token": appToken,
            "user": userKey,
            "title": title,
            "message": message,
            "priority": pushoverPriority,
        ]
        request.httpBody = params
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(data: data, encoding: .utf8) ?? ""
            throw PushError(message: "Pushover returned HTTP \(code): \(body)")
        }
    }

    // MARK: - Webhook

    private func sendWebhook(title: String, message: String, priority: Priority) async throws {
        let urlString = await webhookURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let method = await webhookMethod

        guard let url = URL(string: urlString) else {
            throw PushError(message: "Invalid webhook URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method

        if method == "POST" {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let payload: [String: Any] = [
                "title": title,
                "message": message,
                "priority": priority.rawValue,
                "app": "clyde",
            ]
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        }

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...399).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw PushError(message: "Webhook returned HTTP \(code)")
        }
    }
}
