import CoreLocation
import Foundation
import Testing

@testable import PhotoLightTable

/// A photo reduced to what clustering looks at, so the grouping rules can be
/// exercised with chosen dates and places. `PHAsset` cannot be constructed with
/// a creation date, which is the whole reason `TemporalPhoto` exists.
private struct FakePhoto: TemporalPhoto {
    let id: String
    let creationDate: Date?
    let location: CLLocation?

    init(_ id: String, at date: Date?, location: CLLocation? = nil) {
        self.id = id
        self.creationDate = date
        self.location = location
    }
}

/// A fixed origin, so no test depends on the day it runs.
private let origin = Date(timeIntervalSince1970: 1_700_000_000)

private func hours(_ count: Double) -> TimeInterval { count * 3600 }

private func photo(_ id: String,
                   plusHours offset: Double,
                   location: CLLocation? = nil) -> FakePhoto {
    FakePhoto(id, at: origin.addingTimeInterval(hours(offset)), location: location)
}

@Suite("Clustering by time")
struct ClusterTimeTests {
    @Test("Photos inside the gap stay in one group")
    func withinGapStaysTogether() {
        let items = [photo("a", plusHours: 0), photo("b", plusHours: 1)]
        let groups = EventSuggester.clusters(in: items, granularity: .session)

        #expect(groups.count == 1)
        #expect(groups[0].map(\.id) == ["a", "b"])
    }

    @Test("A gap wider than the granularity starts a new group")
    func gapSplits() {
        // Session is 2h; three hours apart has to break.
        let items = [photo("a", plusHours: 0), photo("b", plusHours: 3)]
        let groups = EventSuggester.clusters(in: items, granularity: .session)

        #expect(groups.count == 2)
        #expect(groups[0].map(\.id) == ["a"])
        #expect(groups[1].map(\.id) == ["b"])
    }

    @Test("The gap is measured from the previous photo, not the group's start")
    func gapIsFromPreviousPhoto() {
        // Six hours end to end, but never more than 90 minutes between two
        // consecutive shots — one continuous session.
        let items = (0..<5).map { photo("p\($0)", plusHours: Double($0) * 1.5) }
        let groups = EventSuggester.clusters(in: items, granularity: .session)

        #expect(groups.count == 1)
        #expect(groups[0].count == 5)
    }

    @Test("A wider granularity keeps together what a narrower one splits")
    func granularityWidens() {
        // Ten hours apart: splits at session (2h) and outing (8h), holds at
        // day (20h) and trip (48h).
        let items = [photo("a", plusHours: 0), photo("b", plusHours: 10)]

        #expect(EventSuggester.clusters(in: items, granularity: .session).count == 2)
        #expect(EventSuggester.clusters(in: items, granularity: .outing).count == 2)
        #expect(EventSuggester.clusters(in: items, granularity: .day).count == 1)
        #expect(EventSuggester.clusters(in: items, granularity: .trip).count == 1)
    }

    @Test("Input order does not matter; groups come back oldest first")
    func inputOrderIgnored() {
        let items = [photo("c", plusHours: 24), photo("a", plusHours: 0), photo("b", plusHours: 1)]
        let groups = EventSuggester.clusters(in: items, granularity: .session)

        #expect(groups.map { $0.map(\.id) } == [["a", "b"], ["c"]])
    }

    @Test("Photos without a date are dropped rather than grouped")
    func undatedDropped() {
        let items = [photo("a", plusHours: 0), FakePhoto("undated", at: nil)]
        let groups = EventSuggester.clusters(in: items, granularity: .session)

        #expect(groups.flatMap { $0 }.map(\.id) == ["a"])
    }

    @Test("An empty library yields no groups rather than one empty group")
    func emptyInput() {
        #expect(EventSuggester.clusters(in: [FakePhoto](), granularity: .session).isEmpty)
    }
}

@Suite("Clustering by place")
struct ClusterPlaceTests {
    private static let toulouse = CLLocation(latitude: 43.6047, longitude: 1.4442)
    /// ~380km from Toulouse — well past the 60km threshold.
    private static let barcelona = CLLocation(latitude: 41.3874, longitude: 2.1686)
    /// ~3km from Toulouse — comfortably inside it.
    private static let acrossTown = CLLocation(latitude: 43.6300, longitude: 1.4442)

