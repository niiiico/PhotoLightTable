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
    case exposure, contrast, blackPoint, saturation, vibrance
    case highlights, shadows, warmth, tint
    case definition, noiseReduction
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
        case .blackPoint: return "Black Point"
        case .definition: return "Definition"
        case .noiseReduction: return "Noise Reduction"
        case .blur: return "Blur"
        }
    }

    var range: ClosedRange<Double> {
        switch self {
        case .exposure: return -3...3
        // Nothing below zero would mean anything: there is no negative amount
        // of noise to remove.
        case .noiseReduction: return 0...1
        default: return -1...1
        }
    }

    var isUnipolar: Bool { self == .noiseReduction }

    /// Blur reads as "sharp ← → blurred" rather than as a signed amount.
    var isSpatial: Bool { self == .blur }

    func formatted(_ value: Double) -> String {
        if self == .exposure { return String(format: "%+.2f EV", value) }
        if isUnipolar { return String(format: "%.0f", value * 100) }
        return String(format: "%+.0f", value * 100)
    }

    /// What this adjustment does, where the name alone doesn't say.
    var explanation: String? {
        switch self {
        case .blur: return "Negative sharpens, positive blurs"
        case .definition: return "Local contrast — separate from sharpening"
        case .blackPoint: return "Where the darkest tone sits"
        case .noiseReduction: return "Strongest settings soften fine detail"
        default: return nil
        }
    }
}

/// A colour in the photo that should read as neutral.
///
/// Stored as the sampled colour rather than as a temperature, because the
/// mapping back from a pixel to a colour temperature isn't invertible — two
/// different illuminants can produce the same pixel. `CIWhitePointAdjust` takes
/// the colour directly, so nothing has to be inferred.
struct WhitePoint: Codable, Equatable {
    var red: Double
    var green: Double
    var blue: Double

    /// Scaled so the correction changes colour without changing brightness.
    ///
    /// `CIWhitePointAdjust` maps the given colour to white, which on a dark
    /// sample would also lift the whole image. Dividing through by luminance
    /// leaves only the ratio between channels, which is the part that describes
    /// the illuminant.
    var luminanceNormalized: WhitePoint? {
        let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
        guard luminance > 0.02 else { return nil }
        return WhitePoint(red: red / luminance,
                          green: green / luminance,
                          blue: blue / luminance)
    }

    var ciColor: CIColor {
        CIColor(red: red, green: green, blue: blue)
    }
}

