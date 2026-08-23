import Testing

@testable import LightTable

private struct FakeEvent: Identifiable {
    let id: String
    let members: [String]
}

private func adopt(_ collections: [(Int64, [String])],
                   _ events: [FakeEvent]) -> [Int64: String] {
    EventProvenance.adopt(collections: collections.map { (id: $0.0, members: $0.1) },
                          candidates: events,
                          members: \.members)
}

@Suite("Recognising a collection an event has drifted from")
struct EventProvenanceTests {
    @Test("An event moved to another folder is still its collection")
    func renamed() {
        // Which is what "Move to Folder" does: the event is renamed and the
        // collection is not, and nothing but the membership still agrees.
        let photographs = (1...20).map { "photo-\($0)" }
        let result = adopt([(1, photographs)], [FakeEvent(id: "moved", members: photographs)])

        #expect(result == [1: "moved"])
    }

    @Test("A handful of picks from a big shoot is not that shoot")
    func subsetIsNotTheSame() {
        // Entirely inside the collection, and nowhere near all of it. This is
        // the case that requires the overlap to hold both ways round.
        let shoot = (1...100).map { "photo-\($0)" }
        let picks = Array(shoot.prefix(12))

        #expect(adopt([(1, shoot)], [FakeEvent(id: "picks", members: picks)]).isEmpty)
    }

    @Test("A few photographs added or missing does not break the recognition")
    func nearlyTheSame() {
        let shoot = (1...100).map { "photo-\($0)" }
        var held = Array(shoot.dropLast(10))
        held.append("something-else")

        #expect(adopt([(1, shoot)], [FakeEvent(id: "close", members: held)]) == [1: "close"])
    }

    @Test("Unrelated events are left alone")
    func unrelated() {
        #expect(adopt([(1, ["a", "b", "c"])], [FakeEvent(id: "other", members: ["x", "y"])]).isEmpty)
    }

    @Test("One collection claims one event, and the best fit wins")
    func oneToOne() {
        let shoot = (1...20).map { "photo-\($0)" }
        let exact = FakeEvent(id: "exact", members: shoot)
        let nearly = FakeEvent(id: "nearly", members: Array(shoot.dropLast(4)))

        let result = adopt([(1, shoot)], [exact, nearly])

        #expect(result == [1: "exact"])
    }

    @Test("Nothing to go on")
    func empty() {
        #expect(adopt([(1, [])], [FakeEvent(id: "e", members: ["a"])]).isEmpty)
        #expect(adopt([], [FakeEvent(id: "e", members: ["a"])]).isEmpty)
    }
}
