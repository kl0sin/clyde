import SwiftUI

/// The review surface. A dedicated window rather than part of the panel:
/// the panel is 400×420 and built for glancing mid-task, while a review is
/// something you sit down and read.
struct ReviewView: View {
    let stats: HistoryStats

    enum Period: String, CaseIterable, Identifiable {
        case day = "Today", week = "This week"
        var id: String { rawValue }

        var range: (from: Date, to: Date) {
            let now = Date()
            let start = Calendar.current.startOfDay(for: now)
            switch self {
            case .day:  return (start, now)
            case .week: return (Calendar.current.date(byAdding: .day, value: -6, to: start) ?? start, now)
            }
        }
    }

    @State private var period: Period = .day

    // `totals` and `projects` used to be computed properties, but every
    // read goes through `HistoryStore`'s ingest queue lock — if the window
    // is open during a 30s ingest tick, a body pass would block the main
    // thread until that transaction commits. Loading them off the main
    // actor and holding the result in state avoids that; a `.task(id:)`
    // reload on period change means the tiles briefly show the seeded
    // zero values, which reads the same as a genuinely empty period.
    @State private var totals = PeriodTotals(workingSeconds: 0, waitingSeconds: 0, turns: 0, sessions: 0)
    @State private var projects: [ProjectRow] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("", selection: $period) {
                ForEach(Period.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 240)
            .accessibilityLabel("Review period")

            HStack(spacing: 12) {
                tile("Working", Self.duration(totals.workingSeconds))
                tile("Waiting on you", Self.duration(totals.waitingSeconds))
                tile("Turns", "\(totals.turns)", accessibilityValue: Self.turnLabel(totals.turns))
                tile("Sessions", "\(totals.sessions)")
            }

            Text("Projects")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(white: 0.7))

            if projects.isEmpty {
                Text("Nothing recorded for this period yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(white: 0.5))
            } else {
                ForEach(projects, id: \.project) { row in
                    HStack {
                        Text((row.project as NSString).lastPathComponent)
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                        Text(row.topTool ?? "—")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color(white: 0.55))
                        Text(Self.turnLabel(row.turns))
                            .font(.system(size: 11))
                            .foregroundStyle(Color(white: 0.55))
                            .frame(width: 70, alignment: .trailing)
                        Text(Self.duration(row.workingSeconds))
                            .font(.system(size: 12, design: .monospaced))
                            .frame(width: 70, alignment: .trailing)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\((row.project as NSString).lastPathComponent), \(Self.turnLabel(row.turns)), \(Self.duration(row.workingSeconds)) working")
                }
            }

            Spacer()
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 420)
        .task(id: period) {
            await load()
        }
    }

    // Runs on the main actor (so assigning back to `@State` is safe) but
    // hands the actual synchronous, lock-taking queries to a detached task
    // so the wait for the ingest queue happens off the main thread.
    // `.task(id: period)` cancels the previous task whenever `period`
    // changes, so a rapid double switch can't have the first load's
    // result land after the second's — the in-flight detached work isn't
    // itself cancelled mid-query (the SQLite call has no cancellation
    // check), but its result is only ever assigned from the `.task` body
    // that owns it, and that body is torn down before ever reaching the
    // assignment once a new `period` supersedes it.
    @MainActor
    private func load() async {
        let range = period.range
        let s = stats
        let (newTotals, newProjects) = await Task.detached(priority: .userInitiated) {
            (s.totals(from: range.from, to: range.to), s.projects(from: range.from, to: range.to))
        }.value
        guard !Task.isCancelled else { return }
        totals = newTotals
        projects = newProjects
    }

    // `accessibilityValue` lets the "Turns" tile speak "1 turn" / "2 turns"
    // to a screen reader while the on-screen text stays the bare number —
    // the label above it already reads "Turns", so the visible value must
    // not duplicate that word.
    private func tile(_ label: String, _ value: String, accessibilityValue: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(Color(white: 0.55))
            Text(value)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.14)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(accessibilityValue ?? value)")
    }

    static func duration(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }

    static func turnLabel(_ count: Int) -> String {
        count == 1 ? "1 turn" : "\(count) turns"
    }
}
