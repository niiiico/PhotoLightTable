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

/// A tonal adjustment, described once so the UI can be generated from it rather
/// than repeating a slider per parameter.
///
/// Every value is neutral at zero and runs -1…1, apart from exposure which is in
/// stops. The mapping into each filter's own units happens in `apply`, so the
/// stored recipe stays in terms a person would recognise.
enum Adjustment: String, CaseIterable, Identifiable, Codable {
    case exposure, contrast, saturation, vibrance
    case highlights, shadows, warmth, tint

    var id: String { rawValue }

    var label: String {
        switch self {
        case .exposure: return "Exposure"
        case .contrast: return "Contrast"
        case .saturation: return "Saturation"
        case .vibrance: return "Vibrance"
        case .highlights: return "Highlights"
        case .shadows: return "Shadows"
        case .warmth: return "Warmth"
        case .tint: return "Tint"
        }
    }

    var range: ClosedRange<Double> {
        self == .exposure ? -3...3 : -1...1
    }

    func formatted(_ value: Double) -> String {
        self == .exposure
            ? String(format: "%+.2f EV", value)
            : String(format: "%+.0f", value * 100)
    }
}

struct PhotoEditRecipe: Codable, Equatable {
    var exposure: Double = 0
    var contrast: Double = 0
    var saturation: Double = 0
    var vibrance: Double = 0
    var highlights: Double = 0
    var shadows: Double = 0
    var warmth: Double = 0
    var tint: Double = 0
    var crop: CropRect = .full

    static let neutral = PhotoEditRecipe()
    var isNeutral: Bool { self == .neutral }

    /// True when no tonal adjustment is set, regardless of the crop.
    var hasNeutralTone: Bool {
        Adjustment.allCases.allSatisfy { self[$0] == 0 }
    }

    subscript(adjustment: Adjustment) -> Double {
        get {
            switch adjustment {
            case .exposure: return exposure
            case .contrast: return contrast
            case .saturation: return saturation
            case .vibrance: return vibrance
            case .highlights: return highlights
            case .shadows: return shadows
            case .warmth: return warmth
            case .tint: return tint
            }
        }
        set {
            switch adjustment {
            case .exposure: exposure = newValue
            case .contrast: contrast = newValue
            case .saturation: saturation = newValue
            case .vibrance: vibrance = newValue
            case .highlights: highlights = newValue
            case .shadows: shadows = newValue
            case .warmth: warmth = newValue
            case .tint: tint = newValue
            }
        }
    }

    var summary: String {
        var parts = Adjustment.allCases
            .filter { self[$0] != 0 }
            .map { "\($0.label) \($0.formatted(self[$0]))" }
        if !crop.isFull { parts.append("Cropped") }
        return parts.isEmpty ? "No adjustments" : parts.joined(separator: " · ")
    }

