import Foundation
import Testing

@testable import LightTable

private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

private func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: day))!
}

@Suite("Timeline rail")
struct TimelineIndexTests {
    @Test("An empty grid has no scale")
    func emptyGrid() {
        #expect(TimelineIndex.ticks(for: [], calendar: calendar).isEmpty)
    }

    @Test("Ticks are placed by how much was shot, not by how much time passed")
    func placedByVolume() {
        // Three days across two years: one of them is four hundred frames, the
        // others are one each. A calendar-shaped rail would put the 2021 mark
        // two-thirds of the way down; scrolling puts it almost at the bottom.
        let days = [(day(2019, 1, 1), 1), (day(2019, 6, 1), 400), (day(2021, 1, 1), 1)]
        let ticks = TimelineIndex.ticks(for: days, calendar: calendar)

        #expect(ticks.map(\.label) == ["2019", "2021"])
        #expect(ticks[0].fraction == 0)
        #expect(ticks[1].fraction > 0.99)
    }

    @Test("A short span is marked by month, a long one by year")
    func granularityFollowsTheSpan() {
        let shortSpan = [(day(2019, 1, 5), 10), (day(2019, 3, 5), 10), (day(2019, 5, 5), 10)]
        #expect(TimelineIndex.ticks(for: shortSpan, calendar: calendar).count == 3)

        let longSpan = [(day(2015, 1, 5), 10), (day(2015, 3, 5), 10), (day(2020, 5, 5), 10)]
        #expect(TimelineIndex.ticks(for: longSpan, calendar: calendar).map(\.label) == ["2015", "2020"])
    }

    @Test("The year is spelled out on the first month and each January only")
    func yearsAppearWhereTheyAreNeeded() {
        let days = [(day(2019, 11, 1), 5), (day(2019, 12, 1), 5), (day(2020, 1, 1), 5)]
        let labels = TimelineIndex.ticks(for: days, calendar: calendar).map(\.label)

        #expect(labels.first?.contains("2019") == true)
        #expect(labels[1] == "Dec")
        #expect(labels[2].contains("2020"))
    }

    @Test("One tick per unit, however many days are in it")
    func daysCollapseIntoTheirUnit() {
        let days = (1...20).map { (day(2019, 4, $0), 3) }
        #expect(TimelineIndex.ticks(for: days, calendar: calendar).count == 1)
    }

    @Test("Fractions never go backwards")
    func fractionsAreMonotonic() {
        let days = (0..<40).map { (day(2010 + $0 / 4, 1 + ($0 % 4) * 3, 1), $0 + 1) }
        let ticks = TimelineIndex.ticks(for: days, calendar: calendar)

        #expect(ticks == ticks.sorted { $0.fraction < $1.fraction })
        #expect(ticks.allSatisfy { $0.fraction >= 0 && $0.fraction <= 1 })
    }

    @Test("Landing is the inverse of drawing: the fraction resolves to its day")
    func fractionResolvesToADay() {
        // Ten, then four hundred, then ten: the middle day owns almost the
        // whole rail, and the pointer anywhere in it has to land there.
        let counts = [10, 400, 10]

        #expect(TimelineIndex.index(atFraction: 0, in: counts) == 0)
        #expect(TimelineIndex.index(atFraction: 0.5, in: counts) == 1)
        #expect(TimelineIndex.index(atFraction: 1, in: counts) == 2)
    }

    @Test("A fraction outside the rail is clamped to its ends")
    func fractionIsClamped() {
        #expect(TimelineIndex.index(atFraction: -3, in: [5, 5]) == 0)
        #expect(TimelineIndex.index(atFraction: 9, in: [5, 5]) == 1)
        #expect(TimelineIndex.index(atFraction: 0.5, in: []) == nil)
    }

    @Test("A long library is thinned to a scale, keeping both ends")
    func thinningKeepsTheEnds() {
        let days = (0..<60).map { (day(1970 + $0, 6, 1), 10) }
        let ticks = TimelineIndex.ticks(for: days, maxLabels: 12, calendar: calendar)

        #expect(ticks.count <= 12)
        #expect(ticks.first?.label == "1970")
        #expect(ticks.last?.label == "2029")
    }
}
