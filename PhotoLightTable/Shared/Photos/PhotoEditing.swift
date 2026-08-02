import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Photos
import SwiftData

/// The description of an edit — small, versioned, and the only thing that needs
/// to survive a round trip through Photos.
///
/// Deliberately a value type with no image data: it is encoded into
/// `PHAdjustmentData` so the edit can be reopened later as adjustable
/// parameters rather than as a flattened result. Phase one carries a single
/// exposure value; masks and further adjustments extend this struct.
struct PhotoEditRecipe: Codable, Equatable {
    /// Exposure in stops.
    var exposure: Double = 0

    static let neutral = PhotoEditRecipe()
    var isNeutral: Bool { self == .neutral }

    var summary: String {
        isNeutral ? "No adjustments" : String(format: "%+.2f EV", exposure)
    }

    func apply(to image: CIImage) -> CIImage {
        guard !isNeutral else { return image }
        let filter = CIFilter.exposureAdjust()
        filter.inputImage = image
        filter.ev = Float(exposure)
        return filter.outputImage ?? image
    }
}

enum PhotoEditError: LocalizedError {
    case notEditable
    case couldNotOpen
    case couldNotRender

    var errorDescription: String? {
        switch self {
        case .notEditable: return "This photo can't be edited."
        case .couldNotOpen: return "Could not open the photo for editing."
        case .couldNotRender: return "Could not render the edited photo."
        }
    }
}

/// One photo's editing session: loads it, previews changes, commits them back.
@MainActor
final class PhotoEditSession: ObservableObject {
    /// Identifies our adjustments to Photos. Only a build that understands this
    /// pair is handed back the original image plus the recipe; anything else
    /// sees the rendered result.
    static let formatIdentifier = "com.photolighttable.edit"
    static let formatVersion = "1"

    @Published var recipe = PhotoEditRecipe()
    @Published private(set) var preview: PlatformImage?
    @Published private(set) var isLoading = false
    @Published private(set) var isCommitting = false
    @Published private(set) var canEdit = false
    /// Whether this photo already carries an edit — ours or another app's.
    @Published private(set) var hasExistingEdit = false
    @Published private(set) var errorMessage: String?

    /// Set by the view from the environment; history is persisted alongside
    /// ratings and events.
    var modelContext: ModelContext?
    @Published private(set) var history: [PhotoEditVersion] = []

    private var input: PHContentEditingInput?
    private var previewBase: CIImage?
    private let context = CIContext()

    var isDirty: Bool { recipe != loadedRecipe }
    private var loadedRecipe = PhotoEditRecipe.neutral

    // MARK: - Opening

    func begin(for item: PhotoItem) async {
        reset()
        isLoading = true
        defer { isLoading = false }

        canEdit = item.asset.canPerform(.content)
        guard canEdit else { return }

        let options = PHContentEditingInputRequestOptions()
        options.isNetworkAccessAllowed = true
        // Claiming our own adjustment data is what makes re-editing
        // non-destructive: PhotoKit then hands back the *original* image along
        // with the previous recipe, instead of an image with the last edit
        // already baked in. Returning false here would compound edits.
        options.canHandleAdjustmentData = { data in
            data.formatIdentifier == Self.formatIdentifier
                && data.formatVersion == Self.formatVersion
        }

        let loaded: PHContentEditingInput? = await withCheckedContinuation { continuation in
            item.asset.requestContentEditingInput(with: options) { input, _ in
                continuation.resume(returning: input)
            }
        }
        guard let loaded else {
            errorMessage = PhotoEditError.couldNotOpen.localizedDescription
            return
        }

        input = loaded
        hasExistingEdit = loaded.adjustmentData != nil
        loadedRecipe = Self.decode(loaded.adjustmentData) ?? .neutral
        recipe = loadedRecipe

        if let display = loaded.displaySizeImage {
            previewBase = CIImage.from(display)
        }
        renderPreview()
        loadHistory(for: item)
    }

    func cancel() { reset() }