    /// Decoded leniently so a recipe written before a field existed still opens.
    ///
    /// Swift's synthesised decoding requires every key to be present, defaults
    /// notwithstanding — which would make each new parameter silently orphan
    /// every edit made before it, since a recipe that fails to decode reads as
    /// no edit at all.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        exposure = try container.decodeIfPresent(Double.self, forKey: .exposure) ?? 0
        contrast = try container.decodeIfPresent(Double.self, forKey: .contrast) ?? 0
        saturation = try container.decodeIfPresent(Double.self, forKey: .saturation) ?? 0
        vibrance = try container.decodeIfPresent(Double.self, forKey: .vibrance) ?? 0
        highlights = try container.decodeIfPresent(Double.self, forKey: .highlights) ?? 0
        shadows = try container.decodeIfPresent(Double.self, forKey: .shadows) ?? 0
        warmth = try container.decodeIfPresent(Double.self, forKey: .warmth) ?? 0
        tint = try container.decodeIfPresent(Double.self, forKey: .tint) ?? 0
        crop = try container.decodeIfPresent(CropRect.self, forKey: .crop) ?? .full
    }

    init() {}

    /// Tone first, geometry last: cropping is a change of frame, and applying it
    /// before the adjustments would leave every later mask defined against a
    /// different extent depending on whether a crop happened to be set.
    ///
    /// The order within the tonal stack follows how the adjustments are meant to
    /// be read: overall exposure, then recovery at each end of the range, then
    /// white balance, then contrast and saturation on top of a settled image.
    func apply(to image: CIImage, applyCrop: Bool = true) -> CIImage {
        var result = image

        if exposure != 0 {
            let filter = CIFilter.exposureAdjust()
            filter.inputImage = result
            filter.ev = Float(exposure)
            result = filter.outputImage ?? result
        }

        if highlights != 0 || shadows != 0 {
            let filter = CIFilter.highlightShadowAdjust()
            filter.inputImage = result
            // highlightAmount is neutral at 1 and shadowAmount at 0, so the two
            // map differently from the same -1…1 slider.
            filter.highlightAmount = Float(1 + highlights)
            filter.shadowAmount = Float(shadows)
            result = filter.outputImage ?? result
        }

        if warmth != 0 || tint != 0 {
            let filter = CIFilter.temperatureAndTint()
            filter.inputImage = result
            filter.neutral = CIVector(x: 6500, y: 0)
            filter.targetNeutral = CIVector(x: 6500 + warmth * 2500, y: tint * 100)
            result = filter.outputImage ?? result
        }

        if contrast != 0 || saturation != 0 {
            let filter = CIFilter.colorControls()
            filter.inputImage = result
            filter.brightness = 0
            filter.contrast = Float(1 + contrast * 0.5)
            filter.saturation = Float(1 + saturation)
            result = filter.outputImage ?? result
        }

        if vibrance != 0 {
            let filter = CIFilter.vibrance()
            filter.inputImage = result
            filter.amount = Float(vibrance)
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
    static let formatVersion = "2"
    /// Every version this build can still read. Dropping "1" here would make
    /// existing edits look like another app's work: PhotoKit would hand back the
    /// rendered image instead of the original, and the next edit would compound
    /// on top of the last one.
    static let readableFormatVersions: Set<String> = ["1", "2"]

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

        let loaded = await Self.loadInput(for: item.asset)
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

        isCommitting = true
        defer { isCommitting = false }

        try await Self.write(recipe, using: input, to: item.asset)
        loadedRecipe = recipe
        hasExistingEdit = true
        record(recipe, for: item)
    }

    // MARK: - Applying without a session

    /// Options that claim our own adjustment data.
    ///
    /// This is what makes re-editing non-destructive: PhotoKit hands back the
    /// *original* image along with the previous recipe, instead of an image with
    /// the last edit already baked in. Returning false would compound edits.
    static func inputOptions() -> PHContentEditingInputRequestOptions {
        let options = PHContentEditingInputRequestOptions()
        options.isNetworkAccessAllowed = true
        options.canHandleAdjustmentData = { data in
            data.formatIdentifier == formatIdentifier
                && readableFormatVersions.contains(data.formatVersion)
        }
        return options
    }

    static func loadInput(for asset: PHAsset) async -> PHContentEditingInput? {
        await withCheckedContinuation { continuation in
            asset.requestContentEditingInput(with: inputOptions()) { input, _ in
                continuation.resume(returning: input)
            }
        }
    }

    /// Reads whatever recipe a photo currently carries, if this app wrote it.
    static func recipe(of asset: PHAsset) async -> PhotoEditRecipe? {
        guard let input = await loadInput(for: asset) else { return nil }
        return decode(input.adjustmentData)
    }

    /// Renders a recipe at full resolution and commits it.
    ///
    /// Shared by the editing session and by pasting onto a selection, so both
    /// produce byte-identical results and there is one place where the
    /// orientation and encoding rules live.
    static func write(_ recipe: PhotoEditRecipe,
                      using input: PHContentEditingInput,
                      to asset: PHAsset) async throws {
        guard let sourceURL = input.fullSizeImageURL else { throw PhotoEditError.couldNotOpen }
        editLog("write: begin orientation=\(input.fullSizeImageOrientation) source=\(sourceURL.lastPathComponent)")

        let output = PHContentEditingOutput(contentEditingInput: input)
        output.adjustmentData = PHAdjustmentData(
            formatIdentifier: formatIdentifier,
            formatVersion: formatVersion,
            data: try JSONEncoder().encode(recipe))

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

        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest(for: asset).contentEditingOutput = output
        }
        editLog("write: committed")
    }

    /// Loads, renders and commits in one call, for photos with no open session.
    static func apply(_ recipe: PhotoEditRecipe, to asset: PHAsset) async throws {
        guard asset.canPerform(.content) else { throw PhotoEditError.notEditable }
        guard let input = await loadInput(for: asset) else { throw PhotoEditError.couldNotOpen }
        try await write(recipe, using: input, to: asset)
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

    static func decode(_ data: PHAdjustmentData?) -> PhotoEditRecipe? {
        guard let data,
              data.formatIdentifier == formatIdentifier,
              readableFormatVersions.contains(data.formatVersion) else { return nil }
        return try? JSONDecoder().decode(PhotoEditRecipe.self, from: data.data)
    }
}
