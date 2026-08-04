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

        var errorDescription: String? {
            switch self {
            case .noOriginal: return "Could not read the original photo."
            case .creationFailed: return "Could not add the new photo to your library."
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
