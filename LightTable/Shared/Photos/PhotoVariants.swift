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
        // Claiming our adjustment data means this is the untouched original,
        // not the current render — so the variant starts from the same place
        // the photo itself does.
        guard let input = await PhotoEditSession.loadInput(for: item.asset),
              let sourceURL = input.fullSizeImageURL else {
            throw VariantError.noOriginal
        }

        var placeholder: PHObjectPlaceholder?
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            // The URL belongs to PhotoKit's editing session; moving it would
            // take it out from under the asset being copied.
            options.shouldMoveFile = false
            request.addResource(with: .photo, fileURL: sourceURL, options: options)

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
