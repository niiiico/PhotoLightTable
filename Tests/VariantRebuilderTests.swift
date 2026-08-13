import Foundation
import Testing

@testable import LightTable

private let noon = Date(timeIntervalSinceReferenceDate: 800_000_000)

private func candidate(_ id: String,
                       at seconds: TimeInterval = 0,
                       signature: String = "img_1.heic#4032x3024",
                       added: TimeInterval? = nil) -> VariantRebuilder.Candidate {
    VariantRebuilder.Candidate(id: id,
                               creationDate: noon.addingTimeInterval(seconds),
                               signature: signature,
                               addedDate: added.map { noon.addingTimeInterval($0) })
}

@Suite("Recovering families from the library")
struct VariantRebuilderTests {
    @Test("Two photos with the same moment and the same file are one family")
    func matchesACopy() {
        let found = VariantRebuilder.families(
            from: [candidate("a", added: 0), candidate("b", added: 60)],
            known: [])

        #expect(found == [VariantRebuilder.Family(rootID: "a", variantIDs: ["b"])])
    }

    @Test("The one added to the library first is the original")
    func addedDateDecidesTheRoot() {
        // creationDate is copied onto a variant, so it cannot answer this;
        // addedDate is the asset's own.
        let found = VariantRebuilder.families(
            from: [candidate("later", added: 500), candidate("earlier", added: 10)],
            known: [])

        #expect(found.first?.rootID == "earlier")
        #expect(found.first?.variantIDs == ["later"])
    }

    @Test("A different moment is a different photograph")
    func differentCreationDate() {
        let found = VariantRebuilder.families(
            from: [candidate("a", at: 0), candidate("b", at: 1)],
            known: [])

        #expect(found.isEmpty)
    }

    @Test("The same moment with a different file is not a copy")
    func differentSignature() {
        // Two cameras firing together, or a RAW and a JPEG imported as a pair:
        // same instant, different files, and not versions of one another.
        let found = VariantRebuilder.families(
            from: [candidate("raw", signature: "img_1.cr2#6000x4000"),
                   candidate("jpeg", signature: "img_1.jpg#6000x4000")],
            known: [])

        #expect(found.isEmpty)
    }

    @Test("A photo with no creation date is never matched")
    func undatedIsSkipped() {
        // Nothing to agree on, and guessing here would be inventing a family.
        let undated = VariantRebuilder.Candidate(id: "x", creationDate: nil,
                                                 signature: "img_1.heic#1x1", addedDate: nil)
        let found = VariantRebuilder.families(from: [undated, undated], known: [])

        #expect(found.isEmpty)
    }

    @Test("A family the store already knows about is left alone")
    func existingRecordsWin() {
        // The store is the better authority where it still has an answer: it
        // holds the label the user saw, which this cannot recover.
        let found = VariantRebuilder.families(
            from: [candidate("a", added: 0), candidate("b", added: 60)],
            known: ["b"])

        #expect(found.isEmpty)
    }

    @Test("Knowing the source alone is enough to leave the family alone")
    func knowingTheRootIsEnough() {
        let found = VariantRebuilder.families(
            from: [candidate("a", added: 0), candidate("b", added: 60)],
            known: ["a"])

        #expect(found.isEmpty)
    }

    @Test("Three copies of one photo are one family, not three")
    func threeCopies() {
        let found = VariantRebuilder.families(
            from: [candidate("c", added: 200), candidate("a", added: 0), candidate("b", added: 100)],
            known: [])

        #expect(found == [VariantRebuilder.Family(rootID: "a", variantIDs: ["b", "c"])])
    }

    @Test("Unrelated families do not bleed into each other")
    func twoFamilies() {
        let found = VariantRebuilder.families(
            from: [candidate("a1", at: 0, signature: "a.heic#1x1", added: 0),
                   candidate("a2", at: 0, signature: "a.heic#1x1", added: 10),
                   candidate("b1", at: 90, signature: "b.heic#1x1", added: 0),
                   candidate("b2", at: 90, signature: "b.heic#1x1", added: 10)],
            known: [])

        #expect(found.count == 2)
        #expect(found.allSatisfy { $0.variantIDs.count == 1 })
    }

    @Test("A photo on its own is not a family")
    func singleton() {
        #expect(VariantRebuilder.families(from: [candidate("a")], known: []).isEmpty)
    }

    @Test("Without added dates the grouping still holds and the root is stable")
    func missingAddedDates() {
        // The fallback matters on older systems, where addedDate does not
        // exist: which one is called the original becomes arbitrary, but it
        // must not change between runs.
        let first = VariantRebuilder.families(
            from: [candidate("b"), candidate("a")], known: [])
        let second = VariantRebuilder.families(
            from: [candidate("a"), candidate("b")], known: [])

        #expect(first == second)
        #expect(first.first?.rootID == "a")
    }

    @Test("A known added date beats an unknown one")
    func knownAddedDateWins() {
        let found = VariantRebuilder.families(
            from: [candidate("unknown"), candidate("known", added: 900)],
            known: [])

        #expect(found.first?.rootID == "known")
    }
}
