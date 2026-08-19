import Testing

@testable import LightTable

@Suite("A hidden album")
struct EventPrivacyTests {
    @Test("Every photograph hidden makes the album hidden")
    func allHidden() {
        #expect(EventPrivacy.isHidden(memberIDs: ["a", "b"], hiddenIDs: ["a", "b", "c"]))
    }

    @Test("One hidden photograph does not hide the album")
    func oneHidden() {
        // An ordinary event with one photograph missing from it, not a private
        // one — otherwise hiding a single frame would lock a hundred others.
        #expect(!EventPrivacy.isHidden(memberIDs: ["a", "b"], hiddenIDs: ["a"]))
    }

    @Test("An empty album is not hidden")
    func empty() {
        // Vacuously true is the wrong answer: an event with nothing in it has
        // nothing to protect, and locking it would only puzzle whoever made it.
        #expect(!EventPrivacy.isHidden(memberIDs: [], hiddenIDs: ["a"]))
    }

    @Test("Nothing hidden at all")
    func noneHidden() {
        #expect(!EventPrivacy.isHidden(memberIDs: ["a"], hiddenIDs: []))
    }
}
