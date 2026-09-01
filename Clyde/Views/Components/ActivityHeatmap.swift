import SwiftUI

/// A calendar grid of the last N weeks, one cell per day, shaded by how
/// much Claude worked that day — the shape people already know from a
/// contribution graph.
///
/// It answers "where did the last few weeks go" at a glance, which no
/// single number can: four tiles can tell you today was busy, only the grid
/// tells you it was the third busy day in a row after a quiet week.
///
/// Colour is sequential — one hue, light to dark — per the visualisation
/// rules: never a rainbow, and never hue-coded intensity. The hue is
/// `SessionTheme.processingColor`, so the grid reads as Clyde rather than
/// as a transplant from another product.
///
/// The three lowest steps sit below 3:1 contrast against the window's
/// surface, which is inherent to a dark sequential ramp (a contribution
/// graph has the same property). That is not dismissable: it obliges
/// non-colour relief, so every cell carries a tooltip and an accessibility
/// label with the exact figures, and the legend names the direction.
struct ActivityHeatmap: View {
    let days: [DayActivity]
    let weeks: Int

    /// The day under the cursor. A native `.help()` tooltip was the first
    /// attempt and it is the wrong tool here: it waits about a second, it
    /// cannot be styled, and on a grid of 180 small squares the delay makes
    /// the whole thing feel dead. This is drawn by us and appears at once.
    @State private var hovered: Date?

    /// The smallest a cell may be, and the largest. Between them the
    /// grid takes whatever width it is given: at a fixed 11 points it
    /// stopped a third of the way across the window and left the rest
    /// of the row empty.
    private static let minCell: CGFloat = 11
    private static let maxCell: CGFloat = 20
    private static let gap: CGFloat = 3
    private static let gutter: CGFloat = 26

    /// Width the grid has been given, measured once and kept.
    @State private var availableWidth: CGFloat = 0

    /// Whole points: a cell is a small square with a 2.5-point radius,
    /// and a fractional one blurs its own corners.
    private var cell: CGFloat {
        guard availableWidth > 0 else { return Self.minCell }
        let columns = CGFloat(weeks)
        let free = availableWidth - Self.gutter - Self.gap * columns
        return min(Self.maxCell, max(Self.minCell, (free / columns).rounded(.down)))
    }

    /// Sequential ramp, validated for monotonic lightness against the
    /// window surface (#17171C): luminance rises 0.013 → 0.027 → 0.062 →
    /// 0.128 → 0.248 with even adjacent steps. Level 0 is the "nothing
    /// happened" shade and is deliberately barely above the surface.
    private static let ramp: [Color] = [
        Color(red: 0.118, green: 0.118, blue: 0.141),  // #1E1E24
        Color(red: 0.227, green: 0.137, blue: 0.322),  // #3A2352
        Color(red: 0.380, green: 0.188, blue: 0.498),  // #61307F
        Color(red: 0.557, green: 0.247, blue: 0.722),  // #8E3FB8
        Color(red: 0.749, green: 0.353, blue: 0.949),  // #BF5AF2 — SessionTheme.processingColor
    ]

    private var byDay: [Date: DayActivity] {
        Dictionary(uniqueKeysWithValues: days.map { ($0.day, $0) })
    }

    private var maxSeconds: Int {
        days.map(\.workingSeconds).max() ?? 0
    }

