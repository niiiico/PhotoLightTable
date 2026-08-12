import SwiftUI

/// The pick/reject axis. Exclusive: a photo is exactly one of these.
enum Pick: Int, Codable, CaseIterable, Identifiable {
    case unrated = 0
    case picked = 1
    case rejected = -1

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .unrated: return "Unrated"
        case .picked: return "Picked"
        case .rejected: return "Rejected"
        }
    }

    /// Badge glyph, drawn on a filled circle over a thumbnail.
    var symbolName: String {
        switch self {
        case .unrated: return "circle.dashed"
        case .picked: return "flag.fill"
        case .rejected: return "xmark.circle.fill"
        }
    }

    /// Glyph for the toolbar chips. These sit side by side, so they need
    /// matching visual weight — `xmark.circle.fill` carries its own circle and
    /// reads far heavier than a flag, and `circle.dashed` turns to mush at small
    /// sizes.
    var chipSymbolName: String {
        switch self {
        case .unrated: return "circle"
        case .picked: return "flag.fill"
        case .rejected: return "xmark"
        }
    }

    var tint: Color {
        switch self {
        case .unrated: return .secondary
        case .picked: return .green
        case .rejected: return .red
        }
    }
}

/// The colour-label axis, independent of pick/reject. Mirrors the
/// five labels photographers are used to from other culling tools.
enum ColorLabel: Int, Codable, CaseIterable, Identifiable {
    case red = 1
    case yellow = 2
    case green = 3
    case blue = 4
    case purple = 5

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .red: return "Red"
        case .yellow: return "Yellow"
        case .green: return "Green"
        case .blue: return "Blue"
        case .purple: return "Purple"
        }
    }

    var color: Color {
        switch self {
        case .red: return .red
        case .yellow: return .yellow
        case .green: return .green
        case .blue: return .blue
        case .purple: return .purple
        }
    }

    /// Number key that applies this label.
    var shortcutKey: Character {
        switch self {
        case .red: return "6"
        case .yellow: return "7"
        case .green: return "8"
        case .blue: return "9"
        case .purple: return "0"
        }
    }

    static func forShortcutKey(_ key: Character) -> ColorLabel? {
        allCases.first { $0.shortcutKey == key }
    }
}

/// Plain value type used everywhere in the UI. The SwiftData row is an
/// implementation detail of `RatingStore`.
struct RatingValue: Equatable {
    var pick: Pick = .unrated
    var color: ColorLabel?

    var isEmpty: Bool { pick == .unrated && color == nil }

    static let empty = RatingValue()
}
