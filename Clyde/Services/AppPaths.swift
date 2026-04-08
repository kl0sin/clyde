import Foundation

/// Central registry of filesystem paths used by Clyde.
/// All paths are relative to the user's home directory.
enum AppPaths {
    static var clydeDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".clyde")
    }

    static var eventsDir: URL {
        clydeDir.appendingPathComponent("events")
    }

    /// Hook-driven session state (busy markers written by UserPromptSubmit,
    /// cleared by Stop).
    static var stateDir: URL {
        clydeDir.appendingPathComponent("state")
    }

    static func busyMarker(pid: pid_t) -> URL {
        stateDir.appendingPathComponent("\(pid)-busy")
    }

    static var logsDir: URL {
        clydeDir.appendingPathComponent("logs")
    }

    static var claudeDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
    }

    static var claudeHooksDir: URL {
        claudeDir.appendingPathComponent("hooks")
    }

    static var claudeSettingsFile: URL {
        claudeDir.appendingPathComponent("settings.json")
    }

    static var clydeHookScript: URL {
        claudeHooksDir.appendingPathComponent("clyde-hook.sh")
    }

    /// Legacy filename used by older Clyde builds. Kept here so the
    /// installer can migrate existing installs (delete the old file,
    /// remove the old settings.json entries) without leaving the user
    /// in a half-broken state.
    static var legacyClydeHookScript: URL {
        claudeHooksDir.appendingPathComponent("clyde-notify.sh")
    }
}

enum AppConstants {
    /// How often to poll for Claude process state changes
    static let defaultPollingInterval: TimeInterval = 3.0

    /// How long a hook-signalled attention event remains valid
    static let attentionEventTimeout: TimeInterval = 60.0

    /// Busy markers are sticky: a marker is considered valid as long as the
    /// owning Claude process is alive (`kill(pid, 0) == 0`). They are removed
    /// only by the hook script on Stop / StopFailure / SessionEnd / interrupt,
    /// or by Clyde itself when the PID disappears. We used to expire them on
    /// mtime staleness (~120s), but that broke two real scenarios:
    ///   1. Long pure-text turns (8–10 min of "thinking" with no tool calls)
    ///      would briefly drop to "ready" mid-turn.
    ///   2. Long permission prompts would expire the marker while the user
    ///      was still picking an option, so resolving the prompt left the
    ///      session stuck in "ready" instead of returning to "working".
    /// Process liveness is the only correct signal for "is this turn over?".

    /// After a Claude session ends, keep the row visible as a ghost for this long.
    static let endedSessionLinger: TimeInterval = 300.0  // 5 minutes

    /// Distance from screen edge to trigger widget snap
    static let edgeSnapThreshold: CGFloat = 36.0

    /// Margin from screen edge when snapping
    static let edgeSnapMargin: CGFloat = 12.0
}
