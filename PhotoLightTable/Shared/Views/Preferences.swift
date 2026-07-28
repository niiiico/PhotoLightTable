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

enum PreferenceKey {
    static let thumbnailFillMode = "thumbnailFillMode"
    static let loupeFields = "loupeMetadataFields"
}

/// Which EXIF fields the loupe shows, stored as a comma-separated list of raw
/// values so it fits in `@AppStorage` without a custom codable wrapper.
enum LoupeFields {
    static let defaultValue = encode(MetadataField.defaults)

    static func encode(_ fields: [MetadataField]) -> String {
        fields.map(\.rawValue).joined(separator: ",")
    }

    static func decode(_ raw: String) -> [MetadataField] {
        let chosen = Set(raw.split(separator: ",").map(String.init))
        // Iterating allCases rather than the stored order keeps the info bar in
        // a stable, sensible sequence however the toggles were flipped.
        return MetadataField.allCases.filter { chosen.contains($0.rawValue) }
    }
}
