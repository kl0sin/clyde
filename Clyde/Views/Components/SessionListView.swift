import SwiftUI
import UniformTypeIdentifiers

// MARK: - Session List

struct SessionListView: View {
    let sessions: [Session]
    let onRename: (UUID, String) -> Void
    let onFocus: (Session) -> Void
    let onReset: (Session) -> Void
    let onMove: (IndexSet, Int) -> Void
    let notificationService: NotificationService?

    @State private var draggedSession: Session?
    /// The row the cursor is currently hovering over during a drag.
    /// Used to draw the drop-target highlight + insertion indicator.
    @State private var dropTargetSession: Session?
    /// Whether the drop will land ABOVE or BELOW the target row, so the
    /// insertion line shows in the right place.
    @State private var dropAbove: Bool = true

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(disambiguated, id: \.session.id) { item in
                    rowWithIndicator(item: item)
                }
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func rowWithIndicator(item: (session: Session, suffix: String?, idleIndex: Int?)) -> some View {
        let isDragging = draggedSession?.id == item.session.id
        let isDropTarget = dropTargetSession?.id == item.session.id && draggedSession?.id != item.session.id

        VStack(spacing: 0) {
            // Insertion line ABOVE the row when the drop will land before it.
            insertionLine
                .opacity(isDropTarget && dropAbove ? 1 : 0)

            SessionRow(
                session: item.session,
                disambiguator: item.suffix,
                idleIndex: item.idleIndex,
                onRename: { name in onRename(item.session.id, name) },
                onFocus: { onFocus(item.session) },
                onReset: { onReset(item.session) },
                notificationService: notificationService
            )
            .scaleEffect(isDragging ? 0.98 : 1.0)
            .opacity(isDragging ? 0.4 : 1.0)
            .background(
                isDropTarget
                ? Color.accentColor.opacity(0.08)
                : Color.clear
            )
            .animation(.easeInOut(duration: 0.18), value: isDragging)
            .animation(.easeInOut(duration: 0.18), value: isDropTarget)
            .onDrag {
                guard !item.session.isGhost else { return NSItemProvider() }
                draggedSession = item.session
                return NSItemProvider(object: item.session.id.uuidString as NSString)
            }
            .onDrop(of: [.text], delegate: SessionDropDelegate(
                destination: item.session,
                draggedSession: $draggedSession,
                dropTargetSession: $dropTargetSession,
                dropAbove: $dropAbove,
                sessions: sessions,
                onMove: onMove
            ))

            // Insertion line BELOW the row when the drop will land after it.
            insertionLine
                .opacity(isDropTarget && !dropAbove ? 1 : 0)

            if item.session.id != sessions.last?.id {
                Divider()
                    .background(Color(white: 0.15))
                    .padding(.leading, 52)
            }
        }
    }

    /// 2pt-tall accent-coloured bar used as a drag insertion indicator.
    private var insertionLine: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(Color.accentColor)
            .frame(height: 2)
            .padding(.horizontal, 16)
            .padding(.vertical, 1)
            .shadow(color: Color.accentColor.opacity(0.6), radius: 3)
    }

    /// Per-row metadata: disambiguation suffix when names collide, plus the
    /// 1-based slot index for idle (non-active, non-ghost) sessions.
    private var disambiguated: [(session: Session, suffix: String?, idleIndex: Int?)] {
        var counts: [String: Int] = [:]
        var indices: [String: Int] = [:]

        for s in sessions {
            counts[s.displayName, default: 0] += 1
        }

        var nextIdleSlot = 1
        return sessions.map { session in
            let name = session.displayName
            var suffix: String? = nil
            if (counts[name] ?? 0) > 1 {
                let nextIndex = (indices[name] ?? 0) + 1
                indices[name] = nextIndex
                suffix = "#\(nextIndex)"
            }

            let isActive = !session.isGhost && (session.needsAttention || session.status == .busy)
            var idleIndex: Int? = nil
            if !isActive && !session.isGhost {
                idleIndex = nextIdleSlot
                nextIdleSlot += 1
            }
            return (session, suffix, idleIndex)
        }
    }
}

// MARK: - Drop delegate

/// Tracks the hovered row + insertion direction during a drag, and
/// commits the actual reorder once on `performDrop`. Doing the reorder
/// in `dropEntered` causes an A/B thrash because each move shifts the
/// dragged row to a new index, which the next hover crossing tries to
/// undo. Doing it in `performDrop` keeps the model stable.
private struct SessionDropDelegate: DropDelegate {
    let destination: Session
    @Binding var draggedSession: Session?
    @Binding var dropTargetSession: Session?
    @Binding var dropAbove: Bool
    let sessions: [Session]
    let onMove: (IndexSet, Int) -> Void

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func dropEntered(info: DropInfo) {
        guard let dragged = draggedSession,
              dragged.id != destination.id,
              !destination.isGhost else { return }
        dropTargetSession = destination
        // Decide if the insertion line should sit above or below this row,
        // based on whether we're dragging up or down through the list.
        if let from = sessions.firstIndex(where: { $0.id == dragged.id }),
           let to = sessions.firstIndex(where: { $0.id == destination.id }) {
            dropAbove = to < from
        }
    }

    func dropExited(info: DropInfo) {
        if dropTargetSession?.id == destination.id {
            dropTargetSession = nil
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            draggedSession = nil
            dropTargetSession = nil
        }
        guard let dragged = draggedSession,
              dragged.id != destination.id,
              !destination.isGhost else {
            return false
        }
        guard let fromIndex = sessions.firstIndex(where: { $0.id == dragged.id }),
              let toIndex = sessions.firstIndex(where: { $0.id == destination.id }) else {
            return false
        }
        // SwiftUI's IndexSet.move uses "insert before" semantics for the
        // target offset. When dragging downwards we need the destination
        // offset to be one past the hovered row so the item lands AFTER it.
        let targetOffset = toIndex > fromIndex ? toIndex + 1 : toIndex
        onMove(IndexSet(integer: fromIndex), targetOffset)
        return true
    }
}
