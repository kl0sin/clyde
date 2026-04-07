import SwiftUI
import Combine

@MainActor
final class SessionListViewModel: ObservableObject {
    let processMonitor: ProcessMonitor
    weak var attentionMonitor: AttentionMonitor?
    private var cancellables = Set<AnyCancellable>()

    /// Custom names keyed by Claude Code session_id (UUID from hook payload).
    /// Stable for the entire lifetime of a Claude session and persisted across
    /// Clyde restarts. When a Claude session ends, its name is dropped.
    @Published private(set) var namesBySessionId: [String: String] = [:]
    /// Fallback for sessions without a known session_id (legacy / pgrep-only):
    /// keyed by current in-memory Session.id, lost on restart.
    @Published private var namesById: [UUID: String] = [:]

    /// User-chosen sort order. Each entry is an `orderKey(for:)` value:
    /// the Claude `session_id` when available, otherwise a `pid:<n>`
    /// fallback so legacy / pgrep-only sessions can still be reordered.
    /// Persisted to disk; pid-based entries naturally drop out on the
    /// next launch because the pid is gone.
    @Published private(set) var orderedSessionIds: [String] = []

    /// The key under which a given session is recorded in
    /// `orderedSessionIds`. Stable for the lifetime of a session and the
    /// same value used by both the writer (`moveSession`) and the reader
    /// (the `sessions` computed property), so the two never disagree.
    private static func orderKey(for session: Session) -> String {
        if let sid = session.sessionId, !sid.isEmpty { return sid }
        return "pid:\(session.pid)"
    }

    var sessions: [Session] {
        let attentionPIDs = attentionMonitor?.attentionPIDs ?? []
        let enriched: [Session] = processMonitor.sessions.map { session in
            var s = session
            if let sid = session.sessionId,
               let name = namesBySessionId[sid], !name.isEmpty {
                s.customName = name
            } else if let name = namesById[session.id], !name.isEmpty {
                s.customName = name
            }
            s.needsAttention = attentionPIDs.contains(session.pid)
            return s
        }

        // Split into live + ghosts so ghosts always end up at the tail.
        let live = enriched.filter { !$0.isGhost }
        let ghosts = enriched.filter { $0.isGhost }

        // Live sessions in user-chosen order come first, in the exact
        // sequence they appear in `orderedSessionIds`.
        let orderMap: [String: Int] = Dictionary(
            uniqueKeysWithValues: orderedSessionIds.enumerated().map { ($0.element, $0.offset) }
        )
        let ordered = live
            .compactMap { session -> (Int, Session)? in
                guard let index = orderMap[Self.orderKey(for: session)] else { return nil }
                return (index, session)
            }
            .sorted { $0.0 < $1.0 }
            .map { $0.1 }

        // Anything else — brand-new sessions that haven't been ordered
        // yet — appears after the ordered block in the monitor's order.
        let orderedSet = Set(ordered.map(\.id))
        let tail = live.filter { !orderedSet.contains($0.id) }

        return ordered + tail + ghosts
    }

    /// Counters reflect *live* sessions only — ghost rows (sessions that
    /// have ended but are still visible for ~5 min) don't contribute.
    var sessionCount: Int { processMonitor.sessions.filter { !$0.isGhost }.count }
    var busyCount: Int { processMonitor.sessions.filter { !$0.isGhost && $0.status == .busy }.count }
    var idleCount: Int { processMonitor.sessions.filter { !$0.isGhost && $0.status == .idle }.count }
    var attentionCount: Int {
        guard let ids = attentionMonitor?.attentionPIDs else { return 0 }
        return ids.count
    }

    init(processMonitor: ProcessMonitor, attentionMonitor: AttentionMonitor? = nil) {
        self.processMonitor = processMonitor
        self.attentionMonitor = attentionMonitor
        loadPersistedNames()
        loadPersistedOrder()
        processMonitor.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        attentionMonitor?.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    /// Move a subset of session rows to a new position, mirroring the
    /// standard SwiftUI `List.onMove` signature. Persists the resulting
    /// order so drag-to-reorder survives across app restarts.
    func moveSession(from source: IndexSet, to destination: Int) {
        var current = sessions.filter { !$0.isGhost }
        current.move(fromOffsets: source, toOffset: destination)
        // Use a stable key per session (session_id or pid:<n>) so even
        // legacy / pgrep-only rows can be reordered without being
        // silently dropped.
        orderedSessionIds = current.map { Self.orderKey(for: $0) }
        persistOrder()
        objectWillChange.send()
    }

    func renameSession(id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // Prefer to persist by Claude session_id (stable across Clyde restarts).
        if let session = processMonitor.sessions.first(where: { $0.id == id }),
           let sid = session.sessionId {
            if trimmed.isEmpty {
                namesBySessionId.removeValue(forKey: sid)
            } else {
                namesBySessionId[sid] = trimmed
            }
            persistNames()
        } else {
            // No session_id (legacy / pgrep-only) — keep in memory only.
            if trimmed.isEmpty {
                namesById.removeValue(forKey: id)
            } else {
                namesById[id] = trimmed
            }
        }
        objectWillChange.send()
    }

    // MARK: - Persistence

    private var persistenceURL: URL {
        AppPaths.clydeDir.appendingPathComponent("session-names.json")
    }

    private func loadPersistedNames() {
        guard let data = try? Data(contentsOf: persistenceURL),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
            return
        }
        // Drop entries that aren't session_id-shaped (UUID). The first iteration of
        // this file used cwd paths as keys; those would never match a real
        // session_id and would silently inflate the dict forever.
        let cleaned = dict.filter { Self.looksLikeSessionId($0.key) }
        namesBySessionId = cleaned
        if cleaned.count != dict.count {
            ClydeLog.general.info("Dropped \(dict.count - cleaned.count, privacy: .public) legacy session-name entries")
            persistNames()
        }
    }

    /// Heuristic: a Claude session_id is a UUID-shape string. Reject anything
    /// that looks like a path or random text.
    static func looksLikeSessionId(_ key: String) -> Bool {
        // Reject obvious non-UUID values: paths, empty, anything containing '/'
        if key.contains("/") || key.isEmpty { return false }
        // UUIDs are 36 chars (8-4-4-4-12) with hyphens.
        return UUID(uuidString: key) != nil
    }

    private func persistNames() {
        do {
            try FileManager.default.createDirectory(at: AppPaths.clydeDir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(namesBySessionId)
            try data.write(to: persistenceURL, options: .atomic)
        } catch {
            ClydeLog.general.error("Failed to persist session names: \(error.localizedDescription, privacy: .public)")
        }
    }

    private var orderPersistenceURL: URL {
        AppPaths.clydeDir.appendingPathComponent("session-order.json")
    }

    private func loadPersistedOrder() {
        guard let data = try? Data(contentsOf: orderPersistenceURL),
              let list = try? JSONDecoder().decode([String].self, from: data) else {
            return
        }
        // Accept either a UUID-shaped session_id or a "pid:<n>" fallback key.
        // Drop anything that looks like garbage from older iterations.
        orderedSessionIds = list.filter { key in
            Self.looksLikeSessionId(key) || key.hasPrefix("pid:")
        }
    }

    private func persistOrder() {
        do {
            try FileManager.default.createDirectory(at: AppPaths.clydeDir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(orderedSessionIds)
            try data.write(to: orderPersistenceURL, options: .atomic)
        } catch {
            ClydeLog.general.error("Failed to persist session order: \(error.localizedDescription, privacy: .public)")
        }
    }
}
