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

    static let hookScript = ##"""
    #!/bin/bash
    # Clyde notification hook — signals Clyde about Claude session state transitions.
    # Installed automatically by Clyde. Safe to remove manually.
    #
    # Files are keyed by Claude's session_id (UUID from the hook payload), so
    # PID recycling cannot produce false positives. Each file's content is
    # JSON with the live PID + cwd, which Clyde reads to do PID-keyed lookups.
    #
    # Handles three event types:
    #   PermissionRequest → writes events/<session_id>.json (attention flag)
    #   UserPromptSubmit  → creates state/<session_id>-busy marker
    #   Stop              → removes state/<session_id>-busy marker

    set -e
    EVENTS_DIR="$HOME/.clyde/events"
    STATE_DIR="$HOME/.clyde/state"
    mkdir -p "$EVENTS_DIR" "$STATE_DIR"

    INPUT=$(cat 2>/dev/null || echo "{}")

    # Extract event_name + session_id + cwd in a single python call.
    # Output is three lines: event\nsession_id\ncwd
    PAYLOAD=$(printf '%s' "$INPUT" | /usr/bin/python3 -c "
    import json, sys
    try:
        d = json.loads(sys.stdin.read())
    except Exception:
        d = {}
    print(d.get('hook_event_name', 'unknown'))
    print(d.get('session_id', ''))
    print(d.get('cwd', ''))
    " 2>/dev/null || printf 'unknown\n\n\n')

    HOOK_EVENT=$(printf '%s' "$PAYLOAD" | sed -n '1p')
    SESSION_ID=$(printf '%s' "$PAYLOAD" | sed -n '2p')
    CWD=$(printf '%s' "$PAYLOAD" | sed -n '3p')

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

    case "$HOOK_EVENT" in
        SessionStart)
            cat > "$STATE_DIR/$KEY-info" <<EOF
    {"session_id": "$ESC_SID", "pid": $CLAUDE_PID, "cwd": "$ESC_CWD", "started_at": $TIMESTAMP}
    EOF
            ;;
        SessionEnd)
            rm -f "$STATE_DIR/$KEY-info" "$STATE_DIR/$KEY-busy" "$EVENTS_DIR/$KEY.json"
            ;;
        PermissionRequest)
            cat > "$EVENTS_DIR/$KEY.json" <<EOF
    {"session_id": "$ESC_SID", "pid": $CLAUDE_PID, "cwd": "$ESC_CWD", "event": "$HOOK_EVENT", "timestamp": $TIMESTAMP}
    EOF
            ;;
        UserPromptSubmit)
            cat > "$STATE_DIR/$KEY-busy" <<EOF
    {"session_id": "$ESC_SID", "pid": $CLAUDE_PID, "cwd": "$ESC_CWD", "timestamp": $TIMESTAMP}
    EOF
            ;;
        Stop)
            rm -f "$STATE_DIR/$KEY-busy"
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
    static let registeredHookEvents = [
        "SessionStart",
        "SessionEnd",
        "UserPromptSubmit",
        "Stop",
        "PermissionRequest",
    ]

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: AppPaths.clydeHookScript.path)
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
            let legacyEvents = ["Notification", "PreToolUse"]
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
