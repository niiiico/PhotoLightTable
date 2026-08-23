import Testing

@testable import LightTable

private struct FakeEvent: Identifiable {
    let id: String
    let name: String
    var members: [String] = []
    var known = false
}

private func redundant(_ events: [FakeEvent], catalog: Set<String> = []) -> [String] {
    EventDuplicates.redundant(events,
                              members: \.members,
                              isKnownToCatalogue: \.known,
                              name: \.name,
                              catalogNames: catalog).map(\.id)
}

@Suite("Copies of the same event")
struct EventDuplicatesTests {
    @Test("Two events holding the same photographs: one is redundant")
    func plainDuplicate() {
        let events = [FakeEvent(id: "old", name: "old / Studio", members: ["a", "b"]),
                      FakeEvent(id: "new", name: "Workshop / Studio", members: ["a", "b"], known: true)]

        // The one the catalogue still knows is the one to keep.
        #expect(redundant(events) == ["old"])
    }

    @Test("Order in the store does not decide it")
    func stableChoice() {
        let known = FakeEvent(id: "known", name: "x", members: ["a"], known: true)
        let other = FakeEvent(id: "other", name: "y", members: ["a"])

        #expect(redundant([known, other]) == ["other"])
        #expect(redundant([other, known]) == ["other"])
    }

    @Test("With no provenance, the one the catalogue names is kept")
    func nameDecides() {
        let events = [FakeEvent(id: "stale", name: "old / Studio", members: ["a"]),
                      FakeEvent(id: "current", name: "Workshop / Studio", members: ["a"])]

        #expect(redundant(events, catalog: ["Workshop / Studio"]) == ["stale"])
    }

    @Test("Events that merely overlap are left alone")
    func overlapIsNotIdentity() {
        // A judgement nobody asked this to make: one may be a selection from
        // the other, and deleting somebody's picks is not tidying up.
        let events = [FakeEvent(id: "all", name: "a", members: ["a", "b", "c"]),
                      FakeEvent(id: "some", name: "b", members: ["a", "b"])]

        #expect(redundant(events).isEmpty)
    }

    @Test("Empty events are not all copies of each other")
    func emptyIsNotADuplicate() {
        let events = [FakeEvent(id: "one", name: "a"), FakeEvent(id: "two", name: "b")]
        #expect(redundant(events).isEmpty)
    }

    @Test("Three copies leave one")
    func threeCopies() {
        let events = [FakeEvent(id: "a", name: "a", members: ["x"], known: true),
                      FakeEvent(id: "b", name: "b", members: ["x"]),
                      FakeEvent(id: "c", name: "c", members: ["x"])]

        #expect(Set(redundant(events)) == ["b", "c"])
    }
}
