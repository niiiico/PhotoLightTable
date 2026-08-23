import Testing

@testable import LightTable

private struct FakeEvent {
    let name: String
    var origin: String?
}

private func vanished(_ events: [FakeEvent], _ paths: Set<String>) -> [String] {
    EventSync.vanished(events, origin: \.origin, catalogPaths: paths).map(\.name)
}

@Suite("Events whose collection is gone")
struct EventSyncTests {
    @Test("An imported event whose collection has been deleted")
    func deletedCollection() {
        let events = [FakeEvent(name: "old / Studio", origin: "old / Studio"),
                      FakeEvent(name: "Places / Hawaii", origin: "Places / Hawaii")]

        #expect(vanished(events, ["Places / Hawaii"]) == ["old / Studio"])
    }

    @Test("An event made by hand is never a candidate, whatever it is called")
    func handMade() {
        // The whole reason provenance exists rather than a guess about names:
        // "Trips / Corsica" is a perfectly ordinary thing to type.
        let events = [FakeEvent(name: "Trips / Corsica", origin: nil)]
        #expect(vanished(events, []).isEmpty)
    }

    @Test("An event renamed here keeps its origin, and its collection is found")
    func renamed() {
        // Renaming the event does not rename the collection it stands for.
        let events = [FakeEvent(name: "Corsica 2019", origin: "Places / Corsica")]
        #expect(vanished(events, ["Places / Corsica"]).isEmpty)
    }

    @Test("Nothing in the catalogue means everything imported has gone")
    func emptyCatalogue() {
        // Which is what pointing the import at the wrong catalogue looks like,
        // so it is a number worth showing before anything is removed.
        let events = [FakeEvent(name: "a", origin: "a"), FakeEvent(name: "b", origin: "b")]
        #expect(vanished(events, []).count == 2)
    }
}
