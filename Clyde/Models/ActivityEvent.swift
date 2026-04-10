import Foundation

/// One row in the activity timeline. Built by `ActivityLog` from
/// transitions it observes on the process / attention monitors and
/// stays purely in-memory (no disk persistence in this iteration).
struct ActivityEvent: Identifiable, Equatable {
    let id = UUID()
    let timestamp: Date
    let kind: Kind
    let sessionDisplayName: String
    let sessionPID: pid_t

    enum Kind: Equatable {
        case sessionStarted
        case sessionResumed
        case sessionCompacted
        case promptSubmitted
        case permissionRequested
        case permissionResolved
        case errorOccurred(reason: String)
        case subagentStarted(agentType: String)
        case subagentStopped
        case sessionReady
        case sessionEnded

        var label: String {
            switch self {
            case .sessionStarted:                return "Session started"
            case .sessionResumed:                return "Session resumed"
            case .sessionCompacted:              return "Context compacted"
            case .promptSubmitted:               return "Prompt submitted"
            case .permissionRequested:           return "Permission requested"
            case .permissionResolved:            return "Permission resolved"
            case .errorOccurred(let reason):     return "Error: \(reason)"
            case .subagentStarted(let type):     return "Subagent: \(type)"
            case .subagentStopped:               return "Subagent finished"
            case .sessionReady:                  return "Ready"
            case .sessionEnded:                  return "Session ended"
            }
        }

        /// SF Symbol used in the timeline row.
        var symbol: String {
            switch self {
            case .sessionStarted:      return "bolt.circle.fill"
            case .sessionResumed:      return "arrow.clockwise.circle.fill"
            case .sessionCompacted:    return "arrow.down.right.and.arrow.up.left.circle.fill"
            case .promptSubmitted:     return "arrow.up.circle.fill"
            case .permissionRequested: return "hand.tap.fill"
            case .permissionResolved:  return "checkmark.circle.fill"
            case .errorOccurred:       return "exclamationmark.triangle.fill"
            case .subagentStarted:     return "person.2.circle.fill"
            case .subagentStopped:     return "person.2.circle"
            case .sessionReady:        return "checkmark.seal.fill"
            case .sessionEnded:        return "moon.zzz.fill"
            }
        }
    }
}
