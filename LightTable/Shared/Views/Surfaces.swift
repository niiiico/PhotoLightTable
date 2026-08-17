import SwiftUI

/// The greys photographs are judged against.
///
/// Neutral by construction — a surface with any colour in it shifts the white
/// balance of everything laid on it — and several shades rather than one so an
/// edge is legible without a border: the table sits behind the cells, the mat
/// behind a photograph that does not fill its own cell, and the chrome that
/// touches the table (sidebar, toolbar, day headers) is cut from the same
/// neutral rather than borrowing the system's, which arrives bright and faintly
/// blue and drags the eye off the photographs.
///
/// What is highlighted — the selected album, the focused photograph — is not
/// here: it is the app's accent colour, a neutral grey in the asset catalog
/// rather than the system blue. One colour, set in one place, so a highlight
/// cannot end up meaning two different things in two different views. The
/// reason is the same as for the greys: a saturated bar a few inches from a
/// photograph is a colour cast in the corner of the eye.
///
/// The light appearance is not a second design: it is the same room with the
/// lights brought up. Every level is lifted by one fixed amount, so the
/// relationships between the surfaces — and the way a photograph reads against
/// them — survive the change. Text stays light in both, which is why the chrome
/// forces the dark scheme whatever the appearance says.
struct Surfaces {
    /// Grey levels rather than colours, so the relationships between them can be
    /// stated once and checked.
    struct Levels: Equatable {
        /// Behind the photograph in the loupe, where nothing else competes.
        var loupe: Double
        /// Behind the sidebar and the window toolbar: the edge of the room.
        var rail: Double
        /// Behind a photograph shown whole, in the letterboxed strips either
        /// side. Below the table so a pale photograph reads as an object on a
        /// surface — but only just. Deeper than that and it stops reading as a
        /// shade of the same material and starts reading as a hole in it.
        var mat: Double
        /// Behind the grid.
        var table: Double
        /// Behind the pinned day headers. A hair above the table: enough to
        /// separate one day from the next while scrolling, not enough to become
        /// a row of bright bars competing with the photographs.
        var header: Double
        static let dark = Levels(loupe: 0.08,
                                 rail: 0.14,
                                 mat: 0.16,
                                 table: 0.20,
                                 header: 0.255)

        /// The dark scheme with the lights up. Enough of a lift to feel like a
        /// different time of day, not enough to turn the surfaces white and put
        /// a photograph on a field brighter than itself.
        static let light = dark.lifted(by: 0.18)

        func lifted(by amount: Double) -> Levels {
            Levels(loupe: loupe + amount,
                   rail: rail + amount,
                   mat: mat + amount,
                   table: table + amount,
                   header: header + amount)
        }

        /// Every surface, darkest first, for rules that care about the order
        /// rather than any one value.
        var ordered: [Double] { [loupe, rail, mat, table, header] }
    }

    var levels: Levels

    static let dark = Surfaces(levels: .dark)
    static let light = Surfaces(levels: .light)

    var loupe: Color { Color(white: levels.loupe) }
    var rail: Color { Color(white: levels.rail) }
    var mat: Color { Color(white: levels.mat) }
    var table: Color { Color(white: levels.table) }
    var header: Color { Color(white: levels.header) }
}

private struct SurfacesKey: EnvironmentKey {
    /// Dark unless told otherwise: it is the scheme the app was drawn for, and
    /// a view that forgets to inherit one should not come out white.
    static let defaultValue = Surfaces.dark
}

extension EnvironmentValues {
    var surfaces: Surfaces {
        get { self[SurfacesKey.self] }
        set { self[SurfacesKey.self] = newValue }
    }
}

/// Resolves the palette from the appearance preference and hands it down.
///
/// Read from the preference rather than from `colorScheme`, because the chrome
/// deliberately forces the dark scheme on itself: asking the environment which
/// scheme it is in would answer "dark" inside the sidebar however bright the
/// rest of the window is.
struct SurfacePalette: ViewModifier {
    @AppStorage(PreferenceKeys.appearance) private var appearanceRaw = AppearancePreference.system.rawValue
    @Environment(\.colorScheme) private var systemScheme

    func body(content: Content) -> some View {
        let preference = AppearancePreference(rawValue: appearanceRaw) ?? .system
        let isDark = preference.colorScheme.map { $0 == .dark } ?? (systemScheme == .dark)
        return content.environment(\.surfaces, isDark ? .dark : .light)
    }
}
