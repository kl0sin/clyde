import SwiftUI

struct SessionTabBar: View {
    let sessions: [Session]
    let selectedID: UUID?
    let onSelect: (Session) -> Void
    let onDoubleClick: (Session) -> Void
    let onNewSession: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(sessions) { session in
                    SessionTab(
                        session: session,
                        isSelected: session.id == selectedID
                    )
                    .onTapGesture(count: 2) { onDoubleClick(session) }
                    .onTapGesture { onSelect(session) }
                }

                Button(action: onNewSession) {
                    Text("+")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.gray)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
            }
        }
        .background(Color(white: 0.12))
    }
}

struct SessionTab: View {
    let session: Session
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(session.status == .busy ? Color.red : Color.green)
                .frame(width: 6, height: 6)

            Text(session.displayName)
                .font(.system(size: 12))
                .foregroundColor(isSelected ? .white : .gray)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .background(isSelected ? Color(white: 0.17) : Color.clear)
        .overlay(
            Rectangle()
                .frame(height: 2)
                .foregroundColor(isSelected ? .purple : .clear),
            alignment: .bottom
        )
    }
}
