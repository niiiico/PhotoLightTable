import Foundation
import Testing

@testable import LightTable

/// A library photograph reduced to what the matcher reads.
private struct FakePhoto: MatchablePhoto {
    let id: String
    let creationDate: Date?
    var pixelWidth: Int = 3888
    var pixelHeight: Int = 2592
}

private let origin = Date(timeIntervalSince1970: 1_200_000_000)

private func moment(_ seconds: Int) -> Date {
    origin.addingTimeInterval(TimeInterval(seconds))
}

private func catalogPhoto(_ id: Int64,
                          at seconds: Int?,
                          width: Int = 3888,
                          height: Int = 2592) -> LightroomMatch.CatalogPhoto {
    LightroomMatch.CatalogPhoto(localID: id,
                               fileName: "IMG_\(id).CR2",
                               captureTime: seconds.map(moment),
                               pixelWidth: width,
                               pixelHeight: height)
}

@Suite("Matching a Lightroom catalogue to the library")
struct LightroomMatchTests {
    @Test("A photograph is found by the second it was taken")
    func matchesOnTheMoment() {
        let index = LightroomMatch.LibraryIndex([
            FakePhoto(id: "asset-a", creationDate: moment(0)),
            FakePhoto(id: "asset-b", creationDate: moment(30)),
        ])
        let outcome = LightroomMatch.match([catalogPhoto(1, at: 30)], in: index)

        #expect(outcome.matched == [1: "asset-b"])
        #expect(outcome.unmatched.isEmpty)
    }

    @Test("The library's fraction of a second does not hide a photograph")
    func subSecondsDoNotHide() {
        // Lightroom writes 12:15:07.26 and truncates to :07; the library keeps
        // the fraction. Rounding this side filed everything past the halfway
        // mark one second late — half a shoot, from any camera that records
        // sub-seconds.
        let index = LightroomMatch.LibraryIndex([
            FakePhoto(id: "late", creationDate: moment(30).addingTimeInterval(0.75)),
            FakePhoto(id: "early", creationDate: moment(90).addingTimeInterval(0.2)),
        ])
        let outcome = LightroomMatch.match([catalogPhoto(1, at: 30), catalogPhoto(2, at: 90)],
                                           in: index)

        #expect(outcome.matched == [1: "late", 2: "early"])
    }

    @Test("A second either way is allowed, but only when that second is empty")
    func neighbouringSecond() {
        let index = LightroomMatch.LibraryIndex([FakePhoto(id: "asset", creationDate: moment(31))])
        #expect(LightroomMatch.match([catalogPhoto(1, at: 30)], in: index).matched == [1: "asset"])

        // A burst is not resolved by reaching into its neighbours: the frame on
        // the exact second is ambiguous, and that is an answer.
        let burst = LightroomMatch.LibraryIndex([
            FakePhoto(id: "a", creationDate: moment(30)),
            FakePhoto(id: "b", creationDate: moment(30)),
            FakePhoto(id: "c", creationDate: moment(31)),
        ])
        #expect(LightroomMatch.match([catalogPhoto(1, at: 30)], in: burst).matched.isEmpty)
    }

    @Test("A photograph the library does not hold stays unmatched")
    func missingStaysMissing() {
        let index = LightroomMatch.LibraryIndex([FakePhoto(id: "asset-a", creationDate: moment(0))])
        let outcome = LightroomMatch.match([catalogPhoto(1, at: 999)], in: index)

        #expect(outcome.matched.isEmpty)
        #expect(outcome.unmatched.map(\.localID) == [1])
    }

    @Test("A photograph with no capture time cannot be looked for")
    func undatedIsUnmatched() {
        let index = LightroomMatch.LibraryIndex([FakePhoto(id: "asset-a", creationDate: moment(0))])
        let outcome = LightroomMatch.match([catalogPhoto(1, at: nil)], in: index)

        #expect(outcome.matched.isEmpty)
        #expect(outcome.unmatched.map(\.localID) == [1])
    }

    @Test("Two frames on the same second are told apart by shape")
    func shapeBreaksTheTie() {
        let index = LightroomMatch.LibraryIndex([
            FakePhoto(id: "landscape", creationDate: moment(0), pixelWidth: 3888, pixelHeight: 2592),
            FakePhoto(id: "square", creationDate: moment(0), pixelWidth: 2592, pixelHeight: 2592),
        ])
        let outcome = LightroomMatch.match([catalogPhoto(1, at: 0, width: 2592, height: 2592)],
                                           in: index)

        #expect(outcome.matched == [1: "square"])
    }

    @Test("A portrait frame matches whichever way round the library holds it")
    func rotationIsNotADifference() {
        let index = LightroomMatch.LibraryIndex([
            FakePhoto(id: "upright", creationDate: moment(0), pixelWidth: 2592, pixelHeight: 3888),
            FakePhoto(id: "other", creationDate: moment(0), pixelWidth: 1000, pixelHeight: 1000),
        ])
        let outcome = LightroomMatch.match([catalogPhoto(1, at: 0, width: 3888, height: 2592)], in: index)

        #expect(outcome.matched == [1: "upright"])
    }

    @Test("Two frames of the same shape on the same second are left alone")
    func ambiguityIsNotGuessedAt() {
        // An event built from the wrong photographs is worse than one that says
        // it is missing some.
        let index = LightroomMatch.LibraryIndex([
            FakePhoto(id: "one", creationDate: moment(0)),
            FakePhoto(id: "two", creationDate: moment(0)),
        ])
        let outcome = LightroomMatch.match([catalogPhoto(1, at: 0)], in: index)

        #expect(outcome.matched.isEmpty)
        #expect(outcome.unmatched.map(\.localID) == [1])
    }

    @Test("A camera clock left on home time shifts the whole collection")
    func timezoneShiftIsFound() {
        // Nine hours out, every frame, which is what a fortnight abroad looks
        // like: found once for the collection rather than as thirty failures.
        let shift: TimeInterval = 9 * 3600
        let photos = (1...30).map { catalogPhoto(Int64($0), at: $0 * 60) }
        let index = LightroomMatch.LibraryIndex(photos.map {
            FakePhoto(id: "asset-\($0.localID)",
                      creationDate: $0.captureTime!.addingTimeInterval(shift))
        })

        let outcome = LightroomMatch.match(photos, in: index)

        #expect(outcome.offset == shift)
        #expect(outcome.count == 30)
    }

    @Test("A single stray hit does not drag the collection sideways")
    func aShiftHasToExplainMostOfIt() {
        // Twenty frames land exactly; one other photograph in the library
        // happens to sit an hour off one of them. The hour is not the answer.
        let photos = (1...20).map { catalogPhoto(Int64($0), at: $0 * 60) }
        var library = photos.map {
            FakePhoto(id: "asset-\($0.localID)", creationDate: $0.captureTime!)
        }
        library.append(FakePhoto(id: "coincidence",
                                 creationDate: moment(60).addingTimeInterval(3600)))

        let outcome = LightroomMatch.match(photos, in: LightroomMatch.LibraryIndex(library))

        #expect(outcome.offset == 0)
        #expect(outcome.count == 20)
    }
}
