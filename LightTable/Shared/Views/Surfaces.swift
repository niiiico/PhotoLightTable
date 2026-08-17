import SwiftUI

/// The greys photographs are judged against.
///
/// Neutral and fixed, not tied to the light/dark setting. A surface with any
/// colour in it shifts the white balance of everything laid on it, and one that
/// changes with the appearance means the same photograph looks different on
/// Tuesday — which is the opposite of what a light table is for.
///
/// Several shades rather than one so an edge is legible without a border: the
/// table sits behind the cells, the mat behind a photograph that does not fill
/// its own cell, and the chrome that touches the table — sidebar, day headers —
/// is cut from the same neutral rather than borrowing the system's chrome, which
/// arrives bright and coloured and drags the eye off the photographs.
enum Surfaces {
    /// Behind the grid.
    static let table = Color(white: 0.20)

    /// Behind a photograph shown whole, in the letterboxed strips either side.
    /// Darker than the table, so a pale photograph reads as an object on a
    /// surface rather than dissolving into it — but only just. Deep enough and
    /// it stops reading as a shade of the same material and starts reading as a
    /// hole in the table.
    static let mat = Color(white: 0.16)

    /// Behind the sidebar. Darker than the table so the list reads as the edge
    /// of the room and the table as the lit surface in it.
    static let rail = Color(white: 0.14)

    /// Behind the pinned day headers. A hair off the table: enough to separate
    /// one day from the next while scrolling, not enough to become a row of
    /// bright bars competing with the photographs.
    static let header = Color(white: 0.255)

    /// Behind the photograph in the loupe, where nothing else competes and the
    /// darkest of the three is right.
    static let loupe = Color(white: 0.08)
}
