import Testing

@testable import LightTable

@Suite("Importing a collection twice")
struct EventMergeTests {
    @Test("The second run adds what it found and keeps what was there")
    func union() {
        let merged = EventMerge.merged(existing: ["a", "b"], incoming: ["b", "c"])
        #expect(merged == ["a", "b", "c"])
    }

    @Test("Running it again with the same result changes nothing")
    func idempotent() {
        let once = EventMerge.merged(existing: [], incoming: ["a", "b"])
        let twice = EventMerge.merged(existing: once, incoming: ["a", "b"])

        #expect(once == twice)
        #expect(EventMerge.adds(existing: once, incoming: ["a", "b"]) == 0)
    }

    @Test("What the event already held keeps its place")
    func orderIsKept() {
        // The order is often the order the photographs were arranged in, which
        // is a judgement worth not shuffling on the way past.
        let merged = EventMerge.merged(existing: ["c", "a"], incoming: ["a", "b", "c"])
        #expect(merged == ["c", "a", "b"])
    }

    @Test("A photograph that stopped matching is not dropped")
    func nothingIsRemoved() {
        // It has usually not left the library: a frame whose file was replaced,
        // or one hidden while the run was measuring. An event is somebody's
        // list, and an import has no business shortening it.
        let merged = EventMerge.merged(existing: ["a", "b"], incoming: ["a"])
        #expect(merged == ["a", "b"])
    }

    @Test("Duplicates in what was found land once")
    func incomingDuplicates() {
        #expect(EventMerge.merged(existing: [], incoming: ["a", "a", "b"]) == ["a", "b"])
    }

    @Test("How many are new, before anything is written")
    func counts() {
        #expect(EventMerge.adds(existing: ["a"], incoming: ["a", "b", "c"]) == 2)
        #expect(EventMerge.adds(existing: ["a", "b"], incoming: []) == 0)
    }
}
