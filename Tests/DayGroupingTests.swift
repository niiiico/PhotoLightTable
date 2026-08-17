import Foundation
import Testing

@testable import LightTable

private struct FakePhoto {
    let id: String
    let date: Date?
}

private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

private func moment(_ day: Int, _ hour: Int) -> Date {
    calendar.date(from: DateComponents(year: 2019, month: 4, day: day, hour: hour))!
}

private func group(_ photos: [FakePhoto], oldestFirst: Bool = false)
-> [(day: Date, ids: [String])] {
    PhotoLibraryService.grouped(photos, dateOf: \.date, oldestFirst: oldestFirst,
                                calendar: calendar)
        .map { ($0.day, $0.items.map(\.id)) }
}

@Suite("Grouping photographs into days")
struct DayGroupingTests {
    @Test("A day's photographs stay together, in the order they came")
    func oneDay() {
        let result = group([FakePhoto(id: "a", date: moment(21, 9)),
                            FakePhoto(id: "b", date: moment(21, 14)),
                            FakePhoto(id: "c", date: moment(21, 18))])

        #expect(result.count == 1)
        #expect(result[0].ids == ["a", "b", "c"])
    }

    @Test("Days come out newest or oldest first, as asked")
    func ordering() {
        let photos = [FakePhoto(id: "new", date: moment(22, 9)),
                      FakePhoto(id: "old", date: moment(20, 9))]

        #expect(group(photos).map(\.ids) == [["new"], ["old"]])
        #expect(group(photos, oldestFirst: true).map(\.ids) == [["old"], ["new"]])
    }

    @Test("A photograph arriving late still joins its own day")
    func stragglerMerges() {
        // What the stacking pass does with a variant whose source is filtered
        // out: it is appended after everything else, days away from its own.
        let result = group([FakePhoto(id: "a", date: moment(22, 9)),
                            FakePhoto(id: "b", date: moment(21, 9)),
                            FakePhoto(id: "straggler", date: moment(22, 11))])

        #expect(result.count == 2)
        #expect(result[0].ids == ["a", "straggler"])
        #expect(result[1].ids == ["b"])
    }

    @Test("Photographs with no date land in one place rather than everywhere")
    func undated() {
        let result = group([FakePhoto(id: "a", date: nil),
                            FakePhoto(id: "b", date: moment(21, 9)),
                            FakePhoto(id: "c", date: nil)])

        #expect(result.count == 2)
        #expect(result.first { $0.ids.contains("a") }?.ids == ["a", "c"])
    }

    @Test("Nothing in, nothing out")
    func empty() {
        #expect(group([]).isEmpty)
    }
}
