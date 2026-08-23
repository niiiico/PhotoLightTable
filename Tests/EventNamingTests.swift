import Testing

@testable import LightTable

@Suite("Following a collection's name")
struct EventNamingTests {
    @Test("An untouched event takes the collection's new name")
    func follows() {
        // Renamed in Lightroom from old/ to Workshop/: the same collection,
        // and the event should move with it rather than be imported again.
        let after = EventNaming.name(for: (name: "old / Studio", importedAs: "old / Studio"),
                                     collection: "Workshop / Studio")
        #expect(after == "Workshop / Studio")
    }

    @Test("An event renamed here keeps the name it was given")
    func doesNotFollowOnceRenamed() {
        let after = EventNaming.name(for: (name: "Studio, May 2007", importedAs: "old / Studio"),
                                     collection: "Workshop / Studio")
        #expect(after == "Studio, May 2007")
    }

    @Test("Moving an event to a folder is a rename, and stops the following")
    func movingCounts() {
        // Which is what Move to Folder does. The point of the flag is that
        // tidying up here is not undone by the next import.
        #expect(!EventNaming.followsCatalogue(name: "Trips / Studio", importedAs: "old / Studio"))
    }

    @Test("An event that never came from a catalogue follows nothing")
    func handMade() {
        #expect(!EventNaming.followsCatalogue(name: "Corsica", importedAs: nil))
        #expect(EventNaming.name(for: (name: "Corsica", importedAs: nil),
                                 collection: "Places / Corsica") == "Corsica")
    }
}
