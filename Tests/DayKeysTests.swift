import Foundation
import Testing

@testable import LightTable

private let zone = TimeZone(identifier: "Europe/Paris")!

private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    return calendar
}()

private func moment(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: day,
                                       hour: hour, minute: minute))!
}

@Suite("Grouping dates into days")
struct DayKeysTests {
    /// The property that matters: whatever the shortcut does, it has to agree
    /// with the calendar for every date, in any order.
    private func agreesWithTheCalendar(_ dates: [Date]) -> Bool {
        var keys = DayKeys(calendar: calendar)
        return dates.allSatisfy { keys.day(of: $0) == calendar.startOfDay(for: $0) }
    }

    @Test("A run of photographs from one day")
    func withinOneDay() {
        let dates = (8..<20).map { moment(2019, 4, 21, $0) }
        #expect(agreesWithTheCalendar(dates))
    }

    @Test("Crossing midnight starts a new day")
    func acrossMidnight() {
        let dates = [moment(2019, 4, 21, 23, 59), moment(2019, 4, 22, 0, 1)]
        var keys = DayKeys(calendar: calendar)
        #expect(keys.day(of: dates[0]) != keys.day(of: dates[1]))
        #expect(agreesWithTheCalendar(dates))
    }

    @Test("Out of order, and jumping back and forth")
    func unordered() {
        let dates = [moment(2020, 7, 3, 12), moment(2015, 1, 1, 6), moment(2020, 7, 3, 18),
                     moment(2015, 1, 1, 23), moment(2026, 12, 31, 0)]
        #expect(agreesWithTheCalendar(dates))
    }

    @Test("The hour a clock change removes")
    func springForward() {
        // 2019-03-31 in Paris is 23 hours long: 02:00 becomes 03:00. A day
        // measured as a fixed 86,400 seconds would carry into the next one.
        let dates = [moment(2019, 3, 30, 12), moment(2019, 3, 31, 1), moment(2019, 3, 31, 23),
                     moment(2019, 4, 1, 0, 30)]
        #expect(agreesWithTheCalendar(dates))
    }

    @Test("The hour a clock change adds")
    func fallBack() {
        // 2019-10-27 in Paris is 25 hours long.
        let dates = [moment(2019, 10, 26, 20), moment(2019, 10, 27, 2), moment(2019, 10, 27, 23),
                     moment(2019, 10, 28, 1)]
        #expect(agreesWithTheCalendar(dates))
    }

    @Test("Photographs with no date at all land together")
    func distantPast() {
        var keys = DayKeys(calendar: calendar)
        #expect(keys.day(of: .distantPast) == keys.day(of: .distantPast))
    }
}
