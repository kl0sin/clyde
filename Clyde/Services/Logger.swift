import Foundation
import os

/// Unified logging interface for Clyde. Routes to os.log for Console.app
/// and optionally to a file at ~/.clyde/logs/clyde.log.
enum ClydeLog {
    /// Taken from the running bundle so a dev build's messages are
    /// filterable apart from the installed app's — the two now carry
    /// different identifiers. The literal is the fallback for contexts
    /// with no bundle, such as the test runner.
    private static let subsystem = Bundle.main.bundleIdentifier ?? "io.github.kl0sin.clyde"
    static let general = os.Logger(subsystem: subsystem, category: "general")
    static let process = os.Logger(subsystem: subsystem, category: "process")
    static let terminal = os.Logger(subsystem: subsystem, category: "terminal")
    static let hooks = os.Logger(subsystem: subsystem, category: "hooks")
    static let ui = os.Logger(subsystem: subsystem, category: "ui")
}
