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
        claudeHooksDir.appendingPathComponent("clyde-notify.sh")
    }
}

enum AppConstants {
    /// How often to poll for Claude process state changes
    static let defaultPollingInterval: TimeInterval = 3.0

    /// How long a hook-signalled attention event remains valid
    static let attentionEventTimeout: TimeInterval = 60.0

    /// How long a busy marker file remains "fresh" before Clyde considers it
    /// stale and stops counting the session as busy. The hook script touches
    /// the marker on every PreToolUse event, so an actively-working session
    /// keeps refreshing it. The timeout only kicks in when something abnormal
    /// happens (Claude crashes, user Ctrl+C interrupt, network hang, etc.) —
    /// without it those scenarios would leave a session stuck in "working"
    /// forever because Claude Code doesn't fire `Stop` on interrupt.
    ///
    /// 120s gives ~2 minutes of grace for pure-text generation phases where
    /// no tool hooks fire. Long tool-using turns refresh the marker more
    /// frequently than that and stay correctly busy.
    static let busyMarkerTimeout: TimeInterval = 120.0

    /// After a Claude session ends, keep the row visible as a ghost for this long.
    static let endedSessionLinger: TimeInterval = 300.0  // 5 minutes

    /// Distance from screen edge to trigger widget snap
    static let edgeSnapThreshold: CGFloat = 36.0

    /// Margin from screen edge when snapping
    static let edgeSnapMargin: CGFloat = 12.0
}
