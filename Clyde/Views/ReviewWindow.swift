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
    /// The grid is deliberately independent of the period switch: it is the
    /// "how have the last weeks gone" view you land on, while the tiles and
    /// the project table answer "and what about today".
    @State private var daily: [DayActivity] = []

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            header

            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("LAST 6 MONTHS")
                    .font(.system(size: 10, weight: .semibold))
                    .kerning(0.6)
                    .foregroundStyle(TextColor.tertiary)
                ActivityHeatmap(days: daily, weeks: Self.heatmapWeeks)
            }

            Rectangle()
                .fill(Color(white: 0.18))
                .frame(height: 1)
                .padding(.vertical, Spacing.xxs)

            periodSwitch

            HStack(spacing: Spacing.sm) {
                tile("Working", Self.duration(totals.workingSeconds))
                tile("Waiting on you", Self.duration(totals.waitingSeconds))
                tile("Turns", "\(totals.turns)", accessibilityValue: Self.turnLabel(totals.turns))
                tile("Sessions", "\(totals.sessions)")
            }

            Text("PROJECTS")
                .font(.system(size: 10, weight: .semibold))
                .kerning(0.6)
                .foregroundStyle(TextColor.tertiary)
                .padding(.top, Spacing.xxs)

            if projects.isEmpty {
                emptyState
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(projects.enumerated()), id: \.element.project) { index, row in
                        if index > 0 {
                            Rectangle()
                                .fill(Color(white: 0.18))
                                .frame(height: 1)
                        }
                        projectRow(row)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
                        .fill(Color(white: 0.12))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
                        .stroke(Color(white: 0.18), lineWidth: 1)
                )
            }

            Spacer(minLength: 0)
        }
        .padding(Spacing.lg)
        .frame(minWidth: 560, minHeight: 560)
        .background(Color(nsColor: NSColor(red: 0.09, green: 0.09, blue: 0.11, alpha: 1)))
        .task(id: period) {
            // Reload once immediately, then keep reloading on the same
            // 30s cadence as the ingest tick, for as long as the window
            // stays visible — otherwise a window left open shows
            // whatever numbers were current when it opened, forever,
            // with no indication they're stale. `load()` awaits its own
            // detached query before returning, so a slow load can never
            // stack a second one on top of it; sleeping in between (not
            // running on a fixed timer) means the 30s gap is always
            // measured from the previous load's completion. `.task(id:)`
            // cancels this whole loop the moment `period` changes or the
            // view disappears.
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(30))
            }
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
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let gridFrom = calendar.date(byAdding: .day, value: -(Self.heatmapWeeks * 7), to: today) ?? today
        let gridTo = calendar.date(byAdding: .day, value: 1, to: today) ?? Date()
        let (newTotals, newProjects, newDaily) = await Task.detached(priority: .userInitiated) {
            (s.totals(from: range.from, to: range.to),
             s.projects(from: range.from, to: range.to),
             s.dailyActivity(from: gridFrom, to: gridTo))
        }.value
        guard !Task.isCancelled else { return }
        totals = newTotals
        projects = newProjects
        daily = newDaily
    }

    // `accessibilityValue` lets the "Turns" tile speak "1 turn" / "2 turns"
    // to a screen reader while the on-screen text stays the bare number —
    // the label above it already reads "Turns", so the visible value must
    // not duplicate that word.
    private func tile(_ label: String, _ value: String, accessibilityValue: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .kerning(0.5)
                .foregroundStyle(TextColor.tertiary)
            // Monospaced digits: these tick on a 30s reload, and
            // proportional figures make the whole row shuffle sideways
            // every time a number changes width.
            Text(value)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(TextColor.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
                .fill(Color(white: 0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
                .stroke(Color(white: 0.18), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(accessibilityValue ?? value)")
    }

    /// Same shape as the panel's header: the mascot carries the app's
    /// identity, so a window that shows Clyde's data should open the same
    /// way the panel does.
    private var header: some View {
        HStack(spacing: Spacing.sm) {
            ClydeAnimationView(state: .idle, pixelSize: 2.625)
                .frame(width: 34, height: 34)
                .padding(Spacing.xs)
                .background(
                    RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
                        .fill(SessionTheme.processingColor.opacity(0.16))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
                        .stroke(SessionTheme.processingColor.opacity(0.45), lineWidth: 1)
                )
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("Session review")
                    .font(.system(size: 16, weight: .heavy, design: .rounded))
                    .foregroundStyle(TextColor.primary)
                Text(periodSubtitle)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(TextColor.tertiary)
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Session review, \(periodSubtitle)")
    }

    private var periodSubtitle: String {
        let range = period.range
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM"
        // "since 00:00" was technically true and told the reader nothing;
        // the date is what they actually want to see next to the numbers.
        switch period {
        case .day:  return formatter.string(from: range.to)
        case .week: return "\(formatter.string(from: range.from)) – \(formatter.string(from: range.to))"
        }
    }

    /// The system segmented control is the single thing that made this
    /// window read as a form from another app. Two capsules in the same
    /// language as the row badges instead.
    private var periodSwitch: some View {
        HStack(spacing: Spacing.xs) {
            ForEach(Period.allCases) { option in
                let selected = option == period
                Button {
                    period = option
                } label: {
                    Text(option.rawValue)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(selected ? SessionTheme.processingColor : TextColor.secondary)
                        .padding(.horizontal, Spacing.sm)
                        .padding(.vertical, 5)
                        .background(
                            Capsule().fill(selected
                                           ? SessionTheme.processingColor.opacity(0.18)
                                           : Color(white: 0.14))
                        )
                        .overlay(
                            Capsule().stroke(selected
                                             ? SessionTheme.processingColor.opacity(0.5)
                                             : .clear, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.rawValue)
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Review period")
    }

    /// Mirrors SessionRow: name on top, a 10pt monospaced secondary line
    /// underneath, figures right-aligned in monospaced digits.
    private func projectRow(_ row: ProjectRow) -> some View {
        HStack(spacing: Spacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text((row.project as NSString).lastPathComponent)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(TextColor.primary)
                Text(row.topTool ?? "—")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(TextColor.tertiary)
            }

            Spacer(minLength: Spacing.xs)

            Text(Self.turnLabel(row.turns))
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(TextColor.tertiary)

            Text(Self.duration(row.workingSeconds))
                .font(.system(size: 13, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(TextColor.secondary)
                .frame(width: 64, alignment: .trailing)
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\((row.project as NSString).lastPathComponent), \(Self.turnLabel(row.turns)), \(Self.duration(row.workingSeconds)) working")
    }

    /// Same shape as the panel's empty state — sleeping mascot and two
    /// lines — rather than a bare sentence floating in the window.
    private var emptyState: some View {
        VStack(spacing: Spacing.sm) {
            ClydeAnimationView(state: .sleeping, pixelSize: 2.5)
                .frame(width: 40, height: 40)
                .accessibilityHidden(true)
            Text("Nothing recorded yet")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(TextColor.disabled)
            Text("Work in any Claude session and it\nwill show up here.")
                .font(.system(size: 11))
                .foregroundStyle(Color(white: 0.4))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.lg)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Nothing recorded for this period yet")
    }

    /// Half a year. Twelve weeks left two thirds of the window empty and made
    /// the grid read as a fragment; at this density 26 columns fill the width
    /// the way the shape people know from a contribution graph does.
    static let heatmapWeeks = 26

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
