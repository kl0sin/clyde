import Foundation

/// A permission request waiting for an answer, as the hook recorded it.
///
/// The hook writes one file per request into `~/.clyde/permissions/` and
/// waits a few seconds for a decision beside it. Everything here comes
/// from that file — Clyde never infers what is being asked.
struct PermissionRequest: Identifiable, Equatable {
    let id: String
    let sessionId: String
    let pid: pid_t
    let cwd: String
    let toolName: String
    let summary: String
    let expiresAt: Date

    /// False once the hook has stopped waiting. The terminal is asking
    /// its own question by then, and answering here would go nowhere.
    var isLive: Bool { expiresAt > Date() }

    init?(fileURL: URL) {
        guard let data = try? Data(contentsOf: fileURL),
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = body["request_id"] as? String,
              let expires = body["expires_at"] as? Double
        else { return nil }

        self.id = id
        self.sessionId = body["session_id"] as? String ?? ""
        self.pid = pid_t(body["pid"] as? Int ?? 0)
        self.cwd = body["cwd"] as? String ?? ""
        let tool = body["tool_name"] as? String ?? ""
        self.toolName = tool
        self.summary = Self.summary(tool: tool, input: body["tool_input"] as? [String: Any] ?? [:])
        self.expiresAt = Date(timeIntervalSince1970: expires)
    }

    /// What the row shows beside the tool name.
    ///
    /// Never abbreviated. A shortened command invites approving
    /// something the user did not read, which is the one habit this
    /// feature must not encourage — the row scrolls instead.
    static func summary(tool: String, input: [String: Any]) -> String {
        if let command = input["command"] as? String { return command }
        if let path = input["file_path"] as? String { return path }
        if let path = input["path"] as? String { return path }
        if let url = input["url"] as? String { return url }
        guard !input.isEmpty else { return "no arguments" }
        // An unfamiliar tool — most likely from an MCP server — still
        // gets shown truthfully rather than described.
        let data = try? JSONSerialization.data(withJSONObject: input,
                                               options: [.sortedKeys, .withoutEscapingSlashes])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "no arguments"
    }
}

enum PermissionDecision: String {
    case allow
    case deny
}