    var body: some View {
        content
            // Measured rather than assumed: the window is resizable, so
            // the grid takes the width it is given on the day.
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { availableWidth = proxy.size.width }
                        .onChange(of: proxy.size.width) { availableWidth = $0 }
                }
            )
    }

    private var content: some View {
        let grid = Self.days(endingOn: Date(), weeks: weeks)
        let columns = stride(from: 0, to: grid.count, by: 7).map { Array(grid[$0..<min($0 + 7, grid.count)]) }
        let lookup = byDay
        let peak = maxSeconds

        return VStack(alignment: .leading, spacing: Spacing.xxs) {
            // Month labels sit above the column where that month starts,
            // so a glance can place "three weeks ago" on the calendar.
            let monthLabels = Self.monthLabels(for: columns)
            HStack(alignment: .bottom, spacing: Self.gap) {
                Color.clear.frame(width: Self.gutter, height: 1)
                ForEach(Array(columns.enumerated()), id: \.offset) { index, _ in
                    // The label is wider than its column, so it must be
                    // allowed to overflow to the right: clipping it to the
                    // cell width turns "Mar" into "ar".
                    Text(monthLabels[index])
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(TextColor.tertiary)
                        .fixedSize()
                        .frame(width: cell, alignment: .leading)
                }
            }
            .frame(height: 10, alignment: .bottom)
            .accessibilityHidden(true)

            HStack(alignment: .top, spacing: Self.gap) {
                // Weekday gutter, every other row like the reference — all
                // seven would be noisier than the grid itself.
                VStack(spacing: Self.gap) {
                    ForEach(0..<7, id: \.self) { row in
                        Text(Self.weekdayLabel(row: row))
                            .font(.system(size: 8))
                            .foregroundStyle(TextColor.tertiary)
                            .frame(width: Self.gutter, height: cell, alignment: .trailing)
                    }
                }
                .accessibilityHidden(true)

                ZStack(alignment: .topLeading) {
                    HStack(alignment: .top, spacing: Self.gap) {
                        ForEach(Array(columns.enumerated()), id: \.offset) { _, week in
                            VStack(spacing: Self.gap) {
                                ForEach(week, id: \.self) { day in
                                    cellView(for: day, activity: lookup[day], peak: peak)
                                }
                            }
                        }
                    }

                    if let hovered, let position = Self.position(of: hovered, in: columns, cell: cell) {
                        tooltip(for: hovered, activity: lookup[hovered])
                            .offset(x: position.x - Self.tooltipWidth / 2,
                                    y: position.y - Self.tooltipHeight - Self.gap)
                            .allowsHitTesting(false)
                    }
                }
            }

            legend
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Activity for the last \(weeks) weeks")
    }

    private func cellView(for day: Date, activity: DayActivity?, peak: Int) -> some View {
        let seconds = activity?.workingSeconds ?? 0
        let turns = activity?.turns ?? 0
        let level = Self.level(seconds: seconds, max: peak)
        let isFuture = day > Date()

        let isToday = Calendar.current.isDateInToday(day)

        return RoundedRectangle(cornerRadius: 2.5, style: .continuous)
            .fill(isFuture ? Color(white: 0.10) : Self.ramp[level])
            .frame(width: cell, height: cell)
            .opacity(isFuture ? 0.5 : 1)
            // Today is outlined rather than recoloured: the fill has to keep
            // meaning intensity, or the scale stops being a scale.
            .overlay(
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .stroke(isToday ? TextColor.secondary.opacity(0.7) : .clear, lineWidth: 1)
            )
            // The label still carries the numbers for a screen reader,
            // because the lowest shades cannot be told apart by eye against
            // this surface — the hover card is the sighted equivalent.
            .overlay(
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .stroke(hovered == day ? TextColor.primary.opacity(0.8) : .clear, lineWidth: 1)
            )
            .onHover { inside in
                if inside {
                    hovered = day
                } else if hovered == day {
                    hovered = nil
                }
            }
            .accessibilityLabel(Self.describe(day: day, seconds: seconds, turns: turns))
    }

    private static let tooltipWidth: CGFloat = 168
    private static let tooltipHeight: CGFloat = 52

    /// Where the centre-top of a day's cell sits inside the grid, so the
    /// card can be anchored to the square the cursor is actually over.
    /// Computed from the layout constants rather than measured: the grid is
    /// a fixed lattice, so geometry readers per cell would be 180 of them
    /// for a number we already know.
    static func position(of day: Date, in columns: [[Date]], cell: CGFloat) -> CGPoint? {
        for (column, week) in columns.enumerated() {
            if let row = week.firstIndex(of: day) {
                return CGPoint(
                    x: gutter + gap + CGFloat(column) * (cell + gap) + cell / 2,
                    y: CGFloat(row) * (cell + gap)
                )
            }
        }
        return nil
    }

    private func tooltip(for day: Date, activity: DayActivity?) -> some View {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, d MMM"

        return VStack(alignment: .leading, spacing: 3) {
            Text(formatter.string(from: day))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(TextColor.primary)

            if let activity, activity.turns > 0 {
                HStack(spacing: Spacing.xxs) {
                    Text(ReviewView.duration(activity.workingSeconds))
                        .monospacedDigit()
                        .foregroundStyle(SessionTheme.processingColor)
                    Text("·").foregroundStyle(TextColor.tertiary)
                    Text(ReviewView.turnLabel(activity.turns))
                        .monospacedDigit()
                        .foregroundStyle(TextColor.secondary)
                }
                .font(.system(size: 10))

                if let project = activity.topProject {
                    Text((project as NSString).lastPathComponent)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(TextColor.tertiary)
                        .lineLimit(1)
                }
            } else {
                Text(day > Date() ? "Not yet" : "Nothing recorded")
                    .font(.system(size: 10))
                    .foregroundStyle(TextColor.tertiary)
            }
        }
        .padding(.horizontal, Spacing.xs)
        .padding(.vertical, 6)
        .frame(width: Self.tooltipWidth, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
                .fill(Color(white: 0.16))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
                .stroke(Color(white: 0.26), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.45), radius: 8, y: 3)
        .accessibilityHidden(true)
    }

    private var legend: some View {
        HStack(spacing: Self.gap) {
            Spacer(minLength: 0)
            Text("Less")
                .font(.system(size: 9))
                .foregroundStyle(TextColor.tertiary)
            ForEach(0..<Self.ramp.count, id: \.self) { level in
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .fill(Self.ramp[level])
                    .frame(width: 9, height: 9)
            }
            Text("More")
                .font(.system(size: 9))
                .foregroundStyle(TextColor.tertiary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Colour scale: darker means less time, brighter means more")
    }

    // MARK: - Pure helpers (tested)

    /// Intensity for one day, 0...4.
    ///
    /// The busiest day in the visible range anchors the top of the scale,
    /// so the grid reads the same for a light week and a heavy one. Any
    /// activity at all lifts a day to level 1: a day with a single short
    /// turn must never share a shade with a day you did not work.
    static func level(seconds: Int, max: Int) -> Int {
        guard seconds > 0, max > 0 else { return 0 }
        // Boundaries are inclusive at the bottom of each band, so a day at
        // exactly a quarter of the peak reads as the quieter level. Better
        // to understate a day than to overstate it.
        let share = Double(seconds) / Double(max)
        switch share {
        case ...0.25: return 1
        case ...0.5:  return 2
        case ...0.75: return 3
        default:      return 4
        }
    }

    /// Every day in the grid, oldest first, aligned so each group of seven
    /// is one calendar week starting on the locale's first weekday.
    static func days(endingOn end: Date, weeks: Int) -> [Date] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: end)
        let earliest = calendar.date(byAdding: .day, value: -(weeks * 7 - 1), to: today) ?? today

        // Walk back to the week boundary so columns are whole weeks.
        var start = earliest
        while calendar.component(.weekday, from: start) != calendar.firstWeekday {
            start = calendar.date(byAdding: .day, value: -1, to: start) ?? start
        }

        var result: [Date] = []
        var cursor = start
        while cursor <= today {
            result.append(cursor)
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor) ?? cursor.addingTimeInterval(86_400)
        }
        // Pad the final partial week so the last column is full height.
        while result.count % 7 != 0 {
            let next = calendar.date(byAdding: .day, value: 1, to: result[result.count - 1]) ?? Date()
            result.append(next)
        }
        return result
    }

    /// Month names, one per column, blank where no label belongs.
    ///
    /// A label is three letters wide but a column is eleven points, so a
    /// month that only has a column or two inside the range would print its
    /// name straight over the next one — the first render read "FebMar".
    /// A month therefore only gets a label if it is at least
    /// `minimumColumnsApart` columns clear of the previous one; the month
    /// that is half-visible at the left edge simply goes unnamed, which is
    /// what the reference does too.
    static func monthLabels(for columns: [[Date]], minimumColumnsApart: Int = 3) -> [String] {
        let calendar = Calendar.current
        var labels = [String](repeating: "", count: columns.count)
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM"

        var lastLabelled = -minimumColumnsApart
        var previousMonth: Int?
        for (index, week) in columns.enumerated() {
            guard let first = week.first else { continue }
            let month = calendar.component(.month, from: first)
            defer { previousMonth = month }
            guard month != previousMonth else { continue }
            guard index - lastLabelled >= minimumColumnsApart else { continue }
            labels[index] = formatter.string(from: first)
            lastLabelled = index
        }
        return labels
    }

    /// Alternating weekday labels, matching the reference: labelling all
    /// seven crowds the gutter more than it helps.
    ///
    /// Rows 0, 2 and 4 — the first, third and fifth day of the week — so a
    /// Monday-first calendar reads Mon / Wed / Fri. Three-letter symbols,
    /// not the single-letter ones: those give "T, T, S" for Tue, Thu and
    /// Sat, which names nothing.
    static func weekdayLabel(row: Int) -> String {
        guard row % 2 == 0 else { return "" }
        let calendar = Calendar.current
        let symbols = calendar.shortStandaloneWeekdaySymbols
        let index = (calendar.firstWeekday - 1 + row) % 7
        return symbols.indices.contains(index) ? symbols[index] : ""
    }

    static func describe(day: Date, seconds: Int, turns: Int) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM"
        let date = formatter.string(from: day)
        guard turns > 0 else { return "\(date): nothing recorded" }
        return "\(date): \(ReviewView.duration(seconds)) working, \(ReviewView.turnLabel(turns))"
    }
}
