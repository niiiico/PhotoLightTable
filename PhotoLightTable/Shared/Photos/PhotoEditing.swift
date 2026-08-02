import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
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
/// A crop in normalized coordinates with a top-left origin, matching how the
/// UI thinks about it.
///
/// Normalized because the same recipe has to render identically against a
/// display-size preview and a full-resolution commit — a rect in pixels would
/// mean one of the two is wrong. Core Image's origin is bottom-left, so the
/// flip happens once, at the point of application.
struct CropRect: Codable, Equatable {
    var x: Double = 0
    var y: Double = 0
    var width: Double = 1
    var height: Double = 1

    static let full = CropRect()
    var isFull: Bool { self == .full }

    /// Clamped to the image and never smaller than a usable sliver.
    func normalized() -> CropRect {
        var result = self
        result.width = min(max(result.width, 0.02), 1)
        result.height = min(max(result.height, 0.02), 1)
        result.x = min(max(result.x, 0), 1 - result.width)
        result.y = min(max(result.y, 0), 1 - result.height)
        return result
    }
}

struct PhotoEditRecipe: Codable, Equatable {
    /// Exposure in stops.
    var exposure: Double = 0
    var crop: CropRect = .full

    static let neutral = PhotoEditRecipe()
    var isNeutral: Bool { self == .neutral }

    var summary: String {
        var parts: [String] = []
        if exposure != 0 { parts.append(String(format: "%+.2f EV", exposure)) }
        if !crop.isFull { parts.append("Cropped") }
        return parts.isEmpty ? "No adjustments" : parts.joined(separator: " · ")
    }

    /// Tone first, geometry last: cropping is a change of frame, and applying it
    /// before the adjustments would leave every later mask defined against a
    /// different extent depending on whether a crop happened to be set.
    func apply(to image: CIImage, applyCrop: Bool = true) -> CIImage {
        var result = image

        if exposure != 0 {
            let filter = CIFilter.exposureAdjust()
            filter.inputImage = result
            filter.ev = Float(exposure)
            result = filter.outputImage ?? result
        }

        if applyCrop, !crop.isFull {
            result = Self.cropped(result, to: crop)
        }
        return result
    }

    private static func cropped(_ image: CIImage, to crop: CropRect) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }

        // Top-left origin to Core Image's bottom-left.
        let rect = CGRect(x: extent.minX + crop.x * extent.width,
                          y: extent.minY + (1 - crop.y - crop.height) * extent.height,
                          width: crop.width * extent.width,
                          height: crop.height * extent.height)

        // Translating back to the origin matters: a cropped CIImage keeps the
        // original extent's offset, and writing one produces a canvas the size
        // of the uncropped image with the crop floating inside it.
        return image.cropped(to: rect)
            .transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
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

#if DEBUG
/// Appends to ~/Library/Containers/<app>/Data/edit.log.
func editLog(_ message: String) {
    let path = NSHomeDirectory() + "/edit.log"
    let line = "\(Date().formatted(date: .numeric, time: .standard))  \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    if !FileManager.default.fileExists(atPath: path) {
        FileManager.default.createFile(atPath: path, contents: nil)
    }
    guard let handle = FileHandle(forWritingAtPath: path) else { return }
    defer { try? handle.close() }
    _ = try? handle.seekToEnd()
    try? handle.write(contentsOf: data)
}
#else
func editLog(_ message: String) {}
#endif

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
        editLog("begin: canEdit=\(canEdit) hasAdjustments=\(loaded.adjustmentData != nil) fullSizeURL=\(loaded.fullSizeImageURL != nil)")
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
    func renderPreview(applyCrop: Bool = true) {
        guard let previewBase else { return }
        let edited = recipe.apply(to: previewBase, applyCrop: applyCrop)
        guard let cgImage = context.createCGImage(edited, from: edited.extent) else { return }
        preview = PlatformImage.from(cgImage)
    }

    // MARK: - Committing

    func commit(for item: PhotoItem) async throws {
        guard let input else { throw PhotoEditError.couldNotOpen }
        guard let sourceURL = input.fullSizeImageURL else { throw PhotoEditError.couldNotOpen }

        isCommitting = true
        defer { isCommitting = false }
        editLog("commit: begin ev=\(recipe.exposure) orientation=\(input.fullSizeImageOrientation) source=\(sourceURL.lastPathComponent)")

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
            let oriented = base.oriented(forExifOrientation: orientation)

            // Orienting bakes the rotation into the pixels, but the metadata
            // carried over from the source still declares the original
            // orientation — so the file says "rotate me" over pixels that are
            // already rotated. Photos validates the render and rejects anything
            // not in up orientation with PHPhotosErrorInvalidResource (3302).
            var properties = oriented.properties
            properties[kCGImagePropertyOrientation as String] = CGImagePropertyOrientation.up.rawValue
            let edited = recipe.apply(to: oriented.settingProperties(properties))
            let context = CIContext()
            try context.writeJPEGRepresentation(
                of: edited,
                to: destination,
                colorSpace: edited.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.95])
        }.value
        editLog("commit: rendered to \(destination.lastPathComponent)")

        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest(for: item.asset).contentEditingOutput = output
        }

        editLog("commit: committed ev=\(recipe.exposure)")
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
