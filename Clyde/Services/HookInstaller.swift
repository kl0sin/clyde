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

    static let hookScript = """
    #!/bin/bash
    # Clyde notification hook — signals Clyde that a Claude session needs attention
    # Installed automatically by Clyde. Safe to remove manually.

    set -e
    EVENTS_DIR="$HOME/.clyde/events"
    mkdir -p "$EVENTS_DIR"

    INPUT=$(cat 2>/dev/null || echo "{}")
    HOOK_EVENT=$(echo "$INPUT" | /usr/bin/python3 -c "import json,sys; d=json.load(sys.stdin) if sys.stdin.read() else {}; print(d.get('hook_event_name', 'unknown'))" 2>/dev/null || echo "unknown")

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

    if [ -n "$CLAUDE_PID" ]; then
        TIMESTAMP=$(date +%s)
        cat > "$EVENTS_DIR/$CLAUDE_PID.json" <<EOF
    {"pid": $CLAUDE_PID, "event": "$HOOK_EVENT", "timestamp": $TIMESTAMP}
    EOF
    fi

    exit 0
    """

    static var hookScriptPath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/hooks/clyde-notify.sh")
    }

    static var settingsPath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: hookScriptPath.path)
    }

    static func install() throws {
        // 1. Write hook script
        let scriptDir = hookScriptPath.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: scriptDir, withIntermediateDirectories: true)
        do {
            try hookScript.write(to: hookScriptPath, atomically: true, encoding: .utf8)
        } catch {
            throw InstallError.writeFailed(error.localizedDescription)
        }

        // Make executable
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookScriptPath.path)

        // 2. Merge hook config into settings.json
        var settings: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsPath),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = parsed
        }

        var hooks = settings["hooks"] as? [String: Any] ?? [:]

        // Add Clyde hook for Notification events
        let hookCommand: [String: Any] = [
            "type": "command",
            "command": hookScriptPath.path
        ]
        let hookBlock: [String: Any] = [
            "hooks": [hookCommand]
        ]

        // Notification: fires when Claude is waiting for user (idle prompt)
        mergeHookBlock(&hooks, eventName: "Notification", block: hookBlock)
        // PermissionRequest: fires when permission dialog appears
        mergeHookBlock(&hooks, eventName: "PermissionRequest", block: hookBlock)

        settings["hooks"] = hooks

        do {
            let data = try JSONSerialization.data(
                withJSONObject: settings,
                options: [.prettyPrinted, .sortedKeys]
            )
            try data.write(to: settingsPath)
        } catch {
            throw InstallError.writeFailed(error.localizedDescription)
        }
    }

    static func uninstall() throws {
        // Remove hook script
        try? FileManager.default.removeItem(at: hookScriptPath)

        // Remove from settings.json
        guard let data = try? Data(contentsOf: settingsPath),
              var settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        if var hooks = settings["hooks"] as? [String: Any] {
            removeClydeHook(&hooks, eventName: "Notification")
            removeClydeHook(&hooks, eventName: "PermissionRequest")
            settings["hooks"] = hooks
        }

        if let newData = try? JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys]
        ) {
            try? newData.write(to: settingsPath)
        }
    }

    private static func mergeHookBlock(_ hooks: inout [String: Any], eventName: String, block: [String: Any]) {
        var existing = hooks[eventName] as? [[String: Any]] ?? []

        // Check if our hook is already there
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
