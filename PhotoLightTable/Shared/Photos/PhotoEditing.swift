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

    init() {}

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        x = try container.decodeIfPresent(Double.self, forKey: .x) ?? 0
        y = try container.decodeIfPresent(Double.self, forKey: .y) ?? 0
        width = try container.decodeIfPresent(Double.self, forKey: .width) ?? 1
        height = try container.decodeIfPresent(Double.self, forKey: .height) ?? 1
    }

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
    /// Negative sharpens, positive blurs. Spatial rather than tonal, but it
    /// belongs in the same set so a mask gets it for nothing.
    case blur

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
        case .blur: return "Blur"
        }
    }

    var range: ClosedRange<Double> {
        self == .exposure ? -3...3 : -1...1
    }

    /// Blur reads as "sharp ← → blurred" rather than as a signed amount.
    var isSpatial: Bool { self == .blur }

    func formatted(_ value: Double) -> String {
        self == .exposure
            ? String(format: "%+.2f EV", value)
            : String(format: "%+.0f", value * 100)
    }
}

/// The eight tonal values, shared by the whole-image stack and by each mask.
///
/// Factored out so a mask is "the same adjustments, somewhere in particular"
/// rather than a parallel set that could drift apart from the global one.
struct ToneAdjustments: Codable, Equatable {
    var exposure: Double = 0
    var contrast: Double = 0
    var saturation: Double = 0
    var vibrance: Double = 0
    var highlights: Double = 0
    var shadows: Double = 0
    var warmth: Double = 0
    var tint: Double = 0
    var blur: Double = 0

    static let neutral = ToneAdjustments()
    var isNeutral: Bool { self == .neutral }

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
            case .blur: return blur
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
            case .blur: blur = newValue
            }
        }
    }

    var summary: String {
        let parts = Adjustment.allCases
            .filter { self[$0] != 0 }
            .map { "\($0.label) \($0.formatted(self[$0]))" }
        return parts.isEmpty ? "No adjustments" : parts.joined(separator: " · ")
    }

    init() {}

    /// Lenient, so a recipe written before a parameter existed still opens.
    /// Swift's synthesised decoding requires every key regardless of defaults,
    /// and a recipe that fails to decode is indistinguishable from no edit.
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
        blur = try container.decodeIfPresent(Double.self, forKey: .blur) ?? 0
    }

    /// The order follows how the adjustments are meant to be read: overall
    /// exposure, recovery at each end of the range, white balance, then contrast
    /// and saturation over a settled image.
    func apply(to image: CIImage) -> CIImage {
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
            // Pinned rather than left at its default: this is a pixel radius,
            // and an unpinned one would make recovery depend on whether the
            // preview or the original is being rendered.
            filter.radius = Float(min(result.extent.width, result.extent.height) * 0.004)
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

        if blur != 0 { result = Self.blurred(result, amount: blur) }
        return result
    }

    /// Blur radius is a fraction of the image rather than a pixel count.
    ///
    /// A 20px blur on a display-size preview and a 20px blur on a 50MP original
    /// are entirely different effects, so a pixel radius would mean the preview
    /// and the committed render disagree — the one thing this whole recipe
    /// design exists to prevent.
    private static func blurred(_ image: CIImage, amount: Double) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }
        let reference = min(extent.width, extent.height)

        if amount > 0 {
            let filter = CIFilter.gaussianBlur()
            // Sampling beyond the edge would otherwise pull in transparency and
            // leave a soft, darkened border around the whole frame.
            filter.inputImage = image.clampedToExtent()
            filter.radius = Float(amount * reference * 0.04)
            return filter.outputImage?.cropped(to: extent) ?? image
        }

        let filter = CIFilter.sharpenLuminance()
        filter.inputImage = image.clampedToExtent()
        filter.sharpness = Float(-amount * 1.5)
        filter.radius = Float(reference * 0.004)
        return filter.outputImage?.cropped(to: extent) ?? image
    }
}

/// A normalized point with a top-left origin, matching how the UI thinks.
struct EditPoint: Codable, Equatable {
    var x: Double
    var y: Double

    init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        x = try container.decodeIfPresent(Double.self, forKey: .x) ?? 0.5
        y = try container.decodeIfPresent(Double.self, forKey: .y) ?? 0.5
    }

    /// Into Core Image's bottom-left pixel space for a given extent.
    func inPixels(of extent: CGRect) -> CGPoint {
        CGPoint(x: extent.minX + x * extent.width,
                y: extent.minY + (1 - y) * extent.height)
    }
}

