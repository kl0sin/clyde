import Foundation

/// Installs the Clyde notification hook into Claude's settings.
/// Creates the hook script at ~/.claude/hooks/clyde-notify.sh and
/// merges the hook configuration into ~/.claude/settings.json.
enum HookInstaller {
    enum InstallError: LocalizedError {
        case writeFailed(String)
        case parseFailed

        var errorDescription: String? {
            switch self {
            case .writeFailed(let msg): return "Failed to write: \(msg)"
            case .parseFailed: return "Failed to parse existing ~/.claude/settings.json"
            }
        }
    }

    /// Bumped whenever the embedded hook script changes. The version line is
    /// embedded in the script itself; Clyde reads it from the installed copy
    /// at startup and prompts a reinstall if it's older.
    static let currentScriptVersion = 9

    static let hookScript = ##"""
    #!/bin/bash
    # clyde-hook-version: 9
    # Clyde notification hook — signals Clyde about Claude session state transitions.
    # Installed automatically by Clyde. Safe to remove manually.
    #
    # Files are keyed by Claude's session_id (UUID from the hook payload), so
    # PID recycling cannot produce false positives. Each file's content is
    # JSON with the live PID + cwd, which Clyde reads to do PID-keyed lookups.
    #
    # Writes are atomic (mktemp + mv) so concurrent hooks can't corrupt files.
    #
    # Handled events:
    #   SessionStart      → state/<session_id>-info (alive marker)
    #   SessionEnd        → removes info + busy + event for that session
    #   UserPromptSubmit  → state/<session_id>-busy marker
    #   Stop              → removes busy marker
    #   PermissionRequest → events/<session_id>.json (attention flag)

    set -e
    EVENTS_DIR="$HOME/.clyde/events"
    STATE_DIR="$HOME/.clyde/state"
    mkdir -p "$EVENTS_DIR" "$STATE_DIR"

    INPUT=$(cat 2>/dev/null || echo "{}")

