import Foundation
import Photos

/// What a photo was captured as, and roughly on what.
///
/// Read from `PHAssetResource`, which is local metadata Photos already holds —
/// no file is opened and no pixels are decoded, so this stays affordable to ask
/// about while scrolling a large library. EXIF would be more precise about the
/// camera, but it means reading from each file, and the answer is only ever a
/// badge on a thumbnail.
struct CaptureKind: Equatable {
    enum Format: Equatable {
        case raw
        case heif
        case jpeg
        case png
        case other

        /// Nothing is drawn for the ordinary case. A badge on every photo is a
        /// badge on none of them.
        var label: String? {
            switch self {
            case .raw: return "RAW"
            case .heif: return "HEIF"
            case .jpeg, .png, .other: return nil
            }
        }
    }

    /// Deliberately coarse. The question a photographer asks of a thumbnail is
    /// "did this come off the camera or the phone", not which body it was.
    enum Device: Equatable {
        case phone
        case camera

        var symbolName: String {
            switch self {
            case .phone: return "iphone"
            case .camera: return "camera"
            }
        }

        var label: String {
            switch self {
            case .phone: return "iPhone"
            case .camera: return "Camera"
            }
        }
    }

    var format: Format
    var device: Device?

    /// Raw extensions worth recognising: the ones a DSLR or mirrorless body
    /// actually writes. Not exhaustive, and does not need to be — an
    /// unrecognised raw simply gets no badge rather than a wrong one.
    private static let rawExtensions: Set<String> = [
        "dng", "cr2", "cr3", "nef", "nrw", "arw", "srf", "sr2",
        "raf", "orf", "rw2", "pef", "raw", "3fr", "fff", "iiq", "erf",
    ]

    /// Raw formats written by cameras rather than by phones. A DNG is the
    /// ambiguous one — Apple ProRAW writes DNG too — so it is not counted here
    /// and is left to the filename to decide.
    private static let cameraRawExtensions: Set<String> = [
        "cr2", "cr3", "nef", "nrw", "arw", "srf", "sr2",
        "raf", "orf", "rw2", "pef", "3fr", "fff", "iiq", "erf",
    ]

    static func of(_ asset: PHAsset) -> CaptureKind {
        let resources = PHAssetResource.assetResources(for: asset)

        // The primary image, falling back to whatever is there: a photo that
        // has been edited still reports its original alongside the render.
        let primary = resources.first { $0.type == .photo } ?? resources.first
        let filename = primary?.originalFilename ?? ""
        let ext = (filename as NSString).pathExtension.lowercased()

        // A raw sibling counts even when the primary is a JPEG: shooting
        // RAW+JPEG is shooting raw, whichever half Photos leads with.
        let alternate = resources.first { $0.type == .alternatePhoto }
        let alternateExt = ((alternate?.originalFilename ?? "") as NSString)
            .pathExtension.lowercased()

        let format: Format
        if rawExtensions.contains(ext) || rawExtensions.contains(alternateExt) {
            format = .raw
        } else {
            switch ext {
            case "heic", "heif": format = .heif
            case "jpg", "jpeg": format = .jpeg
            case "png": format = .png
            default: format = .other
            }
        }

        return CaptureKind(format: format,
                           device: device(extension: ext,
                                          alternateExtension: alternateExt,
                                          filename: filename))
    }

    private static func device(extension ext: String,
                               alternateExtension alternateExt: String,
                               filename: String) -> Device? {
        // A camera raw is conclusive: no phone writes a CR2.
        if cameraRawExtensions.contains(ext) || cameraRawExtensions.contains(alternateExt) {
            return .camera
        }
        // HEIF is Apple's capture format. Something else could write one, but
        // in a real library it did not.
        if ext == "heic" || ext == "heif" { return .phone }

        // Left over: DNG, which is ProRAW from a phone and Adobe's format from
        // everything else, and JPEG, which is everyone. The filename is the
        // only cheap signal, and it is a weak one — Canon also names files
        // IMG_ — so a DNG named that way is guessed as a phone and anything
        // else gets no badge rather than a wrong one.
        if ext == "dng" {
            return filename.uppercased().hasPrefix("IMG_") ? .phone : .camera
        }
        return nil
    }
}

/// Remembers what each photo was captured as.
///
/// Cheap to compute but not free, and the grid asks about the same photo every
/// time a neighbour is selected. Keyed by asset id, which is stable across the
/// pixels changing underneath it — the format of the original does not change
/// when an edit is applied.
@MainActor
enum CaptureKindCache {
    private static var cache: [String: CaptureKind] = [:]

    static func kind(for item: PhotoItem) -> CaptureKind {
        if let hit = cache[item.id] { return hit }
        let kind = CaptureKind.of(item.asset)
        cache[item.id] = kind
        return kind
    }
}
