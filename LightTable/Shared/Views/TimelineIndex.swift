import Foundation

/// Where the years and months fall down the side of the grid.
///
/// The grid is scrolled in photographs, not in time: a fortnight of heavy
/// shooting is a longer stretch of the scrollbar than the two quiet years after
/// it. The rail is drawn on that same measure — a tick sits at the fraction of
/// the library the day starts at — so the marks line up with what scrolling
/// actually does rather than with a calendar the scroll does not obey.
enum TimelineIndex {
    struct Tick: Equatable {
        /// 0 at the top of the grid, 1 at the bottom.
        let fraction: Double
        let label: String
        /// Years are drawn heavier than months.
        let isMajor: Bool
        /// The day this tick starts, for landing on it.
        let day: Date
    }

    /// Ticks for the days the grid is showing, in the order it is showing them.
    ///
    /// `days` carries a count per day because a day of four hundred frames
    /// takes four hundred frames' worth of scrolling; measuring in days would
    /// put the mark for 2019 nowhere near where 2019 actually appears.
    ///
    /// Months while the whole span fits in about a year and a half, years
    /// beyond that: the tick that is worth reading is the one you can act on,
    /// and a decade of month labels is a grey column.
    static func ticks(for days: [(day: Date, count: Int)],
                      maxLabels: Int = 24,
                      calendar: Calendar = .current) -> [Tick] {
        let total = days.reduce(0) { $0 + $1.count }
        guard total > 0, let first = days.first?.day, let last = days.last?.day else { return [] }

        let months = abs(calendar.dateComponents([.month], from: min(first, last), to: max(first, last)).month ?? 0)
        let byMonth = months <= 18

        var ticks: [Tick] = []
        var seen: Set<DateComponents> = []
        var cumulative = 0
        for entry in days {
            let unit: Set<Calendar.Component> = byMonth ? [.year, .month] : [.year]
            let components = calendar.dateComponents(unit, from: entry.day)
            defer { cumulative += entry.count }
            guard seen.insert(components).inserted else { continue }

            let isJanuary = calendar.component(.month, from: entry.day) == 1
            let label: String
            if byMonth {
                // The year earns its place on the first tick and each January;
                // repeating it on every month is noise in a column this narrow.
                label = ticks.isEmpty || isJanuary
                    ? entry.day.formatted(.dateTime.month(.abbreviated).year())
                    : entry.day.formatted(.dateTime.month(.abbreviated))
            } else {
                label = entry.day.formatted(.dateTime.year())
            }
            ticks.append(Tick(fraction: Double(cumulative) / Double(total),
                              label: label,
                              isMajor: !byMonth || isJanuary || ticks.isEmpty,
                              day: entry.day))
        }
        return thinned(ticks, to: maxLabels)
    }

    /// Which day sits a given fraction of the way down the grid.
    ///
    /// Measured in photographs for the same reason the ticks are: this is the
    /// inverse of where the rail drew them, so letting go of the scrubber lands
    /// on the day whose label the pointer was against.
    static func index(atFraction fraction: Double, in counts: [Int]) -> Int? {
        let total = counts.reduce(0, +)
        guard total > 0 else { return nil }
        let target = Double(total) * min(max(fraction, 0), 1)

        var cumulative = 0
        for (index, count) in counts.enumerated() {
            cumulative += count
            if Double(cumulative) > target { return index }
        }
        return counts.indices.last
    }

    /// Keeps the ends and spreads what is left evenly, so a long library reads
    /// as a scale rather than a solid line of text.
    static func thinned(_ ticks: [Tick], to maxLabels: Int) -> [Tick] {
        guard maxLabels > 1, ticks.count > maxLabels else { return ticks }
        let step = Double(ticks.count - 1) / Double(maxLabels - 1)
        var kept: [Tick] = []
        for index in 0..<maxLabels {
            let source = Int((Double(index) * step).rounded())
            let tick = ticks[min(source, ticks.count - 1)]
            if kept.last != tick { kept.append(tick) }
        }
        return kept
    }
}
