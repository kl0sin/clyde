import Foundation

/// Installs the Clyde notification hook into Claude's settings.
/// Creates the hook script at ~/.claude/hooks/clyde-notify.sh and
/// merges the hook configuration into ~/.claude/settings.json.
enum HookInstaller {
    enum InstallError: LocalizedError {
        case writeFailed(String)
        case parseFailed
        case bundledScriptMissing

        var errorDescription: String? {
            switch self {
            case .writeFailed(let msg): return "Failed to write: \(msg)"
            case .parseFailed: return "Failed to parse existing ~/.claude/settings.json"
            case .bundledScriptMissing:
                return "The bundled hook script (clyde-hook.sh) is missing from the app. Reinstall Clyde."
            }
        }
    }

    /// Bumped whenever the embedded hook script changes. The version line is
    /// embedded in the script itself; Clyde reads it from the installed copy
    /// at startup and prompts a reinstall if it's older.
    ///
    /// MUST stay in sync with the `clyde-hook-version` line at the top of
    /// `Clyde/Resources/clyde-hook.sh`.
    static let currentScriptVersion = 13

    /// Loads the hook script source from the bundled resource. The script
    /// itself lives in `Clyde/Resources/clyde-hook.sh` so it can be edited
    /// with proper bash highlighting and tested in isolation.
    ///
    /// Throws `InstallError.bundledScriptMissing` if the resource was lost
    /// from the app bundle (e.g. corrupted install). Previously this was a
    /// `preconditionFailure` that crashed the app on every property access.
    static func loadHookScript() throws -> String {
        guard let url = Bundle.module.url(forResource: "clyde-hook", withExtension: "sh"),
              let contents = try? String(contentsOf: url, encoding: .utf8) else {
            ClydeLog.hooks.error("Bundled clyde-hook.sh resource is missing")
            throw InstallError.bundledScriptMissing
        }
        return contents
    }

