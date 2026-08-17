import Foundation
import Testing

@testable import LightTable

/// A fixed calendar in a fixed zone, so no test depends on where it runs.
private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

private func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: day))!
}

@Suite("Jumping to a day")
struct DayJumpTests {
    @Test("An empty grid has nowhere to jump to")
    func emptyGrid() {
        #expect(DayJump.index(for: day(2019, 4, 21), in: [], calendar: calendar) == nil)
    }

    @Test("The day itself when it is there")
    func exactDay() {
        let days = [day(2019, 4, 20), day(2019, 4, 21), day(2019, 4, 22)]
        #expect(DayJump.index(for: day(2019, 4, 21), in: days, calendar: calendar) == 1)
    }

    @Test("A time of day still lands on that day")
    func timeWithinTheDayIsIgnored() {
        let days = [day(2019, 4, 20), day(2019, 4, 21)]
        let evening = day(2019, 4, 21).addingTimeInterval(20 * 3600)
        #expect(DayJump.index(for: evening, in: days, calendar: calendar) == 1)
    }

    @Test("Nothing shot that day lands on the nearest day either side")
    func nearestWins() {
        // Nothing on the 21st: the 23rd is two days out, the 18th is three.
        let days = [day(2019, 4, 18), day(2019, 4, 23)]
        #expect(DayJump.index(for: day(2019, 4, 21), in: days, calendar: calendar) == 1)
    }

    @Test("A tie goes to the earlier day, whichever way the grid is sorted")
    func tiesGoEarlier() {
        let newestFirst = [day(2019, 4, 23), day(2019, 4, 19)]
        let oldestFirst = [day(2019, 4, 19), day(2019, 4, 23)]
        let target = day(2019, 4, 21)

        #expect(DayJump.index(for: target, in: newestFirst, calendar: calendar) == 1)
        #expect(DayJump.index(for: target, in: oldestFirst, calendar: calendar) == 0)
    }

    @Test("A date outside the library lands on the end nearest to it")
    func outsideTheLibrary() {
        let days = [day(2019, 4, 18), day(2019, 4, 19), day(2019, 4, 20)]
        #expect(DayJump.index(for: day(1998, 1, 1), in: days, calendar: calendar) == 0)
        #expect(DayJump.index(for: day(2026, 1, 1), in: days, calendar: calendar) == 2)
    }
}
