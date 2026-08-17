import SwiftUI

/// The greys photographs are judged against.
///
/// Neutral and fixed, not tied to the light/dark setting. A surface with any
/// colour in it shifts the white balance of everything laid on it, and one that
/// changes with the appearance means the same photograph looks different on
/// Tuesday — which is the opposite of what a light table is for.
///
/// Two shades rather than one so the edge of a photograph is legible without a
/// border: the table sits behind the cells, and the mat sits behind a photograph
/// that does not fill its own cell.
enum Surfaces {
    /// Behind the grid.
    static let table = Color(white: 0.20)

    /// Behind a photograph shown whole, in the letterboxed strips either side.
    /// Darker than the table, so a pale photograph reads as an object on a
    /// surface rather than dissolving into it.
    static let mat = Color(white: 0.11)

    /// Behind the photograph in the loupe, where nothing else competes and the
    /// darkest of the three is right.
    static let loupe = Color(white: 0.08)
}
