import SwiftUI

struct SessionDetailView: View {
    let session: Session

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Circle()
                    .fill(session.status == .busy ? Color.red : Color.green)
                    .frame(width: 8, height: 8)

                Text(session.status == .busy ? "BUSY" : "IDLE")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(session.status == .busy ? .red : .green)

                Text("· \(timeAgo(session.statusChangedAt))")
                    .font(.system(size: 11))
                    .foregroundColor(.gray)
            }

            InfoCard(label: "Directory", value: session.workingDirectory.isEmpty ? "—" : session.workingDirectory)
            InfoCard(label: "PID", value: "\(session.pid)")
        }
        .padding(16)
    }

    private func timeAgo(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        let secs = seconds % 60
        return "\(minutes)m \(secs)s"
    }
}

struct InfoCard: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.gray)
                .textCase(.uppercase)
                .tracking(0.5)

            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.white)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(white: 0.13))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
