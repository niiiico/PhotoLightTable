import Photos
import SwiftUI

/// How a thumbnail fills its cell.
enum ThumbnailFillMode: String, CaseIterable, Identifiable {
    /// Crop to a square. Tidy grid, but you lose the edges of the frame.
    case fill
    /// Show the whole frame letterboxed on black. Ragged, but you judge the
    /// actual composition — which matters when culling.
    case fit

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fill: return "Square crop"
        case .fit: return "Whole frame"
        }
    }

    var help: String {
        switch self {
        case .fill: return "Thumbnails are cropped to squares for an even grid."
        case .fit: return "Thumbnails show the full frame on black, so you see the real composition."
        }
    }

    var contentMode: PHImageContentMode {
        self == .fill ? .aspectFill : .aspectFit
    }

    var swiftUIContentMode: ContentMode {
        self == .fill ? .fill : .fit
    }
}

enum AppearancePreference: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// Nil hands the decision back to the system setting.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

enum PreferenceKeys {
    static let thumbnailFillMode = "thumbnailFillMode"
    static let loupeShowsFilmStrip = "loupeShowsFilmStrip"
    static let loupeFields = "loupeMetadataFields"
    static let appearance = "appearance"
}

/// Which EXIF fields the loupe shows, stored as a comma-separated list of raw
/// values so it fits in `@AppStorage` without a custom codable wrapper.
enum LoupeFields {
    static let defaultValue = encode(MetadataField.defaults)

    static func encode(_ fields: [MetadataField]) -> String {
        fields.map(\.rawValue).joined(separator: ",")
    }

    /// Preserves the stored order: the slots are arranged in the loupe itself,
    /// so their sequence is the user's, not `allCases`.
    static func decode(_ raw: String) -> [MetadataField] {
        raw.split(separator: ",").compactMap { MetadataField(rawValue: String($0)) }
    }
}