    # Extract a top-level string field from the Claude hook payload.
    # Tries python3 first; falls back to a grep-based parser if python3 is
    # missing (Apple keeps threatening to remove the system Python).
    extract_field() {
        local key=$1
        local value=""

        if command -v python3 >/dev/null 2>&1; then
            value=$(printf '%s' "$INPUT" | python3 -c "
    import json, sys
    try:
        d = json.loads(sys.stdin.read())
    except Exception:
        d = {}
    print(d.get('$key', ''))
    " 2>/dev/null) || value=""
        fi

        if [ -z "$value" ]; then
            # Pure-shell fallback: grep the JSON for "key": "value".
            # Handles the common case of unescaped string values (Claude's
            # hook payloads have well-formed UUIDs and absolute paths).
            value=$(printf '%s' "$INPUT" \
                | tr -d '\n' \
                | grep -o "\"$key\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" \
                | head -n1 \
                | sed -E 's/.*"([^"]*)"$/\1/')
        fi

        printf '%s' "$value"
    }

    HOOK_EVENT=$(extract_field hook_event_name)
    SESSION_ID=$(extract_field session_id)
    CWD=$(extract_field cwd)
    [ -z "$HOOK_EVENT" ] && HOOK_EVENT="unknown"

    find_claude_pid() {
        local pid=$PPID
        local depth=0
        while [ "$pid" -gt 1 ] && [ "$depth" -lt 10 ]; do
            local name=$(ps -p "$pid" -o comm= 2>/dev/null | tr -d ' ')
            if [ "$(basename "$name")" = "claude" ]; then
                echo "$pid"
                return 0
            fi
            pid=$(ps -p "$pid" -o ppid= 2>/dev/null | tr -d ' ')
            depth=$((depth + 1))
        done
        return 1
    }

    CLAUDE_PID=$(find_claude_pid || echo "")
    [ -z "$CLAUDE_PID" ] && exit 0

    # Fall back to PID-based key if Claude didn't supply session_id.
    KEY="${SESSION_ID:-$CLAUDE_PID}"
    TIMESTAMP=$(date +%s)

    # JSON-escape cwd for safe embedding (just escape backslashes and quotes).
    ESC_CWD=$(printf '%s' "$CWD" | sed 's/\\/\\\\/g; s/"/\\"/g')
    ESC_SID=$(printf '%s' "$SESSION_ID" | sed 's/\\/\\\\/g; s/"/\\"/g')

    # Atomic write helper: stage to a temp file in the same dir, then mv.
    atomic_write() {
        local target=$1
        local body=$2
        local tmp
        tmp=$(mktemp "$(dirname "$target")/.clyde-tmp.XXXXXX") || return 1
        printf '%s\n' "$body" > "$tmp"
        mv -f "$tmp" "$target"
    }

    case "$HOOK_EVENT" in
        SessionStart)
            atomic_write "$STATE_DIR/$KEY-info" \
                "{\"session_id\": \"$ESC_SID\", \"pid\": $CLAUDE_PID, \"cwd\": \"$ESC_CWD\", \"started_at\": $TIMESTAMP}"
            ;;
        SessionEnd)
            rm -f "$STATE_DIR/$KEY-info" "$STATE_DIR/$KEY-busy" "$EVENTS_DIR/$KEY.json"
            ;;
        PermissionRequest)
            atomic_write "$EVENTS_DIR/$KEY.json" \
                "{\"session_id\": \"$ESC_SID\", \"pid\": $CLAUDE_PID, \"cwd\": \"$ESC_CWD\", \"event\": \"$HOOK_EVENT\", \"timestamp\": $TIMESTAMP}"
            ;;
        UserPromptSubmit)
            atomic_write "$STATE_DIR/$KEY-busy" \
                "{\"session_id\": \"$ESC_SID\", \"pid\": $CLAUDE_PID, \"cwd\": \"$ESC_CWD\", \"timestamp\": $TIMESTAMP}"
            # If this is an existing session that predates Clyde, the
            # SessionStart hook never fired for it. Backfill -info so the
            # session "graduates" to full hook tracking from now on.
            if [ ! -f "$STATE_DIR/$KEY-info" ]; then
                atomic_write "$STATE_DIR/$KEY-info" \
                    "{\"session_id\": \"$ESC_SID\", \"pid\": $CLAUDE_PID, \"cwd\": \"$ESC_CWD\", \"started_at\": $TIMESTAMP}"
            fi
            ;;
        Stop)
            # Clear both the busy marker AND any pending attention event for
            # this session. Stop means the turn is over — any permission
            # request inside that turn has been resolved by the user.
            rm -f "$STATE_DIR/$KEY-busy" "$EVENTS_DIR/$KEY.json"
            ;;
        PreToolUse)
            # Tools can only run after permission was granted, so clear any
            # pending attention flag. The session stays busy via its marker.
            rm -f "$EVENTS_DIR/$KEY.json"
            ;;
    esac

    exit 0
    """##

    /// Claude Code hook events that Clyde registers for.
    /// - `SessionStart`: a Claude session is born → write info file
    /// - `SessionEnd`:   a Claude session exits → drop info + busy markers
    /// - `UserPromptSubmit`: user sent a new prompt → busy start
    /// - `Stop`: Claude finished responding → busy end
    /// - `PermissionRequest`: Claude needs user approval → attention
    /// - `PreToolUse`: Claude is about to run a tool → permission was resolved,
    ///                 so clear any pending attention flag
    static let registeredHookEvents = [
        "SessionStart",
        "SessionEnd",
        "UserPromptSubmit",
        "Stop",
        "PermissionRequest",
        "PreToolUse",
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
            return nil
        }
        // Match a line like "# clyde-hook-version: 2".
        for line in data.components(separatedBy: "\n").prefix(10) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("#") else { continue }
            if let range = trimmed.range(of: "clyde-hook-version:") {
                let value = trimmed[range.upperBound...].trimmingCharacters(in: .whitespaces)
                return Int(value)
            }
        }
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

        do {
            try hookScript.write(to: AppPaths.clydeHookScript, atomically: true, encoding: .utf8)
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
        try? FileManager.default.removeItem(at: AppPaths.clydeHookScript)

        guard let data = try? Data(contentsOf: AppPaths.claudeSettingsFile),
              var settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            ClydeLog.hooks.info("Hook uninstalled (no settings to clean)")
            return
        }

        if var hooks = settings["hooks"] as? [String: Any] {
            // Clean up all currently registered events plus any legacy ones we may have used before.
            let legacyEvents = ["Notification"]
            for eventName in Self.registeredHookEvents + legacyEvents {
                removeClydeHook(&hooks, eventName: eventName)
            }
            settings["hooks"] = hooks
        }

        if let newData = try? JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys]
        ) {
            do {
                try newData.write(to: AppPaths.claudeSettingsFile)
                ClydeLog.hooks.info("Hook uninstalled successfully")
            } catch {
                ClydeLog.hooks.error("Failed to write cleaned settings: \(error.localizedDescription, privacy: .public)")
                throw InstallError.writeFailed(error.localizedDescription)
            }
        }
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