/// The tonal values, shared by the whole-image stack and by each mask.
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
    var blackPoint: Double = 0
    var definition: Double = 0
    var noiseReduction: Double = 0
    var blur: Double = 0
    /// Set by sampling a neutral in the photo; nil means no reference taken.
    var whitePoint: WhitePoint?

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
            case .blackPoint: return blackPoint
            case .definition: return definition
            case .noiseReduction: return noiseReduction
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
            case .blackPoint: blackPoint = newValue
            case .definition: definition = newValue
            case .noiseReduction: noiseReduction = newValue
            case .blur: blur = newValue
            }
        }
    }

    var summary: String {
        var parts = Adjustment.allCases
            .filter { self[$0] != 0 }
            .map { "\($0.label) \($0.formatted(self[$0]))" }
        if whitePoint != nil { parts.append("White balanced") }
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
        blackPoint = try container.decodeIfPresent(Double.self, forKey: .blackPoint) ?? 0
        definition = try container.decodeIfPresent(Double.self, forKey: .definition) ?? 0
        noiseReduction = try container.decodeIfPresent(Double.self, forKey: .noiseReduction) ?? 0
        blur = try container.decodeIfPresent(Double.self, forKey: .blur) ?? 0
        whitePoint = try? container.decodeIfPresent(WhitePoint.self, forKey: .whitePoint)
    }

    /// The order follows how the adjustments are meant to be read: overall
    /// exposure, recovery at each end of the range, white balance, then contrast
    /// and saturation over a settled image.
    func apply(to image: CIImage) -> CIImage {
        var result = image

        // First, so nothing downstream amplifies what is about to be removed.
        if noiseReduction > 0 {
            let filter = CIFilter.noiseReduction()
            filter.inputImage = result
            filter.noiseLevel = Float(noiseReduction * 0.08)
            filter.sharpness = 0.4
            result = filter.outputImage ?? result
        }

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

        if blackPoint != 0 {
            // Only the foot of the curve moves: positive pushes the darkest
            // tones to black, negative lifts them off it. Pure tone mapping, so
            // it means the same thing at any size.
            let filter = CIFilter.toneCurve()
            filter.inputImage = result
            filter.point0 = CGPoint(x: max(0, blackPoint) * 0.2,
                                    y: max(0, -blackPoint) * 0.15)
            filter.point1 = CGPoint(x: 0.25, y: 0.25)
            filter.point2 = CGPoint(x: 0.5, y: 0.5)
            filter.point3 = CGPoint(x: 0.75, y: 0.75)
            filter.point4 = CGPoint(x: 1, y: 1)
            result = filter.outputImage ?? result
        }

        // Before warmth and tint, so the sampled neutral sets the reference and
        // those two remain an adjustment relative to it rather than a competing
        // opinion about the same thing.
        if let normalized = whitePoint?.luminanceNormalized {
            let filter = CIFilter.whitePointAdjust()
            filter.inputImage = result
            filter.color = normalized.ciColor
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

        if definition != 0 {
            // An unsharp mask with a large radius is local contrast, not
            // sharpening: it works on regions rather than edges. The radius is a
            // fraction of the image so the regions stay the same size relative
            // to the subject however large the render is.
            let extent = result.extent
            let filter = CIFilter.unsharpMask()
            filter.inputImage = result.clampedToExtent()
            filter.radius = Float(min(extent.width, extent.height) * 0.02)
            filter.intensity = Float(definition * 0.8)
            result = filter.outputImage?.cropped(to: extent) ?? result
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
/// A selection stored as a small picture of itself.
///
/// Strokes cannot describe a silhouette, so a subject selection is kept as an
/// image — but a tiny one. Vision analyses at 512×512 and upscales, so nothing
/// is lost by keeping the small version and stretching it back at render time:
/// storing the full-resolution mask would be storing an interpolation.
///
/// Roughly 4 KB of base64 in the recipe for a typical subject, which is the
/// price of never having to ask the model the same question twice — and of an
/// edit that cannot change under a future version of it.
struct MaskRegion: Codable, Equatable {
    /// A grayscale PNG, white where selected. `Data` rides in JSON as base64,
    /// so nothing extra is needed to carry it.
    var png: Data

    /// Decoded fresh each time rather than cached. A 512-pixel grayscale PNG
    /// costs about a millisecond, which is far below the render it is part of,
    /// and a cache keyed by image data would need locking to be safe across the
    /// render queue — real complexity for an imagined saving.
    func decoded() -> CGImage? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// The selection as something that can be laid over the photo: red where
    /// selected, transparent everywhere else.
    ///
    /// The stored region is grayscale and fully opaque, so drawing it directly
    /// would cover the picture in a grey rectangle. The mask has to become
    /// alpha before it can become a highlight.
    func overlayImage(tint: CIColor = CIColor(red: 1, green: 0.23, blue: 0.19)) -> CGImage? {
        guard let decoded = decoded() else { return nil }
        let mask = CIImage(cgImage: decoded)

        let blend = CIFilter.blendWithMask()
        blend.inputImage = CIImage(color: tint).cropped(to: mask.extent)
        blend.backgroundImage = CIImage(color: .clear).cropped(to: mask.extent)
        blend.maskImage = mask

        guard let output = blend.outputImage else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
}

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
        region = (try? container.decodeIfPresent(MaskRegion.self, forKey: .region)) ?? nil
        strokes = try container.decodeIfPresent([BrushStroke].self, forKey: .strokes) ?? []
        softness = try container.decodeIfPresent(Double.self, forKey: .softness) ?? Self.defaultSoftness
    }

    /// For a linear gradient, the ramp runs from `start` (no effect) to `end`
    /// (full effect). For a radial one, `start` is the centre and `end` sits on
    /// the edge of the falloff.
    var start = EditPoint(x: 0.5, y: 0.15)
    var end = EditPoint(x: 0.5, y: 0.55)

    /// Brush only: a selection to start from, which the strokes then add to and
    /// take away from. Seeded by tapping a subject; nil for a mask that was
    /// only ever painted.
    var region: MaskRegion?
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
    var isEmpty: Bool {
        kind == .brush && region == nil && strokes.allSatisfy { $0.points.isEmpty }
    }

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
            return Self.brushMask(region: region,
                                  strokes: strokes,
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
    /// Rasterises a brush mask: the seeded region first, then the strokes over
    /// it.
    ///
    /// Built the right way up and inverted at the end, rather than each mark
    /// being drawn in whichever shade inversion happens to call for. With only
    /// strokes that was merely fiddly; with a region underneath them it would
    /// mean inverting the picture before drawing on it, which is two ways of
    /// saying the same thing and one of them would eventually be wrong.
    private static func brushMask(region: MaskRegion?,
                                  strokes: [BrushStroke],
                                  softness: Double,
                                  inverted: Bool,
                                  extent: CGRect) -> CIImage? {
        let painted = strokes.filter { !$0.points.isEmpty }
        guard region != nil || !painted.isEmpty,
              extent.width > 0, extent.height > 0 else { return nil }

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

        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Stretched to the frame rather than fitted: the selection was analysed
        // against the whole photo, so it already has the photo's proportions
        // however square the buffer it came back in.
        if let seeded = region?.decoded() {
            context.draw(seeded, in: CGRect(x: 0, y: 0, width: width, height: height))
        }

        context.setLineCap(.round)
        context.setLineJoin(.round)

        for stroke in painted {
            let paint: CGFloat = stroke.isErase ? 0 : 1
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

        // Inverted once, at the end. Blurring first and inverting after gives
        // the same edge either way, so this costs nothing.
        if inverted {
            let invert = CIFilter.colorInvert()
            invert.inputImage = image
            image = invert.outputImage ?? image
        }

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
    /// Degrees to rotate the photo to level it, positive anticlockwise. Zero is
    /// untouched, and the range is deliberately small — this is for a horizon
    /// that is out by a degree or two, not for turning a picture on its side.
    var straighten: Double = 0

    static let straightenRange: ClosedRange<Double> = -15...15

    static let neutral = PhotoEditRecipe()
    var isNeutral: Bool { self == .neutral }

    var hasNeutralTone: Bool { tone.isNeutral }

    /// A name for this treatment, so a duplicate arrives already described
    /// rather than as "Copy".
    var suggestedVariantLabel: String {
        if tone.saturation <= -0.99 { return "B&W" }
        if tone.saturation < -0.4 { return "Muted" }
        if tone.warmth > 0.3 { return "Warm" }
        if tone.warmth < -0.3 { return "Cool" }
        if tone.contrast > 0.3 { return "Punchy" }
        if !crop.isFull { return "Crop" }
        return "Variant"
    }

    /// True when the whole-image tone carries nothing at all, white point
    /// included — `Adjustment.allCases` doesn't cover it, since it isn't a
    /// slider.
    var hasNeutralToneIncludingWhitePoint: Bool {
        tone.isNeutral && tone.whitePoint == nil
    }

    subscript(adjustment: Adjustment) -> Double {
        get { tone[adjustment] }
        set { tone[adjustment] = newValue }
    }

    var summary: String {
        var parts: [String] = []
        if !tone.isNeutral { parts.append(tone.summary) }
        let active = masks.filter { $0.isEnabled && !$0.tone.isNeutral }.count
        if active > 0 { parts.append("\(active) mask\(active == 1 ? "" : "s")") }
        if straighten != 0 { parts.append(String(format: "Straightened %+.1f°", straighten)) }
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
        straighten = (try? container.decodeIfPresent(Double.self, forKey: .straighten)) ?? 0
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

        // Before the crop, so the crop frames what the straightened photo
        // actually shows rather than a rectangle that is itself tilted.
        if straighten != 0 {
            result = Self.straightened(result, degrees: straighten)
        }

        if applyCrop, !crop.isFull {
            result = Self.cropped(result, to: crop)
        }
        return result
    }

    /// Rotates about the centre and takes back the largest rectangle of the
    /// original shape that still fits inside.
    ///
    /// Rotating a rectangle leaves four empty triangles at the corners. Filling
    /// them would be inventing pixels; leaving them would put transparent
    /// wedges into a photograph. So the photo is scaled into what remains,
    /// which is what every straighten control does and why straightening always
    /// costs a little reach at the edges.
    static func straightened(_ image: CIImage, degrees: Double) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0, degrees != 0 else { return image }

        let radians = degrees * .pi / 180
        let centre = CGPoint(x: extent.midX, y: extent.midY)
        let rotation = CGAffineTransform(translationX: centre.x, y: centre.y)
            .rotated(by: radians)
            .translatedBy(x: -centre.x, y: -centre.y)
        let rotated = image.transformed(by: rotation)

        let inner = largestInteriorSize(width: extent.width,
                                        height: extent.height,
                                        radians: radians)
        let rect = CGRect(x: centre.x - inner.width / 2,
                          y: centre.y - inner.height / 2,
                          width: inner.width,
                          height: inner.height)

        // Scaled back up so straightening does not silently shrink the photo —
        // the frame keeps its pixel dimensions and simply reaches less far.
        let scale = extent.width / max(inner.width, 1)
        return rotated
            .cropped(to: rect)
            .transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }

    /// The largest rectangle of the same proportions that fits inside a `width`
    /// by `height` rectangle rotated about its centre by `radians`.
    ///
    /// Same *shape*, not merely the largest area. The textbook "largest
    /// rectangle in a rotated rectangle" is unconstrained and comes out a
    /// different shape — 1.63 rather than 1.5 for a 3:2 photo at 5° — which
    /// would silently reshape the frame. Straightening should cost reach at the
    /// edges and nothing else; changing the proportions is a crop, and the crop
    /// is the user's to make.
    ///
    /// Solved rather than searched. A centred rectangle half `X` wide and half
    /// `Y` tall fits when its corners, turned back by the same angle, stay
    /// inside the original:
    ///
    ///     X·cos + Y·sin ≤ width/2
    ///     X·sin + Y·cos ≤ height/2
    ///
    /// Holding `Y = X / ratio` leaves two bounds on `X`, and the smaller wins.
    static func largestInteriorSize(width: CGFloat,
                                    height: CGFloat,
                                    radians: CGFloat) -> CGSize {
        guard width > 0, height > 0 else { return .zero }

        let ratio = width / height
        let cosA = abs(cos(radians))
        let sinA = abs(sin(radians))

        let byWidth = (width / 2) / (cosA + sinA / ratio)
        let byHeight = (height / 2) / (sinA + cosA / ratio)
        let half = min(byWidth, byHeight)

        return CGSize(width: half * 2, height: half * 2 / ratio)
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
    static let formatVersion = "4"
    /// Every version this build can still read. Dropping "1" here would make
    /// existing edits look like another app's work: PhotoKit would hand back the
    /// rendered image instead of the original, and the next edit would compound
    /// on top of the last one.
    static let readableFormatVersions: Set<String> = ["1", "2", "3", "4"]

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
    /// What the last "before" was rendered from, so it is only redrawn when it
    /// would actually differ.
    private var renderedBefore: PhotoEditRecipe?
    private var renderedBeforeCrop: Bool?
    /// Which asset `input` was obtained for, so a commit can refuse a mismatch.
    /// The photo carries an edit made somewhere else.
    ///
    /// PhotoKit hands over the result rather than the original in that case, so
    /// nothing is lost — but the adjustments behind it cannot be read, and
    /// anything done here is layered on top of them rather than replacing them.
    @Published private(set) var hasForeignEdit = false

    private var inputAssetID: String?

    /// Whether this session is still open on the photo it was started for.
    ///
    /// Anything that finishes after an `await` has to ask. The session outlives
    /// a single photo — moving to the next one re-begins it in place — so a
    /// result that arrives late would otherwise be written into whichever
    /// photo happens to be open when it lands.
    func isOpen(on assetID: String) -> Bool { inputAssetID == assetID }
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

        hasForeignEdit = item.asset.adjustmentsState != .none && loadedRecipe == .neutral
            && Self.decode(loaded.adjustmentData) == nil

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
        renderedBefore = nil
        renderedBeforeCrop = nil
        recipe = .neutral
        loadedRecipe = .neutral
        hasExistingEdit = false
        hasForeignEdit = false
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
            renderedBefore = nil
            return
        }

        // The "before" depends on the recipe as loaded and the current crop,
        // neither of which changes while a slider moves. Without this it would
        // be redrawn on every frame of every drag, doubling the cost of the
        // preview for an image that is identical each time.
        let wanted = beforeRecipe
        guard beforePreview == nil
                || renderedBefore != wanted
                || renderedBeforeCrop != applyCrop else { return }

        let before = wanted.apply(to: previewBase, applyCrop: applyCrop)
        if let cgImage = context.createCGImage(before, from: before.extent) {
            beforePreview = PlatformImage.from(cgImage)
            renderedBefore = wanted
            renderedBeforeCrop = applyCrop
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

    /// Puts the recipe back to how the photo was when the session opened.
    ///
    /// Used after a treatment is saved as a separate photo: the changes have
    /// gone somewhere, and leaving them applied to the original would mean the
    /// next save — or simply walking to the next photo — altered it too.
    func discardChanges() {
        recipe = loadedRecipe
        renderPreview(applyCrop: pendingApplyCrop)
    }

    // MARK: - White balance

    /// Reads the colour at a point and stores it as the neutral reference.
    ///
    /// Averaged over a small patch rather than taken from one pixel: a single
    /// pixel carries sensor noise, and a white balance set from noise is a
    /// white balance set from nothing. Sampled from the unedited image, so the
    /// reference describes the light in the photograph and not the adjustments
    /// already made to it.
    @discardableResult
    func sampleWhitePoint(at point: EditPoint, into target: MaskTarget = .whole) -> Bool {
        guard let previewBase else { return false }
        let extent = previewBase.extent
        guard extent.width > 0, extent.height > 0 else { return false }

        let patch = max(2, min(extent.width, extent.height) * 0.02)
        let centre = point.inPixels(of: extent)
        let region = CGRect(x: centre.x - patch / 2, y: centre.y - patch / 2,
                            width: patch, height: patch).intersection(extent)
        guard !region.isNull, region.width >= 1, region.height >= 1 else { return false }

        let average = CIFilter.areaAverage()
        average.inputImage = previewBase
        average.extent = region
        guard let output = average.outputImage else { return false }

        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(output,
                       toBitmap: &pixel,
                       rowBytes: 4,
                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8,
                       colorSpace: CGColorSpaceCreateDeviceRGB())

        let sampled = WhitePoint(red: Double(pixel[0]) / 255,
                                 green: Double(pixel[1]) / 255,
                                 blue: Double(pixel[2]) / 255)
        // Too dark to carry a usable ratio between channels.
        guard sampled.luminanceNormalized != nil else { return false }

        switch target {
        case .whole:
            recipe.tone.whitePoint = sampled
        case .mask(let id):
            guard let index = recipe.masks.firstIndex(where: { $0.id == id }) else { return false }
            recipe.masks[index].tone.whitePoint = sampled
        }
        renderPreview(applyCrop: pendingApplyCrop)
        return true
    }

    enum MaskTarget {
        case whole
        case mask(UUID)
    }

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
