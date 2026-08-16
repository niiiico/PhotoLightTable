import Foundation
import ImageIO
import Photos
import SwiftData

/// Saves an alternative treatment of a photo as a photo of its own.
///
/// The duplicate is built from the *original* pixels and then has the recipe
/// applied as an ordinary edit, rather than being written out as a flattened
/// render. That costs one extra step and buys a great deal: the variant is
/// non-destructive like any other edit, can be reverted to the original in
/// Photos, and reopens here with its adjustments intact.
@MainActor
enum PhotoVariants {
    enum VariantError: LocalizedError {
        case noOriginal
        case creationFailed
        case notAVariant

        var errorDescription: String? {
            switch self {
            case .noOriginal: return "Could not read the original photo."
            case .creationFailed: return "Could not add the new photo to your library."
            case .notAVariant:
                return "That is an original photo, not a version made here — it can only be removed in Photos."
            }
        }
    }

    /// Returns the new asset's identifier.
    @discardableResult
    static func create(from item: PhotoItem,
                       applying recipe: PhotoEditRecipe,
                       label: String,
                       context: ModelContext?,
                       library: PhotoLibraryService?) async throws -> String {
        // The main image has to be the one the recipe was written against, and
        // that is what PhotoKit hands the editor: `fullSizeImageURL`.
        //
        // Taking the `.photo` resource instead looks equivalent and is not. For
        // a photo already edited in Photos.app, PhotoKit gives the editor the
        // *rendered* image — cropped, rotated, whatever was done to it — while
        // the resource is still the untouched original underneath. A mask
        // placed on a photo cropped to 9:16 was then stretched over the 3:4
        // original, landing beside its subject rather than on it.
        //
        // Companions still come from the resources, which is what makes a
        // duplicated Live Photo stay live.
        guard let input = await PhotoEditSession.loadInput(for: item.asset),
              let baseURL = input.fullSizeImageURL else {
            throw VariantError.noOriginal
        }
        // Companions can only come along when the base image is the original
        // they belong to. When the source carries somebody else's edit the base
        // is a render of it, and pairing that with the untouched RAW sibling or
        // Live Photo video describes a photo that does not exist — PhotoKit
        // refuses the whole thing with PHPhotosErrorInvalidResource.
        //
        // The still wins in that case. A duplicate that is not live is a
        // disappointment; a duplicate that will not save at all is a bug.
        let companions = baseIsTheOriginal(baseURL, of: item.asset)
            ? try await copiedResources(of: item.asset)
            : []
        defer { for file in companions { try? FileManager.default.removeItem(at: file.url) } }

        var placeholder: PHObjectPlaceholder?
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()

            let primary = PHAssetResourceCreationOptions()
            // The URL belongs to PhotoKit's editing session; moving it would
            // take it out from under the asset being copied.
            primary.shouldMoveFile = false
            request.addResource(with: .photo, fileURL: baseURL, options: primary)

            for source in companions {
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = source.originalFilename
                options.shouldMoveFile = true
                request.addResource(with: source.type, fileURL: source.url, options: options)
            }

            // Carried over so the variant sorts next to its original rather
            // than to the moment it was made, which is what "alongside" means
            // in a library ordered by date.
            request.creationDate = item.creationDate
            request.location = item.location
            placeholder = request.placeholderForCreatedAsset
        }

        guard let newID = placeholder?.localIdentifier,
              let created = PHAsset.fetchAssets(withLocalIdentifiers: [newID], options: nil).firstObject
        else { throw VariantError.creationFailed }

        if !recipe.isNeutral {
            try await PhotoEditSession.apply(recipe, to: created)
        }

