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

    /// Distance from screen edge to trigger widget snap
    static let edgeSnapThreshold: CGFloat = 36.0

    /// Margin from screen edge when snapping
    static let edgeSnapMargin: CGFloat = 12.0
}
