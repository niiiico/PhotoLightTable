import Foundation

/// Start-of-day keys for a run of dates.
///
/// `Calendar.startOfDay(for:)` is around a microsecond, which is nothing until
/// it is asked ninety thousand times to lay out a grid — a seventh of a second,
/// on the main thread, every time the library is regrouped. Photographs arrive
/// in date order and a day holds many of them, so the answer for the last date
/// is nearly always the answer for this one: the day's own interval is kept and
/// the calendar is only consulted when a date falls outside it.
///
/// Exact rather than approximate. Dividing by 86,400 would be faster still and
/// wrong twice a year, in the hour a clock change adds or removes.
struct DayKeys {
    private var current: (day: Date, range: Range<Date>)?
    private let calendar: Calendar

    init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    mutating func day(of date: Date) -> Date {
        if let current, current.range.contains(date) { return current.day }

        let start = calendar.startOfDay(for: date)
        // A day is not always 24 hours long; ask the calendar where the next
        // one begins rather than adding a constant to this one.
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        current = (start, start..<end)
        return start
    }
}
