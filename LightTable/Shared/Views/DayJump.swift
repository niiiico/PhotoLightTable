import Foundation

/// Finding a day in a library too long to scroll.
///
/// Knowing the date is the common case — "that walk was the Easter weekend" —
/// and the grid is the wrong instrument for acting on it: at a few hundred
/// photographs a screen, a year back is a minute of scrolling with nothing to
/// aim at on the way.
enum DayJump {
    /// The day to land on for a target date: that day if it is there, otherwise
    /// the nearest one to it.
    ///
    /// Nearest rather than "the first day on or before", because the reason to
    /// miss is usually that nothing was shot that day, and the photographs that
    /// answer "around then" are as likely to be the following weekend as the
    /// previous one. A tie goes to the earlier day, so the answer does not
    /// depend on which way the grid happens to be sorted.
    ///
    /// `days` is whatever the grid is showing — the sections, in their order —
    /// so a filtered grid jumps within what survives the filter rather than to
    /// a day that has been filtered out from under it.
    static func index(for target: Date,
                      in days: [Date],
                      calendar: Calendar = .current) -> Int? {
        guard !days.isEmpty else { return nil }
        let targetDay = calendar.startOfDay(for: target)

        var best: (index: Int, distance: TimeInterval, day: Date)?
        for (index, day) in days.enumerated() {
            let startOfDay = calendar.startOfDay(for: day)
            let distance = abs(startOfDay.timeIntervalSince(targetDay))
            guard let current = best else {
                best = (index, distance, startOfDay)
                continue
            }
            if distance < current.distance
                || (distance == current.distance && startOfDay < current.day) {
                best = (index, distance, startOfDay)
            }
        }
        return best?.index
    }
}