    private func reset() {
        input = nil
        previewBase = nil
        preview = nil
        recipe = .neutral
        loadedRecipe = .neutral
        hasExistingEdit = false
        errorMessage = nil
    }

    // MARK: - Preview

    /// Renders at display size, which is what `PHContentEditingInput` provides
    /// for exactly this purpose — the full-size render is deferred to commit.
    func renderPreview() {
        guard let previewBase else { return }
        let edited = recipe.apply(to: previewBase)
        guard let cgImage = context.createCGImage(edited, from: edited.extent) else { return }
        preview = PlatformImage.from(cgImage)
    }

    // MARK: - Committing

    func commit(for item: PhotoItem) async throws {
        guard let input else { throw PhotoEditError.couldNotOpen }
        guard let sourceURL = input.fullSizeImageURL else { throw PhotoEditError.couldNotOpen }

        isCommitting = true
        defer { isCommitting = false }

        let output = PHContentEditingOutput(contentEditingInput: input)
        output.adjustmentData = PHAdjustmentData(
            formatIdentifier: Self.formatIdentifier,
            formatVersion: Self.formatVersion,
            data: try JSONEncoder().encode(recipe))

        let recipe = self.recipe
        let orientation = input.fullSizeImageOrientation
        let destination = output.renderedContentURL

        // Full resolution off the main actor: this is a real decode and encode,
        // and on a 50MP file it is not a frame's worth of work.
        try await Task.detached(priority: .userInitiated) {
            guard let base = CIImage(contentsOf: sourceURL) else {
                throw PhotoEditError.couldNotRender
            }
            let edited = recipe.apply(to: base.oriented(forExifOrientation: orientation))
            let context = CIContext()
            try context.writeJPEGRepresentation(
                of: edited,
                to: destination,
                colorSpace: edited.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.95])
        }.value

        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest(for: item.asset).contentEditingOutput = output
        }

        loadedRecipe = recipe
        hasExistingEdit = true
        record(recipe, for: item)
    }

    /// Photos keeps the original, so this is a true revert rather than an
    /// inverse edit. Requires the original to be on the device.
    func revert(for item: PhotoItem) async throws {
        isCommitting = true
        defer { isCommitting = false }

        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest(for: item.asset).revertAssetContentToOriginal()
        }
        recipe = .neutral
        loadedRecipe = .neutral
        hasExistingEdit = false
        renderPreview()
        record(.neutral, for: item)
    }

    // MARK: - History

    private func loadHistory(for item: PhotoItem) {
        guard let modelContext else { history = []; return }
        let assetID = item.id
        var descriptor = FetchDescriptor<PhotoEditVersion>(
            predicate: #Predicate { $0.assetID == assetID },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        descriptor.fetchLimit = 50
        history = (try? modelContext.fetch(descriptor)) ?? []
    }

    private func record(_ recipe: PhotoEditRecipe, for item: PhotoItem) {
        guard let modelContext, let data = try? JSONEncoder().encode(recipe) else { return }
        // Re-applying the same recipe isn't a new state to return to.
        if let latest = history.first, latest.recipe == recipe { return }

        modelContext.insert(PhotoEditVersion(assetID: item.id, recipeData: data))
        try? modelContext.save()
        loadHistory(for: item)
    }

    /// Puts a previous recipe back and commits it, so restoring is itself an
    /// edit — it lands in the history like any other and can be stepped back
    /// out of.
    func restore(_ version: PhotoEditVersion, for item: PhotoItem) async throws {
        guard let recipe = version.recipe else { return }
        self.recipe = recipe
        renderPreview()
        try await commit(for: item)
    }

    func clearHistory(for item: PhotoItem) {
        guard let modelContext else { return }
        for version in history { modelContext.delete(version) }
        try? modelContext.save()
        history = []
    }

    // MARK: - Adjustment data

    private static func decode(_ data: PHAdjustmentData?) -> PhotoEditRecipe? {
        guard let data,
              data.formatIdentifier == formatIdentifier,
              data.formatVersion == formatVersion else { return nil }
        return try? JSONDecoder().decode(PhotoEditRecipe.self, from: data.data)
    }
}