/// One painted stroke, stored as the path it followed rather than the pixels it
/// produced — so it re-renders at whatever resolution is being drawn.
struct BrushStroke: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    /// Normalized, top-left origin.
    var points: [EditPoint] = []
    /// Radius as a fraction of the image's shorter side, so a stroke covers the
    /// same part of the photograph on a preview and on the original.
    var radius: Double = defaultRadius
    var isErase: Bool = false

    static let defaultRadius = 0.06

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        points = try container.decodeIfPresent([EditPoint].self, forKey: .points) ?? []
        radius = try container.decodeIfPresent(Double.self, forKey: .radius) ?? Self.defaultRadius
        isErase = try container.decodeIfPresent(Bool.self, forKey: .isErase) ?? false
    }
}

/// A selective adjustment: where it applies, and what it does there.
struct EditMask: Codable, Equatable, Identifiable {
    enum Kind: String, Codable {
        case linear
        case radial
        case brush
    }

    var id: UUID = UUID()
    var kind: Kind = .linear
    var isEnabled: Bool = true
    var isInverted: Bool = false
    var tone = ToneAdjustments()

    init() {}

    /// Lenient, like every other part of a recipe.
    ///
    /// Masks written before brushes existed carry no `strokes` or `softness`,
    /// and synthesised decoding requires every key. Worse, a mask that fails to
    /// decode takes the whole recipe with it — `decodeIfPresent` throws on a key
    /// that is present but malformed — so one old mask would silently discard
    /// the tone and crop alongside it.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .linear
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        isInverted = try container.decodeIfPresent(Bool.self, forKey: .isInverted) ?? false
        tone = try container.decodeIfPresent(ToneAdjustments.self, forKey: .tone) ?? ToneAdjustments()
        start = try container.decodeIfPresent(EditPoint.self, forKey: .start) ?? EditPoint(x: 0.5, y: 0.15)
        end = try container.decodeIfPresent(EditPoint.self, forKey: .end) ?? EditPoint(x: 0.5, y: 0.55)
        strokes = try container.decodeIfPresent([BrushStroke].self, forKey: .strokes) ?? []
        softness = try container.decodeIfPresent(Double.self, forKey: .softness) ?? Self.defaultSoftness
    }

    /// For a linear gradient, the ramp runs from `start` (no effect) to `end`
    /// (full effect). For a radial one, `start` is the centre and `end` sits on
    /// the edge of the falloff.
    var start = EditPoint(x: 0.5, y: 0.15)
    var end = EditPoint(x: 0.5, y: 0.55)

    /// Brush only.
    var strokes: [BrushStroke] = []
    /// How far the painted edge feathers, as a fraction of the shorter side.
    var softness: Double = defaultSoftness

    static let defaultSoftness = 0.35

    var name: String {
        switch kind {
        case .linear: return "Linear Gradient"
        case .radial: return "Radial Gradient"
        case .brush: return "Brush"
        }
    }

    /// A brush with nothing painted has no effect, unlike a gradient which
    /// always covers something.
    var isEmpty: Bool { kind == .brush && strokes.allSatisfy { $0.points.isEmpty } }

    /// Geometry is stored against the *uncropped* image, so changing the crop
    /// reframes the photo without dragging the masks across its content.
    func maskImage(for extent: CGRect) -> CIImage? {
        let p0 = start.inPixels(of: extent)
        let p1 = end.inPixels(of: extent)

        let clear = CIColor(red: 0, green: 0, blue: 0, alpha: 1)
        let solid = CIColor(red: 1, green: 1, blue: 1, alpha: 1)
        let from = isInverted ? solid : clear
        let to = isInverted ? clear : solid

        if kind == .brush {
            return Self.brushMask(strokes: strokes,
                                  softness: softness,
                                  inverted: isInverted,
                                  extent: extent)
        }

        let generated: CIImage?
        switch kind {
        case .linear:
            let filter = CIFilter.smoothLinearGradient()
            filter.point0 = p0
            filter.point1 = p1
            filter.color0 = from
            filter.color1 = to
            generated = filter.outputImage
        case .radial:
            let filter = CIFilter.radialGradient()
            filter.center = p0
            filter.radius0 = 0
            filter.radius1 = Float(hypot(p1.x - p0.x, p1.y - p0.y))
            filter.color0 = to
            filter.color1 = from
            generated = filter.outputImage
        case .brush:
            generated = nil
        }

        // Gradient generators are infinite; without cropping, the blend has no
        // definite extent and the render size becomes unbounded.
        return generated?.cropped(to: extent)
    }

    /// Rasterises the strokes into a grayscale mask.
    ///
    /// Core Graphics rather than a chain of Core Image gradients: a hundred
    /// strokes would be a hundred composites, where one bitmap is one. The
    /// raster is capped and scaled up to the target extent, which is invisible
    /// because a painted mask is feathered anyway — the strokes themselves stay
    /// resolution-independent, which is what actually matters.
    private static func brushMask(strokes: [BrushStroke],
                                  softness: Double,
                                  inverted: Bool,
                                  extent: CGRect) -> CIImage? {
        let painted = strokes.filter { !$0.points.isEmpty }
        guard !painted.isEmpty, extent.width > 0, extent.height > 0 else { return nil }

        let cap: CGFloat = 2048
        let scale = min(1, cap / max(extent.width, extent.height))
        let width = max(1, Int(extent.width * scale))
        let height = max(1, Int(extent.height * scale))
        let reference = CGFloat(min(width, height))

        guard let context = CGContext(data: nil,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }

        context.setFillColor(gray: inverted ? 1 : 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setLineCap(.round)
        context.setLineJoin(.round)

        for stroke in painted {
            // Erasing paints the background value back, which is why inversion
            // has to swap both ends rather than negate the result afterwards.
            let paint: CGFloat = stroke.isErase ? (inverted ? 1 : 0) : (inverted ? 0 : 1)
            context.setStrokeColor(gray: paint, alpha: 1)
            context.setLineWidth(max(1, stroke.radius * 2 * reference))

            // Normalized top-left to the context's bottom-left origin.
            let points = stroke.points.map {
                CGPoint(x: $0.x * CGFloat(width), y: (1 - $0.y) * CGFloat(height))
            }
            if points.count == 1 {
                // A tap is a dot, which a zero-length path won't draw.
                let radius = max(0.5, stroke.radius * reference)
                context.setFillColor(gray: paint, alpha: 1)
                context.fillEllipse(in: CGRect(x: points[0].x - radius,
                                               y: points[0].y - radius,
                                               width: radius * 2,
                                               height: radius * 2))
            } else {
                context.addLines(between: points)
                context.strokePath()
            }
        }

        guard let raster = context.makeImage() else { return nil }
        var image = CIImage(cgImage: raster)

        if softness > 0 {
            let blur = CIFilter.gaussianBlur()
            blur.inputImage = image.clampedToExtent()
            blur.radius = Float(softness * reference * 0.12)
            image = blur.outputImage?.cropped(to: image.extent) ?? image
        }

        return image
            .transformed(by: CGAffineTransform(scaleX: extent.width / CGFloat(width),
                                               y: extent.height / CGFloat(height)))
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
            .cropped(to: extent)
    }
}