        record(newID, from: item.id, label: label, context: context)
        library?.refreshAsset(withID: newID)
        return newID
    }

    /// Splits a photo into two, side by side, as separate photos.
    ///
    /// Built on the same path as any other variant, so each half is a real
    /// photo from the original pixels with a crop applied non-destructively —
    /// the halves can be re-cropped, adjusted or reverted afterwards, which a
    /// pair of flattened exports could not.
    ///
    /// The original is left untouched. Two scanned pages on one frame become
    /// two pages without losing the sheet they came from.
    @discardableResult
    static func splitLeftRight(_ item: PhotoItem,
                               applying recipe: PhotoEditRecipe,
                               context: ModelContext?,
                               library: PhotoLibraryService?) async throws -> [String] {
        var created: [String] = []
        for half in Half.allCases {
            var halved = recipe
            halved.crop = half.crop(within: recipe.crop)
            created.append(try await create(from: item,
                                            applying: halved,
                                            label: half.label,
                                            context: context,
                                            library: library))
        }
        return created
    }

    enum Half: CaseIterable {
        case left, right

        var label: String { self == .left ? "Left" : "Right" }

        /// Halves whatever is currently framed rather than the whole file, so
        /// splitting after a crop divides what is actually visible.
        func crop(within crop: CropRect) -> CropRect {
            let width = crop.width / 2
            return CropRect(x: self == .left ? crop.x : crop.x + width,
                            y: crop.y,
                            width: width,
                            height: crop.height)
        }
    }

    /// Removes a variant from the library.
    ///
    /// The single place in this app that deletes anything, and deliberately
    /// narrow. [ADR 001](../../../docs/adr-001-ratings-outside-photos.md) says
    /// nothing is ever deleted, which was about *photographs* — a variant is a
    /// copy this app made, and the photo it came from stays. Removing one
    /// destroys no picture that was taken.
    ///
    /// PhotoKit's `deleteAssets` moves an asset to Recently Deleted rather than
    /// erasing it, so this is recoverable in Photos for thirty days, and macOS
    /// puts its own confirmation in front of it besides ours.
    @MainActor
    static func remove(_ item: PhotoItem,
                       context: ModelContext?,
                       ratings: RatingStore?) async throws {
        guard ratings?.isVariant(item.id) ?? false else {
            throw VariantError.notAVariant
        }

        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets([item.asset] as NSArray)
        }

        // Only once the asset is actually gone: if the deletion is refused or
        // cancelled, the record has to survive or the photo becomes a variant
        // the app no longer knows anything about.
        ratings?.forgetVariant(item.id)

        if let context, let events = try? context.fetch(FetchDescriptor<LightTableEvent>()) {
            for event in events {
                event.pinnedAssetIDs.removeAll { $0 == item.id }
                event.excludedAssetIDs.removeAll { $0 == item.id }
            }
            try? context.save()
        }
    }

    // MARK: - Copying the parts of a photo

    struct CopiedResource {
        let type: PHAssetResourceType
        let url: URL
        let originalFilename: String
    }

    /// Whether the editor's base image is the source's original file rather
    /// than a render of it.
    ///
    /// Compared by pixel dimensions, which is a fact about both, rather than
    /// inferred from whether the asset has adjustments — an edit that only
    /// changed exposure leaves the dimensions alone and its companions would
    /// still match.
    private static func baseIsTheOriginal(_ baseURL: URL, of asset: PHAsset) -> Bool {
        guard let primary = PHAssetResource.assetResources(for: asset)
            .first(where: { $0.type == .photo }) else { return false }
        guard let source = CGImageSourceCreateWithURL(baseURL as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any] else { return false }

        let width = properties[kCGImagePropertyPixelWidth] as? Int
        let height = properties[kCGImagePropertyPixelHeight] as? Int
        return width == primary.pixelWidth && height == primary.pixelHeight
    }

    /// The resources worth carrying into a copy, beside the main image.
    ///
    /// `.alternatePhoto` is the RAW beside a JPEG and `.pairedVideo` is what
    /// makes a Live Photo live. `.photo` is deliberately not among them: the
    /// main image comes from the editing input instead, so that it is the same
    /// picture the recipe was written against. `.fullSizePhoto` and
    /// `.adjustmentData` are the source's own edit, which a variant does not
    /// inherit — it gets its own recipe.
    private static func isWorthCopying(_ type: PHAssetResourceType) -> Bool {
        switch type {
        case .alternatePhoto, .pairedVideo, .video, .audio: return true
        default: return false
        }
    }

    /// Writes each resource out to a temporary file.
    ///
    /// There is no way to hand PhotoKit one asset's resources directly, so a
    /// copy has to go through the file system. Network access is allowed
    /// because the original may only exist in iCloud, and failing on a photo
    /// that is merely not downloaded yet would be arbitrary.
    private static func copiedResources(of asset: PHAsset) async throws -> [CopiedResource] {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LightTableVariant-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var copied: [CopiedResource] = []
        for resource in PHAssetResource.assetResources(for: asset) where isWorthCopying(resource.type) {
            let destination = directory.appendingPathComponent(resource.originalFilename)
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true

            do {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    PHAssetResourceManager.default().writeData(for: resource,
                                                               toFile: destination,
                                                               options: options) { error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume()
                        }
                    }
                }
            } catch {
                // One missing companion should not cost the whole duplicate:
                // better a still copy of a Live Photo than no copy at all. The
                // primary image is checked for by the caller.
                continue
            }

            copied.append(CopiedResource(type: resource.type,
                                         url: destination,
                                         originalFilename: resource.originalFilename))
        }
        return copied
    }

    private static func record(_ assetID: String,
                               from originalID: String,
                               label: String,
                               context: ModelContext?) {
        guard let context else { return }
        context.insert(PhotoVariant(assetID: assetID, originalAssetID: originalID, label: label))

        // Pinned into whatever the original belongs to, so a variant turns up
        // beside it rather than only in the library at large.
        if let events = try? context.fetch(FetchDescriptor<LightTableEvent>()) {
            for event in events where event.pinnedAssetIDs.contains(originalID)
                || (!event.isExplicit && !event.excludedAssetIDs.contains(originalID)) {
                guard !event.pinnedAssetIDs.contains(assetID) else { continue }
                event.pinnedAssetIDs.append(assetID)
            }
        }
        try? context.save()
    }
}
