import Foundation
import Photos
import SwiftData
import SwiftUI

/// Carries an edit from one photo to others.
///
/// The copied recipe is read from the photo's actual adjustment data rather than
/// from this app's history, so it reflects what the photo currently carries even
/// if it was reverted or re-edited elsewhere.
@MainActor
final class EditClipboard: ObservableObject {
    @Published private(set) var recipe: PhotoEditRecipe?
    @Published private(set) var sourceName: String?

    @Published private(set) var applied = 0
    @Published private(set) var total = 0
    @Published private(set) var isApplying = false
    @Published var errorMessage: String?

    /// Set so pasted photos refresh in the grid, and so each pasted recipe is
    /// recorded in that photo's own history.
    weak var library: PhotoLibraryService?
    var modelContext: ModelContext?

    var hasContents: Bool { recipe != nil }

    var progressDescription: String? {
        guard isApplying else { return nil }
        return "Pasting \(applied) of \(total)"
    }

    // MARK: - Copy

    func copy(from item: PhotoItem) async {
        errorMessage = nil
        guard let copied = await PhotoEditSession.recipe(of: item.asset) else {
            recipe = nil
            sourceName = nil
            errorMessage = "That photo has no adjustments made in this app."
            return
        }
        recipe = copied
        sourceName = item.creationDate?.formatted(date: .abbreviated, time: .shortened)
    }

    func clear() {
        recipe = nil
        sourceName = nil
        errorMessage = nil
    }

    // MARK: - Paste

    /// Applies the clipboard to each photo in turn.
    ///
    /// Sequential rather than concurrent: each one is a full-resolution decode,
    /// render and encode, and running a selection of them in parallel would
    /// compete for memory and leave the machine unusable rather than finish
    /// sooner.
    func paste(to items: [PhotoItem], includingCrop: Bool) async {
        guard var recipe, !items.isEmpty else { return }
        if !includingCrop { recipe.crop = .full }

        errorMessage = nil
        isApplying = true
        applied = 0
        total = items.count
        defer { isApplying = false }

        var failures = 0
        for item in items {
            do {
                try await PhotoEditSession.apply(recipe, to: item.asset)
                library?.refreshAsset(withID: item.id)
                record(recipe, for: item)
            } catch {
                failures += 1
                editLog("paste: failed for \(item.id) — \(error)")
            }
            applied += 1
        }

        if failures > 0 {
            // Photos rejects some assets outright — shared or synced ones can't
            // be edited — so a partial result is expected rather than a bug.
            errorMessage = failures == items.count
                ? "None of the photos could be adjusted."
                : "\(failures) of \(items.count) photos could not be adjusted."
        }
    }

    private func record(_ recipe: PhotoEditRecipe, for item: PhotoItem) {
        guard let modelContext, let data = try? JSONEncoder().encode(recipe) else { return }
        modelContext.insert(PhotoEditVersion(assetID: item.id, recipeData: data))
        try? modelContext.save()
    }
}