struct PhotoEditRecipe: Codable, Equatable {
    var tone = ToneAdjustments()
    var masks: [EditMask] = []
    var crop: CropRect = .full

    static let neutral = PhotoEditRecipe()
    var isNeutral: Bool { self == .neutral }

    var hasNeutralTone: Bool { tone.isNeutral }

    subscript(adjustment: Adjustment) -> Double {
        get { tone[adjustment] }
        set { tone[adjustment] = newValue }
    }

    var summary: String {
        var parts: [String] = []
        if !tone.isNeutral { parts.append(tone.summary) }
        let active = masks.filter { $0.isEnabled && !$0.tone.isNeutral }.count
        if active > 0 { parts.append("\(active) mask\(active == 1 ? "" : "s")") }
        if !crop.isFull { parts.append("Cropped") }
        return parts.isEmpty ? "No adjustments" : parts.joined(separator: " · ")
    }

    init() {}

    /// Reads both shapes: the tonal values used to sit at the top level, before
    /// masks needed the same set. Old recipes decode into `tone` so edits made
    /// before this change still open as parameters rather than as nothing.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let nested = try container.decodeIfPresent(ToneAdjustments.self, forKey: .tone) {
            tone = nested
        } else {
            tone = try ToneAdjustments(from: decoder)
        }
        // Each field falls back on its own. Losing the masks is bad; losing the
        // exposure and the crop as collateral because one mask wouldn't parse is
        // far worse, and indistinguishable from the photo never having been
        // edited at all.
        masks = (try? container.decodeIfPresent([EditMask].self, forKey: .masks)) ?? []
        crop = (try? container.decodeIfPresent(CropRect.self, forKey: .crop)) ?? .full
    }

    /// Whole-image tone, then each mask over the result, then geometry.
    ///
    /// Masks run against the uncropped extent so their placement is a fact about
    /// the photo rather than about the current crop.
    func apply(to image: CIImage, applyCrop: Bool = true) -> CIImage {
        var result = tone.apply(to: image)

        for mask in masks where mask.isEnabled && !mask.tone.isNeutral && !mask.isEmpty {
            guard let maskImage = mask.maskImage(for: result.extent) else { continue }
            let adjusted = mask.tone.apply(to: result)

            let blend = CIFilter.blendWithMask()
            blend.inputImage = adjusted
            blend.backgroundImage = result
            blend.maskImage = maskImage
            result = blend.outputImage ?? result
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
    case staleSession

    var errorDescription: String? {
        switch self {
        case .notEditable: return "This photo can't be edited."
        case .couldNotOpen: return "Could not open the photo for editing."
        case .couldNotRender: return "Could not render the edited photo."
        case .staleSession: return "The photo changed while it was open. Reopen it and try again."
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
    static let formatVersion = "3"
    /// Every version this build can still read. Dropping "1" here would make
    /// existing edits look like another app's work: PhotoKit would hand back the
    /// rendered image instead of the original, and the next edit would compound
    /// on top of the last one.
    static let readableFormatVersions: Set<String> = ["1", "2", "3"]

    @Published var recipe = PhotoEditRecipe()
    @Published private(set) var preview: PlatformImage?
    /// The photo as it stood when this session opened, for comparison.
    @Published private(set) var beforePreview: PlatformImage?
    /// Rendering the "before" costs a second pass over the image, so it is only
    /// produced while something is actually showing it.
    var wantsBeforePreview = false {
        didSet { if wantsBeforePreview != oldValue { renderPreview(applyCrop: pendingApplyCrop) } }
    }
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
    private var previewTask: Task<Void, Never>?
    private var pendingApplyCrop = true
    /// Which asset `input` was obtained for, so a commit can refuse a mismatch.
    private var inputAssetID: String?
    /// Bumped per `begin`, so a slow load that finishes after a newer one is
    /// discarded instead of overwriting it.
    private var generation = 0

    var isDirty: Bool { recipe != loadedRecipe }
    private var loadedRecipe = PhotoEditRecipe.neutral

    // MARK: - Opening

    func begin(for item: PhotoItem) async {
        reset()
        generation += 1
        let token = generation
        isLoading = true
        defer { if token == generation { isLoading = false } }

        // canPerform faults PHAssetAdjustmentProperties, which PhotoKit warns
        // about when it happens on the main queue. There is no fetch option to
        // prefetch them, so the read is moved off instead.
        let asset = item.asset
        let editable = await Task.detached { asset.canPerform(.content) }.value
        // Arrowing to another photo while a slow load is in flight would
        // otherwise let the older one land on top of the newer session — and a
        // later commit would render one photo's pixels onto another's asset.
        guard token == generation else { return }
        canEdit = editable
        guard canEdit else { return }

        let loaded = await Self.loadInput(for: item.asset)
        guard token == generation else { return }
        guard let loaded else {
            errorMessage = PhotoEditError.couldNotOpen.localizedDescription
            return
        }

        input = loaded
        inputAssetID = item.id
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
        previewTask?.cancel()
        previewTask = nil
        input = nil
        inputAssetID = nil
        previewBase = nil
        preview = nil
        beforePreview = nil
        recipe = .neutral
        loadedRecipe = .neutral
        hasExistingEdit = false
        errorMessage = nil
    }

    // MARK: - Preview

    /// Asks for a preview, coalescing repeated requests.
    ///
    /// Dragging a slider asks far more often than a render can be produced, and
    /// rendering straight from the binding's setter publishes `preview` while
    /// SwiftUI is mid-update — which is undefined behaviour and what the
    /// "Publishing changes from within view updates" warning reports. Yielding
    /// first moves the publish out of the update pass and drops the redundant
    /// renders on the way.
    func renderPreview(applyCrop: Bool = true) {
        pendingApplyCrop = applyCrop
        guard previewTask == nil else { return }

        let token = generation
        previewTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, token == self.generation else { return }
            self.previewTask = nil
            self.renderPreviewNow(applyCrop: self.pendingApplyCrop)
        }
    }

    /// Renders at display size, which is what `PHContentEditingInput` provides
    /// for exactly this purpose — the full-size render is deferred to commit.
    private func renderPreviewNow(applyCrop: Bool) {
        guard let previewBase else { return }
        let edited = recipe.apply(to: previewBase, applyCrop: applyCrop)
        if let cgImage = context.createCGImage(edited, from: edited.extent) {
            preview = PlatformImage.from(cgImage)
        }

        guard wantsBeforePreview else {
            beforePreview = nil
            return
        }
        let before = beforeRecipe.apply(to: previewBase, applyCrop: applyCrop)
        if let cgImage = context.createCGImage(before, from: before.extent) {
            beforePreview = PlatformImage.from(cgImage)
        }
    }

    /// The tone and masks as they were when the session opened, framed as the
    /// photo is framed now.
    ///
    /// Keeping the current crop is what makes a split comparison legible: two
    /// images of different shapes can't be compared across a divider, and the
    /// question being asked is what the adjustments did, not what the crop did.
    private var beforeRecipe: PhotoEditRecipe {
        var recipe = loadedRecipe
        recipe.crop = self.recipe.crop
        return recipe
    }

    /// Whether anything actually differs from how the session opened.
    var hasVisibleChange: Bool { recipe != loadedRecipe }

    // MARK: - Committing

    func commit(for item: PhotoItem) async throws {
        // The input describes one specific asset; committing it against another
        // would render the wrong photo's pixels into it.
        guard let input, inputAssetID == item.id else { throw PhotoEditError.staleSession }

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
        let options = inputOptions()
        return await withCheckedContinuation { continuation in
            // Requested off the main queue: the call faults
            // PHAssetAdjustmentProperties synchronously on whichever thread
            // makes it, and PhotoKit warns when that is the main one. There is
            // no fetch option to prefetch them.
            DispatchQueue.global(qos: .userInitiated).async {
                asset.requestContentEditingInput(with: options) { input, _ in
                    continuation.resume(returning: input)
                }
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
            // A RAW decoded by CIImage(contentsOf:) is ImageIO's baseline
            // rendering, which is not what Photos shows and not what the
            // adjustments were judged against. CIRAWFilter returns nil for
            // anything that isn't RAW, so this is also the format test.
            let oriented: CIImage
            if let raw = CIRAWFilter(imageURL: sourceURL) {
                // CIRAWFilter orients the image itself, from its own
                // `orientation` property. Applying the EXIF orientation on top
                // of that rotates the photo twice — which writes a render that
                // is correct in the editor, because the editor works from
                // PhotoKit's original, and wrong everywhere the rendered file is
                // shown.
                raw.orientation = CGImagePropertyOrientation(rawValue: UInt32(orientation)) ?? .up
                guard let decoded = raw.outputImage else { throw PhotoEditError.couldNotRender }
                oriented = decoded
                editLog("write: RAW pipeline, orientation applied by decoder")
            } else if let decoded = CIImage(contentsOf: sourceURL) {
                // ImageIO hands back unrotated pixels with the orientation left
                // in the metadata, so it has to be applied here.
                oriented = decoded.oriented(forExifOrientation: orientation)
                editLog("write: ImageIO pipeline, orientation applied here")
            } else {
                throw PhotoEditError.couldNotRender
            }

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
        let editable = await Task.detached { asset.canPerform(.content) }.value
        guard editable else { throw PhotoEditError.notEditable }
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
        record(.neutral, for: item)

        // Reverting changes the asset's content version, so the input held from
        // before it describes a version that no longer exists. Committing
        // against it afterwards is rejected — or worse, writes a render derived
        // from the pre-revert state.
        await begin(for: item)
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
        do {
            return try JSONDecoder().decode(PhotoEditRecipe.self, from: data.data)
        } catch {
            // A recipe this app wrote that it can no longer read means an edit
            // silently reverting to the original, so it is worth knowing about.
            editLog("decode: FAILED version=\(data.formatVersion) — \(error)")
            return nil
        }
    }
}