    @Test("A long jump splits the group even when the clock would not")
    func distanceSplits() {
        let items = [photo("a", plusHours: 0, location: Self.toulouse),
                     photo("b", plusHours: 1, location: Self.barcelona)]
        let groups = EventSuggester.clusters(in: items, granularity: .trip)

        #expect(groups.count == 2)
    }

    @Test("Moving around inside the threshold does not split")
    func shortMoveDoesNotSplit() {
        let items = [photo("a", plusHours: 0, location: Self.toulouse),
                     photo("b", plusHours: 1, location: Self.acrossTown)]
        let groups = EventSuggester.clusters(in: items, granularity: .session)

        #expect(groups.count == 1)
    }

    @Test("Location is only consulted when both photos have a fix")
    func oneSidedLocationIgnored() {
        let items = [photo("a", plusHours: 0, location: Self.toulouse),
                     photo("b", plusHours: 1, location: nil),
                     photo("c", plusHours: 2, location: Self.barcelona)]
        // b has no fix, so neither pair can be compared by distance and the
        // clock alone decides — one group.
        let groups = EventSuggester.clusters(in: items, granularity: .session)

        #expect(groups.count == 1)
        #expect(groups[0].count == 3)
    }
}

@Suite("Growing a selection")
struct RelatedTests {
    private var library: [FakePhoto] {
        // Two sessions, four hours apart.
        [photo("a", plusHours: 0), photo("b", plusHours: 1),
         photo("c", plusHours: 5), photo("d", plusHours: 6)]
    }

    @Test("One seed pulls in its whole group and nothing else")
    func seedGrowsToGroup() {
        let related = EventSuggester.related(to: ["a"], in: library, granularity: .session)

        #expect(related.map(\.id) == ["a", "b"])
    }

    @Test("Seeds spanning a boundary pull in both groups")
    func seedsAcrossBoundary() {
        let related = EventSuggester.related(to: ["a", "c"], in: library, granularity: .session)

        #expect(related.map(\.id) == ["a", "b", "c", "d"])
    }

    @Test("No seeds means no result, rather than the whole library")
    func emptySeeds() {
        #expect(EventSuggester.related(to: [String](), in: library, granularity: .session).isEmpty)
    }

    @Test("A seed that is not in the library yields nothing")
    func unknownSeed() {
        #expect(EventSuggester.related(to: ["missing"], in: library, granularity: .session).isEmpty)
    }
}

@Suite("Date range")
struct DateRangeTests {
    @Test("Bounds span the oldest and newest photo regardless of input order")
    func boundsSpanExtremes() {
        let items = [photo("b", plusHours: 5), photo("a", plusHours: 0), photo("c", plusHours: 2)]
        let range = EventSuggester.dateRange(of: items)

        #expect(range?.start == origin)
        #expect(range?.end == origin.addingTimeInterval(hours(5)))
    }

    @Test("No dated photos means no range")
    func noDates() {
        #expect(EventSuggester.dateRange(of: [FakePhoto("x", at: nil)]) == nil)
    }
}

@Suite("Granularity ladder")
struct GranularityTests {
    @Test("Each step is strictly wider than the last")
    func gapsIncrease() {
        let ladder: [ClusterGranularity] = [.session, .outing, .day, .trip]
        for (narrower, wider) in zip(ladder, ladder.dropFirst()) {
            #expect(narrower.maximumGap < wider.maximumGap)
        }
    }

    @Test("`next` walks the ladder once and stops at the widest")
    func nextTerminates() {
        // Pressing R repeatedly widens the selection; if this ever cycled, it
        // would never settle.
        var seen: [ClusterGranularity] = []
        var current: ClusterGranularity? = .session
        while let step = current {
            #expect(!seen.contains(step))
            seen.append(step)
            current = step.next
        }

        #expect(seen == [.session, .outing, .day, .trip])
    }
}
