import Foundation

/// Installs the status-line wrapper and owns the one `statusLine` slot
/// in `~/.claude/settings.json`.
///
/// The slot is shared: whatever the user had there before is stored in
/// `~/.clyde/usage/passthrough` and run by the wrapper with the same
/// stdin, and put back when the feature is turned off. Kept outside
/// settings.json so a hand edit there cannot lose it.
enum UsageLimitsInstaller {

    /// MUST stay in sync with the `clyde-statusline-version` line at the
    /// top of `Clyde/Resources/clyde-statusline.sh`.
    static let currentScriptVersion = 1

    /// The Settings toggle. Off by default: a configured status line is
    /// visible in the terminal in a way the hook is not.
    static let settingKey = "showUsageLimits"
    /// Set when the user closes the one-time offer chip.
    static let offerDismissedKey = "usageLimitsOfferDismissed"

    enum Issue: Equatable {
        case notInstalled
        case scriptMissing
        case scriptVersionUnreadable
        case outdated(installed: Int, current: Int)
        /// Something else took the slot after Clyde did.
        case displaced(by: String)

        var message: String {
            switch self {
            case .notInstalled:
                return "The status line wrapper is not installed."
            case .scriptMissing:
                return "The status line wrapper is registered but its script is gone. Turn the setting off and on to reinstall it."
            case .scriptVersionUnreadable:
                return "The status line wrapper on disk carries no readable version. Turn the setting off and on to replace it."
            case .outdated(let installed, let current):
                return "The status line wrapper is outdated (v\(installed) → v\(current)). Turn the setting off and on to upgrade it."
            case .displaced(let command):
                return "Another status line replaced Clyde's (\(command)). Turn the setting off and on to adopt it and put Clyde's wrapper back in front."
            }
        }
    }

    enum InstallError: LocalizedError, Equatable {
        case parseFailed
        case writeFailed(String)
        case bundledScriptMissing

        var errorDescription: String? {
            switch self {
            case .parseFailed: return "Failed to parse existing ~/.claude/settings.json"
            case .writeFailed(let msg): return "Failed to write: \(msg)"
            case .bundledScriptMissing: return "The bundled status line script is missing from the app. Reinstall Clyde."
            }
        }
    }

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: settingKey)
    }

    /// Test override for `shouldOffer()`. Production never sets it.
    nonisolated(unsafe) static var offerOverride: Bool?

    /// Whether the panel should carry the one-time "Clyde can show your
    /// limits" chip: only while the feature is off and the chip has
    /// never been closed.
    static func shouldOffer(defaults: UserDefaults = .standard) -> Bool {
        if let override = offerOverride { return override }
        if defaults.bool(forKey: settingKey) { return false }
        return !defaults.bool(forKey: offerDismissedKey)
    }

    static func isClydeStatusLineCommand(_ cmd: String) -> Bool {
        cmd.contains("clyde-statusline.sh")
    }

    static func loadScript() throws -> String {
        guard let url = Bundle.module.url(forResource: "clyde-statusline", withExtension: "sh"),
              let contents = try? String(contentsOf: url, encoding: .utf8) else {
            ClydeLog.hooks.error("Bundled clyde-statusline.sh resource is missing")
            throw InstallError.bundledScriptMissing
        }
        return contents
    }

    // MARK: - Settings I/O

    private static func readSettings() throws -> [String: Any] {
        guard let data = try? Data(contentsOf: AppPaths.claudeSettingsFile), !data.isEmpty else {
            return [:]
        }
        guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            ClydeLog.hooks.error("settings.json is unparseable — refusing to overwrite it")
            throw InstallError.parseFailed
        }
        return parsed
    }

    private static func writeSettings(_ settings: [String: Any]) throws {
        do {
            try FileManager.default.createDirectory(at: AppPaths.claudeDir, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: AppPaths.claudeSettingsFile, options: .atomic)
            // The settings.json watcher in AppViewModel suppresses the
            // echo of Clyde's own writes by this timestamp; ours count.
            HookInstaller.lastSelfWriteAt = Date()
        } catch {
            throw InstallError.writeFailed(error.localizedDescription)
        }
    }

    private static func configuredCommand(in settings: [String: Any]) -> String? {
        (settings["statusLine"] as? [String: Any])?["command"] as? String
    }

    // MARK: - Install / uninstall

    static func install() throws {
        var settings = try readSettings()

        try FileManager.default.createDirectory(at: AppPaths.claudeHooksDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: AppPaths.usageDir, withIntermediateDirectories: true)
        let script = try loadScript()
        do {
            try script.write(to: AppPaths.clydeStatusLineScript, atomically: true, encoding: .utf8)
        } catch {
            throw InstallError.writeFailed(error.localizedDescription)
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                               ofItemAtPath: AppPaths.clydeStatusLineScript.path)

        var statusLine = settings["statusLine"] as? [String: Any] ?? [:]
        if let theirs = configuredCommand(in: settings), !isClydeStatusLineCommand(theirs) {
            // Theirs goes behind ours. Overwrites an older stored
            // command on purpose: a user who changed status lines while
            // the feature was off means the new one.
            try theirs.write(to: AppPaths.usagePassthroughFile, atomically: true, encoding: .utf8)
        } else if configuredCommand(in: settings) == nil {
            try? FileManager.default.removeItem(at: AppPaths.usagePassthroughFile)
        }
        statusLine["type"] = "command"
        statusLine["command"] = AppPaths.clydeStatusLineScript.path
        settings["statusLine"] = statusLine
        try writeSettings(settings)
        ClydeLog.hooks.info("Status line wrapper installed")
    }

    static func uninstall() throws {
        var settings = try readSettings()
        if let configured = configuredCommand(in: settings), isClydeStatusLineCommand(configured) {
            var statusLine = settings["statusLine"] as? [String: Any] ?? [:]
            if let theirs = try? String(contentsOf: AppPaths.usagePassthroughFile, encoding: .utf8),
               !theirs.isEmpty {
                statusLine["command"] = theirs
                settings["statusLine"] = statusLine
            } else {
                settings["statusLine"] = nil
            }
            try writeSettings(settings)
        }
        // Only once settings.json no longer points at it.
        try? FileManager.default.removeItem(at: AppPaths.clydeStatusLineScript)
        try? FileManager.default.removeItem(at: AppPaths.usagePassthroughFile)
        try? FileManager.default.removeItem(at: AppPaths.usageSnapshotFile)
        ClydeLog.hooks.info("Status line wrapper uninstalled")
    }

    // MARK: - Health

    static func installedScriptVersion() -> Int? {
        guard let source = try? String(contentsOf: AppPaths.clydeStatusLineScript, encoding: .utf8) else {
            return nil
        }
        for line in source.split(separator: "\n").prefix(5) {
            if let range = line.range(of: "# clyde-statusline-version: ") {
                return Int(line[range.upperBound...].trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }

    static func healthCheck() -> Issue? {
        let settings = (try? readSettings()) ?? [:]
        let configured = configuredCommand(in: settings)
        let scriptExists = FileManager.default.fileExists(atPath: AppPaths.clydeStatusLineScript.path)

        if let configured, !isClydeStatusLineCommand(configured) {
            return scriptExists ? .displaced(by: configured) : .notInstalled
        }
        guard configured != nil else { return .notInstalled }
        guard scriptExists else { return .scriptMissing }
        guard let version = installedScriptVersion() else { return .scriptVersionUnreadable }
        if version < currentScriptVersion {
            return .outdated(installed: version, current: currentScriptVersion)
        }
        return nil
    }
}
