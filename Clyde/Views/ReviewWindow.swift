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
    @State private var totals = PeriodTotals(workingSeconds: 0, waitingSeconds: 0, turns: 0,
                                             sessions: 0, longestWaitSeconds: 0, longestTurnSeconds: 0,
                                             toolSeconds: 0)
    @State private var projects: [ProjectRow] = []
    /// The grid is deliberately independent of the period switch: it is the
    /// "how have the last weeks gone" view you land on, while the tiles and
    /// the project table answer "and what about today".
    @State private var daily: [DayActivity] = []
    @State private var trail: [HistoryEvent] = []
    /// Set by clicking a project row. The trail is the only thing it
    /// narrows — the tiles keep describing the whole period, so the filter
    /// cannot quietly change what the headline numbers mean.
    @State private var projectFilter: String?

    var body: some View {
        // The window scrolls. It used to be a plain stack in a window
        // with a minimum height, so a machine with more than a handful
        // of projects had the list cut off at the bottom edge with no
        // way to reach the rest.
        ScrollView {
            content
        }
        // A floor, not a size: the window sets what it opens at. Low
        // enough that someone can pull it down to a corner of the screen
        // and still scroll the whole report.
        .frame(minWidth: 560, minHeight: 420)
        .background(Color(nsColor: NSColor(red: 0.09, green: 0.09, blue: 0.11, alpha: 1)))
    }

    private var content: some View {
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
                .fill(Rule.band)
                .frame(height: Rule.thickness)
                .padding(.vertical, Spacing.xxs)

            periodSwitch

            HStack(spacing: Spacing.sm) {
                // "Waiting on you" as a total was misleading (an overnight
                // gap dominates it and means nothing) and "Sessions" drove
                // no decision at all. The pair that replaced them names
                // moments you can act on: the worst single wait, and how
                // often a permission prompt stopped the work.
                // "Working" overstated what it measures: the figure is the
                // wall-clock a turn was open, which includes every tool
                // call. On a repo whose test suite takes a minute, most of
                // it is the machine, not the model. "Busy" is what it is;
                // the bar underneath says what it was made of.
                tile("Busy", Self.duration(totals.workingSeconds))
                tile("Turns", "\(totals.turns)", accessibilityValue: Self.turnLabel(totals.turns))
                tile("Longest wait", Self.duration(totals.longestWaitSeconds))
                // Was "Blocked", a count of permission prompts — which reads
                // 0 for every session running without them, so the tile
                // spent most of its life saying nothing. The worst single
                // turn is always populated and is the one you would go look
                // at.
                tile("Longest turn", Self.duration(totals.longestTurnSeconds))
            }

            if Self.showsBusySplit(working: totals.workingSeconds, tools: totals.toolSeconds) {
                busySplit
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
                                .fill(Rule.band)
                                .frame(height: Rule.thickness)
                        }
                        Button {
                            projectFilter = (projectFilter == row.project) ? nil : row.project
                        } label: {
                            projectRow(row)
                        }
                        .buttonStyle(.plain)
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

            activitySection
        }
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: TaskKey(period: period, project: projectFilter)) {
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
        let filter = projectFilter
        let (newTotals, newProjects, newDaily, newTrail) = await Task.detached(priority: .userInitiated) {
            (s.totals(from: range.from, to: range.to),
             s.projects(from: range.from, to: range.to),
             s.dailyActivity(from: gridFrom, to: gridTo),
             s.trail(from: range.from, to: range.to, project: filter))
        }.value
        guard !Task.isCancelled else { return }
        totals = newTotals
        projects = newProjects
        daily = newDaily
        trail = newTrail
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
            // Two points per sprite pixel. At 2.625 the sprite was
            // drawn 42 points wide inside a 34-point frame — soft, and
            // eight points larger than the box holding it.
            ClydeAnimationView(state: .idle, pixelSize: 2)
                .frame(width: 32, height: 32)
                .padding(Spacing.xs)
                .background(
                    // The same stepped frame the panel's sprites wear.
                    SteppedSquare(step: 50 * SteppedSquare.stepRatio)
                        .fill(SessionTheme.processingColor.opacity(0.16))
                )
                .overlay(
                    SteppedSquare(step: 50 * SteppedSquare.stepRatio)
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

    /// The bar divides busy time, so it can only be drawn when there is
    /// busy time and the parts fit inside it.
    ///
    /// Tool time is recorded as each call ends; busy time only exists once
    /// a turn reaches its Stop. Mid-turn the parts therefore exceed the
    /// whole, and a period whose only turn is still running has tools
    /// inside a busy total of zero — which the first version drew as a
    /// full-width bar under a tile reading "0s".
    ///
    /// Zero tool time means "not recorded" for history from before the
    /// hook reported durations, so that hides the bar too rather than
    /// claiming every second was thinking.
    static func showsBusySplit(working: Int, tools: Int) -> Bool {
        working > 0 && tools > 0 && tools <= working
    }

    /// Part-to-whole for one number, so a bar rather than a second set of
    /// tiles: two segments with a surface gap between them and their
    /// labels attached directly, no legend to look up.
    ///
    /// Hidden entirely when no durations were recorded — history from
    /// before the hook reported them would otherwise be drawn as if every
    /// second had been the model thinking.
    private var busySplit: some View {
        let total = max(1, totals.workingSeconds)
        let toolShare = min(1, Double(totals.toolSeconds) / Double(total))

        return VStack(alignment: .leading, spacing: Spacing.xxs) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(SessionTheme.processingColor)
                        .frame(width: max(0, geo.size.width * (1 - toolShare) - 1))
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Color(white: 0.32))
                }
            }
            .frame(height: 6)

            HStack(spacing: Spacing.sm) {
                Label {
                    Text("Thinking \(Self.duration(totals.thinkingSeconds))")
                } icon: {
                    Circle().fill(SessionTheme.processingColor).frame(width: 6, height: 6)
                }
                Label {
                    Text("Tools \(Self.duration(totals.toolSeconds))")
                } icon: {
                    Circle().fill(Color(white: 0.32)).frame(width: 6, height: 6)
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 10))
            .foregroundStyle(TextColor.tertiary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Busy time split: \(Self.duration(totals.thinkingSeconds)) thinking, \(Self.duration(totals.toolSeconds)) running tools")
    }

    /// Mirrors SessionRow: name on top, a 10pt monospaced secondary line
    /// underneath, figures right-aligned in monospaced digits.
    private func projectRow(_ row: ProjectRow) -> some View {
        let isFiltered = projectFilter == row.project
        return projectRowBody(row, isFiltered: isFiltered)
    }

    private func projectRowBody(_ row: ProjectRow, isFiltered: Bool) -> some View {
        let name = (row.project as NSString).lastPathComponent
        return HStack(spacing: Spacing.sm) {
            ProjectMark(name: name)

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(TextColor.primary)
                HStack(spacing: 6) {
                    Text(row.topTool ?? "—")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(TextColor.tertiary)
                    // Branches are part of the project, not projects of
                    // their own. Naming them here is what tells you the
                    // hours were spread across two worktrees rather than
                    // spent in one place.
                    if !row.worktrees.isEmpty {
                        Text(Self.worktreeLabel(row.worktrees))
                            .font(.system(size: 10))
                            .foregroundStyle(TextColor.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
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
        .background(isFiltered ? SessionTheme.processingColor.opacity(0.12) : .clear)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\((row.project as NSString).lastPathComponent), \(Self.turnLabel(row.turns)), \(Self.duration(row.workingSeconds)) working")
        .accessibilityHint(isFiltered ? "Showing only this project below. Activate to clear." : "Activate to show only this project's activity below.")
        .accessibilityAddTraits(isFiltered ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: - Activity trail

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.xs) {
                Text("ACTIVITY")
                    .font(.system(size: 10, weight: .semibold))
                    .kerning(0.6)
                    .foregroundStyle(TextColor.tertiary)

                if let projectFilter {
                    Button {
                        self.projectFilter = nil
                    } label: {
                        HStack(spacing: 3) {
                            Text((projectFilter as NSString).lastPathComponent)
                                .font(.system(size: 9, weight: .medium))
                            Image(systemName: "xmark")
                                .font(.system(size: 7, weight: .bold))
                        }
                        .foregroundStyle(SessionTheme.processingColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(SessionTheme.processingColor.opacity(0.16)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear the \((projectFilter as NSString).lastPathComponent) filter")
                }

                Spacer(minLength: 0)
            }

            if trail.isEmpty {
                Text("No tool calls recorded for this period.")
                    .font(.system(size: 11))
                    .foregroundStyle(TextColor.disabled)
                    .padding(.vertical, Spacing.xs)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(trail.enumerated()), id: \.offset) { _, entry in
                            trailRow(entry)
                        }
                    }
                }
                .frame(maxHeight: 180)
                .background(
                    RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
                        .fill(Color(white: 0.12))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
                        .stroke(Color(white: 0.18), lineWidth: 1)
                )
            }
        }
    }

    private func trailRow(_ entry: HistoryEvent) -> some View {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        let name = entry.event == "SubagentStart" ? "Agent"
                 : entry.event == "StopFailure" ? "Error"
                 : (entry.tool ?? entry.event)

        return HStack(spacing: Spacing.xs) {
            Text(formatter.string(from: entry.ts))
                .font(.system(size: 10, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(TextColor.tertiary)
                .frame(width: 38, alignment: .leading)

            Text(name)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(entry.event == "StopFailure" ? SessionTheme.errorColor : TextColor.secondary)
                .frame(width: 74, alignment: .leading)
                .lineLimit(1)

            Text(entry.summary ?? "")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(TextColor.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(formatter.string(from: entry.ts)), \(name)\(entry.summary.map { ", \($0)" } ?? "")")
    }

    /// Same shape as the panel's empty state — sleeping mascot and two
    /// lines — rather than a bare sentence floating in the window.
    private var emptyState: some View {
        VStack(spacing: Spacing.sm) {
            ClydeAnimationView(state: .sleeping, pixelSize: 3)
                .frame(width: 48, height: 48)
                .accessibilityHidden(true)
            Text("Nothing recorded yet")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(TextColor.disabled)
            // fixedSize, because the surrounding layout squeezed this to
            // one line and truncated it to "…and it…" — a sentence that
            // stops mid-clause in the one place a new user is guaranteed
            // to look.
            Text("Work in any Claude session and it\nwill show up here.")
                .font(.system(size: 11))
                .foregroundStyle(Color(white: 0.4))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.lg)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Nothing recorded for this period yet")
    }

    /// Half a year. Twelve weeks left two thirds of the window empty and made
    /// the grid read as a fragment; at this density 26 columns fill the width
    /// the way the shape people know from a contribution graph does.
    /// `.task(id:)` needs one value to key on, and the trail depends on the
    /// period *and* the project filter — without the filter in the key,
    /// clicking a project would leave the list showing every project until
    /// the next 30-second reload.
    private struct TaskKey: Equatable {
        let period: Period
        let project: String?
    }

    static let heatmapWeeks = 26

    /// Names the branches when there are one or two, counts them past
    /// that: three names of a length nobody controls will not fit.
    static func worktreeLabel(_ worktrees: [String]) -> String {
        switch worktrees.count {
        case 0: return ""
        case 1, 2: return "· " + worktrees.joined(separator: ", ")
        default: return "· \(worktrees.count) worktrees"
        }
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