    /// Claude Code hook events that Clyde registers for.
    /// - `SessionStart`: a Claude session is born → write info file
    /// - `SessionEnd`:   a Claude session exits → drop info + busy markers
    /// - `UserPromptSubmit`: user sent a new prompt → busy start
    /// - `Stop`: Claude finished responding → busy end
    /// - `StopFailure`: turn ended due to API error → busy end (abnormal)
    /// - `PermissionRequest`: Claude needs user approval → attention
    /// - `PreToolUse`: Claude is about to run a tool → permission was resolved,
    ///                 plus refresh busy marker mtime so it doesn't go stale
    /// - `PostToolUseFailure`: tool failed; if `is_interrupt: true` (user
    ///                 Ctrl+C), drop the busy marker immediately
    static let registeredHookEvents = [
        "SessionStart",
        "SessionEnd",
        "UserPromptSubmit",
        "Stop",
        "StopFailure",
        "PermissionRequest",
        "PreToolUse",
        "PostToolUseFailure",
    ]

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: AppPaths.clydeHookScript.path)
    }

    /// Result of the startup health check.
    enum HealthIssue: Equatable {
        case notInstalled
        case scriptMissing                      // settings registers it but file is gone
        case scriptNotExecutable
        case outdated(installed: Int, current: Int)
        case missingEvents([String])            // events that are missing from settings.json
        case autoRepairFailed(reason: String)   // we tried to fix it and write threw

        var bannerMessage: String {
            switch self {
            case .notInstalled:
                return "Claude hook not installed. Real-time tracking is disabled."
            case .scriptMissing:
                return "Hook script is missing. Reinstall to restore real-time tracking."
            case .scriptNotExecutable:
                return "Hook script isn't executable. Reinstall to fix permissions."
            case .outdated(let installed, let current):
                return "Hook script is outdated (v\(installed) → v\(current)). Reinstall to upgrade."
            case .missingEvents(let names):
                return "Hook isn't registered for: \(names.joined(separator: ", ")). Reinstall to fix."
            case .autoRepairFailed(let reason):
                return "Auto-repair failed: \(reason). Open Settings and reinstall manually."
            }
        }
    }

    /// Inspect the installed hook on disk and the settings.json registration.
    /// Returns nil if everything looks healthy.
    static func healthCheck() -> HealthIssue? {
        let scriptPath = AppPaths.clydeHookScript.path
        let scriptExists = FileManager.default.fileExists(atPath: scriptPath)

        // No script at all → user simply hasn't installed yet.
        if !scriptExists {
            // If the user previously installed but the script vanished, the
            // settings.json will still reference it. Treat that as a corruption
            // worth flagging; otherwise it's just "not installed yet".
            if isRegisteredInSettings(eventName: registeredHookEvents.first ?? "") {
                return .scriptMissing
            }
            return .notInstalled
        }

        // Script exists — check executable bit.
        if let attrs = try? FileManager.default.attributesOfItem(atPath: scriptPath),
           let perms = attrs[.posixPermissions] as? NSNumber,
           (perms.intValue & 0o111) == 0 {
            return .scriptNotExecutable
        }

        // Version stamp.
        if let installedVersion = readInstalledVersion(),
           installedVersion < currentScriptVersion {
            return .outdated(installed: installedVersion, current: currentScriptVersion)
        }

        // Settings registration for every required event.
        let missing = registeredHookEvents.filter { !isRegisteredInSettings(eventName: $0) }
        if !missing.isEmpty {
            return .missingEvents(missing)
        }

        return nil
    }

    private static func readInstalledVersion() -> Int? {
        guard let data = try? String(contentsOf: AppPaths.clydeHookScript, encoding: .utf8) else {
            ClydeLog.hooks.warning("Could not read installed hook script for version check")
            return nil
        }
        // Match a line like "# clyde-hook-version: 2".
        for line in data.components(separatedBy: "\n").prefix(20) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("#") else { continue }
            if let range = trimmed.range(of: "clyde-hook-version:") {
                let value = trimmed[range.upperBound...].trimmingCharacters(in: .whitespaces)
                if let parsed = Int(value) { return parsed }
                ClydeLog.hooks.warning("Hook version line present but unparseable: \(value, privacy: .public)")
                return nil
            }
        }
        ClydeLog.hooks.warning("Installed hook script has no clyde-hook-version line")
        return nil
    }

    private static func isRegisteredInSettings(eventName: String) -> Bool {
        guard let data = try? Data(contentsOf: AppPaths.claudeSettingsFile),
              let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = settings["hooks"] as? [String: Any],
              let events = hooks[eventName] as? [[String: Any]] else {
            return false
        }
        for entry in events {
            if let inner = entry["hooks"] as? [[String: Any]] {
                for h in inner {
                    if let cmd = h["command"] as? String, cmd.contains("clyde-notify.sh") {
                        return true
                    }
                }
            }
        }
        return false
    }

    static func install() throws {
        // 1. Write hook script
        try FileManager.default.createDirectory(
            at: AppPaths.claudeHooksDir,
            withIntermediateDirectories: true
        )

        let scriptContents = try loadHookScript()
        do {
            try scriptContents.write(to: AppPaths.clydeHookScript, atomically: true, encoding: .utf8)
        } catch {
            ClydeLog.hooks.error("Failed to write hook script: \(error.localizedDescription, privacy: .public)")
            throw InstallError.writeFailed(error.localizedDescription)
        }

        // Make executable
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: AppPaths.clydeHookScript.path
        )

        // 2. Merge hook config into settings.json
        var settings: [String: Any] = [:]
        if let data = try? Data(contentsOf: AppPaths.claudeSettingsFile),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = parsed
        }

        var hooks = settings["hooks"] as? [String: Any] ?? [:]

        let hookCommand: [String: Any] = [
            "type": "command",
            "command": AppPaths.clydeHookScript.path
        ]
        let hookBlock: [String: Any] = ["hooks": [hookCommand]]

        for eventName in Self.registeredHookEvents {
            mergeHookBlock(&hooks, eventName: eventName, block: hookBlock)
        }
        settings["hooks"] = hooks

        do {
            let data = try JSONSerialization.data(
                withJSONObject: settings,
                options: [.prettyPrinted, .sortedKeys]
            )
            try data.write(to: AppPaths.claudeSettingsFile)
            ClydeLog.hooks.info("Hook installed successfully")
        } catch {
            ClydeLog.hooks.error("Failed to write settings.json: \(error.localizedDescription, privacy: .public)")
            throw InstallError.writeFailed(error.localizedDescription)
        }
    }

    static func uninstall() throws {
        // Order matters: we must remove the registration from settings.json
        // BEFORE deleting the script file on disk. Otherwise there's a window
        // where Claude Code still thinks the hook exists but the file is gone,
        // and every hook invocation in that window errors with
        // "No such file or directory".
        if let data = try? Data(contentsOf: AppPaths.claudeSettingsFile),
           var settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {

            if var hooks = settings["hooks"] as? [String: Any] {
                // Clean up all currently registered events plus any legacy ones
                // we may have used before.
                let legacyEvents = ["Notification"]
                for eventName in Self.registeredHookEvents + legacyEvents {
                    removeClydeHook(&hooks, eventName: eventName)
                }
                settings["hooks"] = hooks
            }

            do {
                let newData = try JSONSerialization.data(
                    withJSONObject: settings,
                    options: [.prettyPrinted, .sortedKeys]
                )
                try newData.write(to: AppPaths.claudeSettingsFile)
            } catch {
                ClydeLog.hooks.error("Failed to write cleaned settings: \(error.localizedDescription, privacy: .public)")
                throw InstallError.writeFailed(error.localizedDescription)
            }
        } else {
            ClydeLog.hooks.info("Hook uninstalled (no settings to clean)")
        }

        // Only now, once settings.json no longer references the script, is it
        // safe to delete the file itself.
        try? FileManager.default.removeItem(at: AppPaths.clydeHookScript)
        ClydeLog.hooks.info("Hook uninstalled successfully")
    }

    private static func mergeHookBlock(_ hooks: inout [String: Any], eventName: String, block: [String: Any]) {
        var existing = hooks[eventName] as? [[String: Any]] ?? []

        let alreadyPresent = existing.contains { entry in
            if let innerHooks = entry["hooks"] as? [[String: Any]] {
                return innerHooks.contains { h in
                    (h["command"] as? String)?.contains("clyde-notify.sh") == true
                }
            }
            return false
        }

        if !alreadyPresent {
            existing.append(block)
            hooks[eventName] = existing
        }
    }

    private static func removeClydeHook(_ hooks: inout [String: Any], eventName: String) {
        guard var existing = hooks[eventName] as? [[String: Any]] else { return }
        existing.removeAll { entry in
            if let innerHooks = entry["hooks"] as? [[String: Any]] {
                return innerHooks.contains { h in
                    (h["command"] as? String)?.contains("clyde-notify.sh") == true
                }
            }
            return false
        }
        if existing.isEmpty {
            hooks.removeValue(forKey: eventName)
        } else {
            hooks[eventName] = existing
        }
    }
}
