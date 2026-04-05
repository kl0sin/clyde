import Foundation

enum SessionStatus: Equatable {
    case busy
    case idle
}

struct Session: Identifiable, Equatable {
    let id: UUID
    let pid: pid_t
    var status: SessionStatus
    var workingDirectory: String
    var customName: String?
    var statusChangedAt: Date
    var consecutiveIdleReads: Int

    var displayName: String {
        if let customName, !customName.isEmpty {
            return customName
        }
        return (workingDirectory as NSString).lastPathComponent
    }

    init(pid: pid_t, workingDirectory: String = "", status: SessionStatus = .busy) {
        self.id = UUID()
        self.pid = pid
        self.status = status
        self.workingDirectory = workingDirectory
        self.customName = nil
        self.statusChangedAt = Date()
        self.consecutiveIdleReads = 0
    }
}
