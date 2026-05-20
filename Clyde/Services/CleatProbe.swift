import Foundation

/// Detects whether [cleat](https://github.com/cleatdev/cleat) is
/// installed and whether its `hooks` capability — the host-side hook
/// bridge — is currently enabled. Used to surface a one-line advisory
/// when a user has cleat on their PATH but cleat's hook bridge is off
/// (the most common reason cleat-sandboxed sessions silently don't
/// show up in Clyde's panel).
///
/// We deliberately read cleat's config file directly instead of
/// shelling out to `cleat config --list`. The CLI output is a TUI
/// with ANSI escape codes that varies between cleat versions and
/// terminal capabilities — fragile and slow. The on-disk format is
/// trivial:
///
///     [caps]
///     hooks
///     git
///
/// A `[caps]` section with one enabled capability per line. We just
/// look for a bare-line `hooks` token under that section.
enum CleatProbe {
    enum Status: Equatable {
        /// Either cleat isn't on PATH, or its config directory doesn't
        /// exist (e.g. user installed cleat but never ran it). Banner
        /// stays silent in this state — there's no problem to surface.
        case notInstalled
        /// Cleat is installed and configured, but the `hooks` cap is
        /// disabled. Sandboxed sessions won't reach Clyde until the
        /// user runs `cleat config --enable hooks`.
        case hooksDisabled
        /// Cleat installed, `hooks` cap on. Clyde's integration works.
        case hooksEnabled
    }

    /// Override for tests so we don't depend on the host's real
    /// cleat install. Production never sets this.
    nonisolated(unsafe) static var configPathOverride: URL?

    /// Override for tests that want to simulate `cleat` (not) being
    /// on PATH. Production never sets this.
    nonisolated(unsafe) static var cleatOnPathOverride: Bool?

    /// Returns the current status. Cheap — a single file read.
    static func hooksCapStatus() -> Status {
        guard isCleatOnPath() else { return .notInstalled }
        let configURL = configPathOverride ?? defaultConfigURL()
        guard let contents = try? String(contentsOf: configURL, encoding: .utf8) else {
            // cleat is on PATH but no config file — user has cleat
            // installed but has never run `cleat config` (and the
            // default caps don't include `hooks`). Treat as disabled
            // so the advisory fires and tells them what to do.
            return .hooksDisabled
        }
        return parseConfig(contents).contains("hooks") ? .hooksEnabled : .hooksDisabled
    }

    /// Parse cleat's config file and return the set of enabled
    /// capabilities. Exposed internal so tests can exercise the parser
    /// without round-tripping through the filesystem.
    static func parseConfig(_ contents: String) -> Set<String> {
        var caps: Set<String> = []
        var inCapsSection = false
        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                inCapsSection = (line == "[caps]")
                continue
            }
            guard inCapsSection else { continue }
            // Whitespace-separated cap names per line in cleat ≥ 0.x;
            // historically one-per-line but split-on-whitespace handles
            // either form without changing semantics.
            for token in line.split(whereSeparator: { $0.isWhitespace }) {
                caps.insert(String(token))
            }
        }
        return caps
    }

    private static func isCleatOnPath() -> Bool {
        if let override = cleatOnPathOverride { return override }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        task.arguments = ["cleat"]
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static func defaultConfigURL() -> URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".config/cleat/config")
    }
}
