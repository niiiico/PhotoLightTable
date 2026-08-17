import Testing

@testable import LightTable

/// The palette is two sets of grey levels, and what matters is not the numbers
/// but the relationships between them: a photograph has to read the same way in
/// either appearance, which it only does if the surfaces keep their order and
/// their distances.
@Suite("Surface palettes")
struct SurfacesTests {
    @Test("The light palette is the dark one lifted, not a second design")
    func lightIsDarkLifted() {
        let dark = Surfaces.Levels.dark
        let light = Surfaces.Levels.light
        let lift = light.table - dark.table

        #expect(lift > 0)
        for (darkLevel, lightLevel) in zip(dark.ordered, light.ordered) {
            #expect(abs((lightLevel - darkLevel) - lift) < 0.0001)
        }
    }

    @Test("Every surface keeps its place in the stack", arguments: [Surfaces.Levels.dark, .light])
    func orderHolds(_ levels: Surfaces.Levels) {
        // Darkest first: the loupe, then the chrome around the table, the mat
        // under a letterboxed photograph, the table, and the day headers.
        #expect(levels.ordered == levels.ordered.sorted())
    }

    @Test("Nothing is driven out of range by the lift", arguments: [Surfaces.Levels.dark, .light])
    func staysInRange(_ levels: Surfaces.Levels) {
        for level in levels.ordered {
            #expect(level > 0 && level < 1)
        }
    }

    @Test("The lift stops well short of white, so no surface outshines a photograph")
    func lightStaysASurface() {
        // A photograph on a field brighter than itself reads as a hole in the
        // screen; the light appearance is a lit room, not a lightbox.
        #expect(Surfaces.Levels.light.header < 0.5)
    }
}
