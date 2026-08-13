import Foundation
import Testing

@testable import LightTable

/// A photo reduced to its identifier, which is all the stacking rule reads.
private struct FakePhoto: Identifiable {
    let id: String
}

private func photos(_ ids: String...) -> [FakePhoto] {
    ids.map(FakePhoto.init)
}

/// One family: `root` shares its pixels with each of `variants`.
private struct Family {
    let root: String
    let variants: [String]
}

private func stack(_ items: [FakePhoto],
                   families: [Family] = [],
                   expanded: Set<String> = []) -> (items: [FakePhoto], sizes: [String: Int]) {
    var rootOf: [String: String] = [:]
    var variantsOf: [String: [String]] = [:]
    for family in families {
        variantsOf[family.root] = family.variants
        for variant in family.variants {
            rootOf[variant] = family.root
        }
    }
    return LibraryProjection.stacked(items,
                                     rootOf: { rootOf[$0] ?? $0 },
                                     variantsOf: { variantsOf[$0] ?? [] },
                                     isExpanded: { expanded.contains($0) })
}

@Suite("Stacking a family in the grid")
struct StackingTests {
    @Test("Photos with no variants are left exactly as they are")
    func noFamilies() {
        let result = stack(photos("a", "b", "c"))

        #expect(result.items.map(\.id) == ["a", "b", "c"])
        #expect(result.sizes.isEmpty)
    }

    @Test("A closed family shows only its source, and says how many it stands for")
    func closedFamily() {
        let result = stack(photos("a", "bw", "crop", "b"),
                           families: [Family(root: "a", variants: ["bw", "crop"])])

        #expect(result.items.map(\.id) == ["a", "b"])
        #expect(result.sizes == ["a": 3])
    }

    @Test("An open family shows its members after the source, in order")
    func openFamily() {
        let result = stack(photos("a", "bw", "crop", "b"),
                           families: [Family(root: "a", variants: ["bw", "crop"])],
                           expanded: ["a"])

        #expect(result.items.map(\.id) == ["a", "bw", "crop", "b"])
        // Still counted while open — the badge is what closes it again.
        #expect(result.sizes == ["a": 3])
    }

    @Test("Variants are gathered to their source wherever they had sorted")
    func variantsAreGathered() {
        // The variant sorted between two unrelated photos; stacking pulls it in.
        let result = stack(photos("a", "b", "bw", "c"),
                           families: [Family(root: "a", variants: ["bw"])],
                           expanded: ["a"])

        #expect(result.items.map(\.id) == ["a", "bw", "b", "c"])
    }

    @Test("A variant whose source is filtered out stays where it fell")
    func orphanedVariantSurvives() {
        // Hiding a photo because its parent is hidden would be a second,
        // invisible filter.
        let result = stack(photos("bw", "b"),
                           families: [Family(root: "a", variants: ["bw"])])

        #expect(result.items.map(\.id) == ["bw", "b"])
        #expect(result.sizes.isEmpty)
    }

    @Test("Only the variants actually present are counted")
    func countsWhatIsShowing() {
        // "crop" was filtered out, so the stack stands for two, not three.
        let result = stack(photos("a", "bw"),
                           families: [Family(root: "a", variants: ["bw", "crop"])])

        #expect(result.items.map(\.id) == ["a"])
        #expect(result.sizes == ["a": 2])
    }

    @Test("A family of one is not a stack")
    func singletonIsNotAStack() {
        let result = stack(photos("a", "b"),
                           families: [Family(root: "a", variants: [])])

        #expect(result.items.map(\.id) == ["a", "b"])
        #expect(result.sizes.isEmpty)
    }

    @Test("Families are independent of one another")
    func twoFamilies() {
        let result = stack(photos("a", "a-bw", "b", "b-bw", "c"),
                           families: [Family(root: "a", variants: ["a-bw"]),
                                      Family(root: "b", variants: ["b-bw"])],
                           expanded: ["b"])

        #expect(result.items.map(\.id) == ["a", "b", "b-bw", "c"])
        #expect(result.sizes == ["a": 2, "b": 2])
    }

    @Test("No photo is emitted twice, whatever the family says")
    func noDuplicates() {
        // A malformed family naming a photo twice must not double it in the
        // grid — a duplicated id would break selection and focus.
        let result = stack(photos("a", "bw"),
                           families: [Family(root: "a", variants: ["bw", "bw"])],
                           expanded: ["a"])

        #expect(result.items.map(\.id) == ["a", "bw"])
    }

    @Test("Every photo that went in comes out, open or closed")
    func nothingIsLost() {
        let input = photos("a", "bw", "crop", "b", "c")
        let families = [Family(root: "a", variants: ["bw", "crop"])]

        let open = stack(input, families: families, expanded: ["a"])
        #expect(Set(open.items.map(\.id)) == Set(input.map(\.id)))

        // Closed, the variants are deliberately absent — but nothing else is.
        let closed = stack(input, families: families)
        #expect(closed.items.map(\.id) == ["a", "b", "c"])
    }
}
