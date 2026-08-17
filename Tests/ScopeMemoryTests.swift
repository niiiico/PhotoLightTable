import Testing

@testable import LightTable

/// Scopes stand in for `LibrarySelection`, which needs a SwiftData store to
/// mint the identifiers an event case carries.
@Suite("Where we were")
struct ScopeMemoryTests {
    @Test("A scope never visited has nothing to go back to")
    func unvisitedScopeIsEmpty() {
        let memory = ScopeMemory<String>()
        #expect(memory.focus(in: "all") == nil)
    }

    @Test("Each scope keeps its own place")
    func scopesAreIndependent() {
        var memory = ScopeMemory<String>()
        memory.remember("photo-40", in: "all")
        memory.remember("photo-2", in: "wedding")

        #expect(memory.focus(in: "all") == "photo-40")
        #expect(memory.focus(in: "wedding") == "photo-2")
    }

    @Test("The latest place in a scope is the one kept")
    func lastOneWins() {
        var memory = ScopeMemory<String>()
        memory.remember("photo-1", in: "all")
        memory.remember("photo-9", in: "all")

        #expect(memory.focus(in: "all") == "photo-9")
    }

    @Test("A photograph that leaves is forgotten everywhere")
    func forgettingClearsEveryScope() {
        var memory = ScopeMemory<String>()
        // The same photo can be where you were in more than one album, which is
        // exactly the case a filter over one scope would miss.
        memory.remember("photo-3", in: "all")
        memory.remember("photo-3", in: "wedding")
        memory.remember("photo-8", in: "holiday")

        memory.forget("photo-3")

        #expect(memory.focus(in: "all") == nil)
        #expect(memory.focus(in: "wedding") == nil)
        #expect(memory.focus(in: "holiday") == "photo-8")
    }
}
