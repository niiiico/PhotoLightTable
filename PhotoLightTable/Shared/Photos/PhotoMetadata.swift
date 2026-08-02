import Foundation
import ImageIO
import Photos

/// EXIF/TIFF values read from a photo's original file.
struct PhotoMetadata {
    var make: String?
    var model: String?
    var lens: String?
    var iso: Int?
    var aperture: Double?
    /// Exposure time in seconds.
    var shutter: Double?
    var focalLength: Double?
    var focalLength35mm: Int?
    var exposureBias: Double?
    var originalFilename: String?
    var fileSize: Int64?

    static let empty = PhotoMetadata()
}

/// A single line item in the loupe's info bar.
///
/// Values are formatted the way they're printed on a lens barrel rather than
/// labelled — "ƒ/2.8" needs no caption, and a row of captions would crowd out
/// the photo.
enum MetadataField: String, CaseIterable, Identifiable, Codable {
    case dateTime
    case camera
    case lens
    case focalLength
    case aperture
    case shutter
    case iso
    case exposureBias
    case dimensions
    case megapixels
    case filename
    case fileSize

    var id: String { rawValue }

    var label: String {
        switch self {
        case .dateTime: return "Date and time"
        case .camera: return "Camera"
        case .lens: return "Lens"
        case .focalLength: return "Focal length"
        case .aperture: return "Aperture"
        case .shutter: return "Shutter speed"
        case .iso: return "ISO"
        case .exposureBias: return "Exposure compensation"
        case .dimensions: return "Pixel dimensions"
        case .megapixels: return "Megapixels"
        case .filename: return "File name"
        case .fileSize: return "File size"
        }
    }

    /// What the loupe prints. Nil means the photo carries no such value, and the
    /// field is skipped rather than shown empty.
    func display(item: PhotoItem, metadata: PhotoMetadata) -> String? {
        switch self {
        case .dateTime:
            return item.creationDate?.formatted(date: .abbreviated, time: .shortened)

        case .camera:
            // "SONY" + "ILCE-7M4" reads as one name; some files repeat the make
            // inside the model, in which case the model alone is enough.
            let make = metadata.make?.trimmingCharacters(in: .whitespaces)
            let model = metadata.model?.trimmingCharacters(in: .whitespaces)
            switch (make, model) {
            case let (make?, model?):
                return model.localizedCaseInsensitiveContains(make) ? model : "\(make) \(model)"
            case let (nil, model?): return model
            case let (make?, nil): return make
            default: return nil
            }

        case .lens:
            return metadata.lens

        case .focalLength:
            guard let focal = metadata.focalLength else { return nil }
            let base = "\(Self.trim(focal)) mm"
            guard let equivalent = metadata.focalLength35mm,
                  abs(Double(equivalent) - focal) > 0.5 else { return base }
            return "\(base) (\(equivalent) mm eq.)"

        case .aperture:
            guard let aperture = metadata.aperture else { return nil }
            return "ƒ/\(Self.trim(aperture))"

        case .shutter:
            guard let shutter = metadata.shutter, shutter > 0 else { return nil }
            if shutter >= 1 { return "\(Self.trim(shutter)) s" }
            return "1/\(Int((1 / shutter).rounded())) s"

        case .iso:
            guard let iso = metadata.iso else { return nil }
            return "ISO \(iso)"

        case .exposureBias:
            guard let bias = metadata.exposureBias, abs(bias) > 0.01 else { return nil }
            return "\(bias > 0 ? "+" : "")\(Self.trim(bias)) EV"

        case .dimensions:
            guard item.pixelWidth > 0 else { return nil }
            return "\(item.pixelWidth) × \(item.pixelHeight)"

        case .megapixels:
            guard item.pixelWidth > 0 else { return nil }
            let mp = Double(item.pixelWidth * item.pixelHeight) / 1_000_000
            return String(format: "%.1f MP", mp)

        case .filename:
            return metadata.originalFilename

        case .fileSize:
            guard let bytes = metadata.fileSize, bytes > 0 else { return nil }
            return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }
    }

    /// Drops a trailing ".0" so focal lengths read "35 mm", not "35.0 mm".
    private static func trim(_ value: Double) -> String {
        value == value.rounded()
            ? String(Int(value))
            : String(format: "%.1f", value)
    }

    static let defaults: [MetadataField] = [
        .dateTime, .camera, .lens, .focalLength, .aperture, .shutter, .iso
    ]
}

/// Reads metadata straight from the original file.
///
/// `CGImageSource` parses headers lazily, so this never decodes pixels — the
/// cost is the file being made available, not the image being read.
@MainActor
final class MetadataLoader: ObservableObject {
    static let shared = MetadataLoader()

    private var cache: [String: PhotoMetadata] = [:]
    private init() {}

    func cached(for item: PhotoItem) -> PhotoMetadata? {
        cache[item.id]
    }

    func metadata(for item: PhotoItem) async -> PhotoMetadata {
        if let hit = cache[item.id] { return hit }

        var result = await Self.read(asset: item.asset)

        if let resource = PHAssetResource.assetResources(for: item.asset)
            .first(where: { $0.type == .photo }) ?? PHAssetResource.assetResources(for: item.asset).first {
            result.originalFilename = resource.originalFilename
            // Not part of the public API surface but the standard way to get a
            // size without fetching the data; absent on some assets.
            result.fileSize = (resource.value(forKey: "fileSize") as? NSNumber)?.int64Value
        }

        cache[item.id] = result
        return result
    }

    private static func read(asset: PHAsset) async -> PhotoMetadata {
        let options = PHContentEditingInputRequestOptions()
        options.isNetworkAccessAllowed = true

        let url: URL? = await withCheckedContinuation { continuation in
            // Off the main queue: this faults PHAssetAdjustmentProperties on the
            // calling thread, and the loupe asks for metadata on every photo it
            // shows — so on the main queue it would fault once per frame viewed.
            DispatchQueue.global(qos: .userInitiated).async {
                asset.requestContentEditingInput(with: options) { input, _ in
                    continuation.resume(returning: input?.fullSizeImageURL)
                }
            }
        }
        guard let url else { return .empty }

        return await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                    as? [CFString: Any] else { return PhotoMetadata.empty }

            let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
            let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]

            var metadata = PhotoMetadata()
            metadata.make = tiff[kCGImagePropertyTIFFMake] as? String
            metadata.model = tiff[kCGImagePropertyTIFFModel] as? String
            metadata.lens = exif[kCGImagePropertyExifLensModel] as? String
            metadata.iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first
            metadata.aperture = exif[kCGImagePropertyExifFNumber] as? Double
            metadata.shutter = exif[kCGImagePropertyExifExposureTime] as? Double
            metadata.focalLength = exif[kCGImagePropertyExifFocalLength] as? Double
            metadata.focalLength35mm = exif[kCGImagePropertyExifFocalLenIn35mmFilm] as? Int
            metadata.exposureBias = exif[kCGImagePropertyExifExposureBiasValue] as? Double
            return metadata
        }.value
    }
}
