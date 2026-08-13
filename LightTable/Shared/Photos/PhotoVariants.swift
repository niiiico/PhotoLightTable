import Foundation
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
        // Every part the photo is made of, not just its main image. Copying
        // only `.photo` turned a duplicated Live Photo into a still and would
        // drop the RAW half of a RAW+JPEG pair — the resource header warns
        // that full fidelity means preserving every resource.
        let sources = try await copiedResources(of: item.asset)
        defer { for file in sources { try? FileManager.default.removeItem(at: file.url) } }
        guard sources.contains(where: { $0.type == .photo }) else {
            throw VariantError.noOriginal
        }

        var placeholder: PHObjectPlaceholder?
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            for source in sources {
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = source.originalFilename
                // These are our own temporary copies, so letting PhotoKit take
                // them saves writing every byte a second time.
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

    /// The resources worth carrying into a copy.
    ///
    /// `.photo` is the untouched original — not `.fullSizePhoto`, which is the
    /// render of whatever edit the source currently has, and not
    /// `.adjustmentData`, since a variant starts from the original and gets its
    /// own recipe. `.alternatePhoto` is the RAW beside a JPEG, and
    /// `.pairedVideo` is what makes a Live Photo live.
    private static func isWorthCopying(_ type: PHAssetResourceType) -> Bool {
        switch type {
        case .photo, .alternatePhoto, .pairedVideo, .video, .audio: return true
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
