#!/usr/bin/env swift

/// Removes a window reflection from the sky region of a RAW photo.
///
/// The method rests on one fact: a reflection only ever *adds* light, so
///
///     observed = sky + reflection,  reflection >= 0
///
/// which means the true sky is the **lower envelope** of what was recorded, not
/// its average. Blurring the sky to model it fails, because the blur is dragged
/// upward by the very thing being removed. Instead a smooth polynomial surface
/// is fitted to the low side of the data — residuals above the model are
/// downweighted as "probably reflection", residuals below it are trusted — and
/// what does not fit the surface is the reflection.
///
/// All arithmetic is done in linear light. A reflection is a sum of photons, so
/// subtracting it is only correct on linear values; doing it on gamma-encoded
/// data produces grey mush. The real feature would insert this into
/// `CIRAWFilter.linearSpaceFilter`; this prototype instead renders the RAW into
/// a linear colour space and works on the pixels directly, which is easier to
/// reason about and to inspect.
///
/// The sky mask comes from the capture's own `semanticSegmentationSkyMatte`, so
/// nothing outside the sky is touched.
///
/// Usage:
///   swift reflection-fix.swift <input.dng> <output.tiff> [strength] [degree]
///
///   strength  how much of the detected reflection to remove, 0...1 (default 1)
///   degree    polynomial degree of the sky model (default 3)

import Accelerate
import CoreImage
import Foundation

// MARK: - Arguments

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("usage: swift reflection-fix.swift <input.dng> <output.tiff> [strength] [degree]")
    exit(1)
}

let inputURL = URL(fileURLWithPath: args[1])
let outputURL = URL(fileURLWithPath: args[2])
let strength = args.count > 3 ? Float(args[3]) ?? 1.0 : 1.0
let degree = args.count > 4 ? Int(args[4]) ?? 3 : 3

// MARK: - Decode the RAW into linear light

guard let raw = CIRAWFilter(imageURL: inputURL) else {
    print("Not a RAW file Core Image can open: \(inputURL.lastPathComponent)")
    exit(1)
}

// If the reflection pushed the sky to clipping, that information is gone and no
// subtraction recovers it. This buys back what there is to buy.
if raw.isHighlightRecoverySupported {
    raw.isHighlightRecoveryEnabled = true
}

guard let image = raw.outputImage else {
    print("Could not decode \(inputURL.lastPathComponent)")
    exit(1)
}
guard let matte = raw.semanticSegmentationSkyMatte else {
    print("No sky matte in this file — this prototype needs one.")
    exit(1)
}

let extent = image.extent
let width = Int(extent.width)
let height = Int(extent.height)

// `outputImage` has the capture's orientation applied; the auxiliary mattes do
// **not**. On this photo (orientation 3, shot upside down) that put the mask
// 180° out from the image — the not-sky band sat over the sky and vice versa.
// An aspect-ratio check cannot catch it, since 180° preserves aspect, so the
// orientation has to be applied deliberately rather than assumed to match.
print("Orientation \(raw.orientation.rawValue) applied to the matte.")
let orientedMatte = matte.oriented(raw.orientation)

// Half resolution, so it is scaled up to the image's geometry.
let scaledMatte = orientedMatte.transformed(by: CGAffineTransform(
    scaleX: extent.width / orientedMatte.extent.width,
    y: extent.height / orientedMatte.extent.height))

/// Linear, so that a subtraction means what it says.
let linearSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
let context = CIContext(options: [.workingColorSpace: linearSpace,
                                  .outputColorSpace: linearSpace])

let pixelCount = width * height
var pixels = [Float](repeating: 0, count: pixelCount * 4)
var maskPixels = [Float](repeating: 0, count: pixelCount * 4)

pixels.withUnsafeMutableBytes { buffer in
    context.render(image,
                   toBitmap: buffer.baseAddress!,
                   rowBytes: width * 16,
                   bounds: extent,
                   format: .RGBAf,
                   colorSpace: linearSpace)
}
// Deliberately unmanaged: the matte is a coverage fraction, not a colour.
// Rendering it through a colour space linearizes it as if it were sRGB, which
// silently turns a coverage of 0.5 into about 0.21 — the mask then reads as far
// less sky than there is, and every edge is weighted wrongly.
maskPixels.withUnsafeMutableBytes { buffer in
    context.render(scaledMatte,
                   toBitmap: buffer.baseAddress!,
                   rowBytes: width * 16,
                   bounds: extent,
                   format: .RGBAf,
                   colorSpace: nil)
}

// A heavily blurred copy of the matte, to divide the sharp one by.
//
// The matte's confidence drifts across the frame — high over the clean left,
// collapsing over the reflected right — so no single threshold can mean "sky"
// everywhere. Dividing by the local average removes that drift while keeping
// local contrast, which is where the real information is: the aeroplane is a
// sharp dip against its surroundings, the right-hand side is uniformly low.
// Clamping first stops the blur from darkening the frame's edges.
let blurredMatte = scaledMatte
    .clampedToExtent()
    .applyingGaussianBlur(sigma: 200)
    .cropped(to: extent)

var blurPixels = [Float](repeating: 0, count: pixelCount * 4)
blurPixels.withUnsafeMutableBytes { buffer in
    context.render(blurredMatte,
                   toBitmap: buffer.baseAddress!,
                   rowBytes: width * 16,
                   bounds: extent,
                   format: .RGBAf,
                   colorSpace: nil)
}

print("Decoded \(width) x \(height) in linear light.")

// MARK: - The sky model

/// Terms of a 2D polynomial of the given degree, evaluated at normalized
/// coordinates. Degree 3 gives 10 terms — enough to follow a real sky's
/// gradient and the lens's falloff, too stiff to bend around a building.
func basis(x: Float, y: Float, degree: Int) -> [Float] {
    var terms: [Float] = []
    for total in 0...degree {
        for i in 0...total {
            terms.append(powf(x, Float(total - i)) * powf(y, Float(i)))
        }
    }
    return terms
}

let termCount = basis(x: 0, y: 0, degree: degree).count

/// Solves `A · coefficients = b` for a small symmetric system by Gaussian
/// elimination with partial pivoting.
func solve(_ A: [[Double]], _ b: [Double]) -> [Double]? {
    var a = A
    var rhs = b
    let n = b.count

    for column in 0..<n {
        var pivot = column
        for row in (column + 1)..<n where abs(a[row][column]) > abs(a[pivot][column]) {
            pivot = row
        }
        guard abs(a[pivot][column]) > 1e-12 else { return nil }
        a.swapAt(column, pivot)
        rhs.swapAt(column, pivot)

        for row in (column + 1)..<n {
            let factor = a[row][column] / a[column][column]
            guard factor != 0 else { continue }
            for k in column..<n {
                a[row][k] -= factor * a[column][k]
            }
            rhs[row] -= factor * rhs[column]
        }
    }

    var result = [Double](repeating: 0, count: n)
    for row in stride(from: n - 1, through: 0, by: -1) {
        var sum = rhs[row]
        for k in (row + 1)..<n {
            sum -= a[row][k] * result[k]
        }
        result[row] = sum / a[row][row]
    }
    return result
}

/// Sampling stride for the fit. The sky model is low-frequency by construction,
/// so a fraction of the pixels determines it just as well and much faster.
let sampleStride = max(1, min(width, height) / 400)

/// Remaps the matte's raw confidence into a usable coverage.
///
/// The matte is a soft confidence map, not a clean mask: on this photo it peaks
/// at 0.84 and only 4.5% of it exceeds 0.5. Crucially the segmenter is *least*
/// confident exactly where the reflection is strongest — so thresholding high
/// would discard precisely the region that needs fixing. The knee is therefore
/// low, and the robust fit is left to deal with the reflection.
func remap(_ value: Float, _ low: Float, _ high: Float) -> Float {
    min(max((value - low) / (high - low), 0), 1)
}

/// The matte relative to its own local average — "is this sky compared with its
/// surroundings", rather than "how sure is the segmenter in absolute terms".
///
/// This is what makes the right-hand side reachable. There the matte reads
/// uniformly low because the reflection is strongest there and the segmenter
/// loses confidence; but its *neighbourhood* is equally low, so the ratio is
/// near one and it is correctly treated as sky. The aeroplane, a sharp dip
/// against confident sky, stays near zero.
func localSkyness(at index: Int) -> Float {
    maskPixels[index] / max(blurPixels[index], 0.02)
}

/// Where the sky is trustworthy enough to *measure* from.
func fitCoverage(at index: Int) -> Float {
    remap(localSkyness(at: index), 0.55, 0.80)
}

/// Where the correction is *applied*: broader, and not attenuated by
/// confidence. The mask's job is only to say "this is sky, not aeroplane and
/// not trees"; how much to remove is the model's job.
func applyCoverage(at index: Int) -> Float {
    remap(localSkyness(at: index), 0.35, 0.60)
}

// MARK: - The sky region

var applyMask = [Float](repeating: 0, count: pixelCount)
for pixel in 0..<pixelCount {
    applyMask[pixel] = applyCoverage(at: pixel * 4)
}

/// Which end of the buffer holds the sky. Core Image's bitmap row order follows
/// its own bottom-left origin rather than the photo's, so this is measured
/// rather than assumed — the same class of mistake as the matte's orientation.
func meanCoverage(rows: Range<Int>) -> Float {
    var total: Float = 0
    var count = 0
    for y in rows {
        for x in Swift.stride(from: 0, to: width, by: 8) {
            total += applyMask[y * width + x]
            count += 1
        }
    }
    return count > 0 ? total / Float(count) : 0
}

let band = max(1, height / 10)
let skyAtRowZero = meanCoverage(rows: 0..<band) > meanCoverage(rows: (height - band)..<height)
print("Sky lies toward row \(skyAtRowZero ? 0 : height - 1) of the bitmap.")

// Everything past the skyline is cut, whatever the matte says about it. The
// parked aeroplane at the bottom of the frame sits below the treeline and is
// bright white, so the model read it as an enormous reflection and subtracted
// it — the mask has to exclude it on grounds of *position*, since on grounds of
// brightness it looks exactly like the thing being removed.
// Walked upward *from the ground edge*, not downward from the sky.
//
// Scanning from the sky end finds the aeroplane first — a legitimate hole in
// the sky — and treats everything below it as ground, which blanks a column
// straight through the middle of the frame. The ground is distinguished from
// the aeroplane not by being non-sky but by being **anchored to the bottom
// edge**, so that is what is tested.
let skyRunNeeded = max(8, height / 60)
var groundColumns = 0
for x in 0..<width {
    var skyRun = 0
    var groundEnds: Int?
    for step in 0..<height {
        // step 0 is the ground edge, walking toward the sky.
        let y = skyAtRowZero ? height - 1 - step : step
        if applyMask[y * width + x] > 0.10 {
            skyRun += 1
            if skyRun >= skyRunNeeded {
                groundEnds = step - skyRun + 1
                break
            }
        } else {
            skyRun = 0
        }
    }
    // No sustained sky in this column at all: leave it alone rather than
    // cutting the whole column.
    guard let groundEnds, groundEnds > 0 else { continue }
    groundColumns += 1
    for step in 0..<groundEnds {
        let y = skyAtRowZero ? height - 1 - step : step
        applyMask[y * width + x] = 0
    }
}
print("Ground found below the skyline in \(groundColumns) of \(width) columns.")

struct Sample {
    let basis: [Float]
    let value: [Float]   // one per channel
    let weight: Float    // sky coverage, 0...1
}

var samples: [Sample] = []
for y in Swift.stride(from: 0, to: height, by: sampleStride) {
    for x in Swift.stride(from: 0, to: width, by: sampleStride) {
        let index = (y * width + x) * 4
        let coverage = min(fitCoverage(at: index), applyMask[y * width + x] > 0 ? 1 : 0)
        guard coverage > 0.5 else { continue }

        let nx = Float(x) / Float(width) * 2 - 1
        let ny = Float(y) / Float(height) * 2 - 1
        samples.append(Sample(basis: basis(x: nx, y: ny, degree: degree),
                              value: [pixels[index], pixels[index + 1], pixels[index + 2]],
                              weight: coverage))
    }
}

guard samples.count > termCount * 4 else {
    print("Only \(samples.count) sky samples — too little sky to fit a model to.")
    exit(1)
}

let skyFraction = Float(samples.count) / Float((width / sampleStride) * (height / sampleStride))
print("Sky covers roughly \(Int(skyFraction * 100))% of the frame "
      + "(\(samples.count) samples, \(termCount) coefficients).")

/// Fits one channel's sky surface, iteratively discounting samples that sit
/// *above* the model. Those are the reflection: it can only add light, so a
/// sample brighter than the fit is evidence of contamination, while a darker
/// one is evidence about the sky itself.
func fitChannel(_ channel: Int) -> [Double]? {
    var weights = samples.map { Double($0.weight) }
    var coefficients: [Double]?

    for iteration in 0..<12 {
        var normal = [[Double]](repeating: [Double](repeating: 0, count: termCount),
                                count: termCount)
        var rhs = [Double](repeating: 0, count: termCount)

        for (index, sample) in samples.enumerated() {
            let w = weights[index]
            guard w > 0 else { continue }
            let value = Double(sample.value[channel])
            for i in 0..<termCount {
                let bi = Double(sample.basis[i]) * w
                for j in i..<termCount {
                    normal[i][j] += bi * Double(sample.basis[j])
                }
                rhs[i] += bi * value
            }
        }
        // Mirror the upper triangle.
        for i in 0..<termCount {
            for j in 0..<i {
                normal[i][j] = normal[j][i]
            }
        }

        guard let fit = solve(normal, rhs) else { return coefficients }
        coefficients = fit
        guard iteration < 11 else { break }

        // Robust scale from the *negative* residuals only — those are the ones
        // the reflection cannot explain, so they measure the sky's own noise.
        var belowModel: [Double] = []
        var residuals = [Double](repeating: 0, count: samples.count)
        for (index, sample) in samples.enumerated() {
            var predicted = 0.0
            for i in 0..<termCount {
                predicted += fit[i] * Double(sample.basis[i])
            }
            let residual = Double(sample.value[channel]) - predicted
            residuals[index] = residual
            if residual < 0 { belowModel.append(-residual) }
        }
        belowModel.sort()
        let scale = max(belowModel.isEmpty ? 1e-4
                        : belowModel[belowModel.count / 2] * 1.4826, 1e-5)

        for index in samples.indices {
            let residual = residuals[index]
            let base = Double(samples[index].weight)
            if residual <= 0 {
                weights[index] = base
            } else {
                // Falls away smoothly, so a slightly-bright pixel still counts
                // for something and a clearly reflected one counts for nothing.
                let t = residual / (3 * scale)
                weights[index] = base / (1 + t * t)
            }
        }
    }
    return coefficients
}

var models: [[Double]] = []
for channel in 0..<3 {
    guard let fit = fitChannel(channel) else {
        print("The sky model would not converge on channel \(channel).")
        exit(1)
    }
    models.append(fit)
}

// MARK: - Subtract

// How far above the sky model things sit, as a fraction of the model. A veil is
// a modest addition — the sky is still visible through it — while a sunlit white
// aeroplane is several times brighter than the sky behind it. Measured before
// choosing where to cut, rather than guessed.
var ratios: [Float] = []
for y in Swift.stride(from: 0, to: height, by: 4) {
    let ny = Float(y) / Float(height) * 2 - 1
    for x in Swift.stride(from: 0, to: width, by: 4) {
        let index = (y * width + x) * 4
        guard applyMask[y * width + x] > 0.5 else { continue }
        let terms = basis(x: Float(x) / Float(width) * 2 - 1, y: ny, degree: degree)
        var predicted = 0.0
        for i in 0..<termCount { predicted += models[1][i] * Double(terms[i]) }
        guard predicted > 0.001 else { continue }
        ratios.append((pixels[index + 1] - Float(predicted)) / Float(predicted))
    }
}
ratios.sort()
func percentile(_ p: Double) -> Float {
    guard !ratios.isEmpty else { return 0 }
    return ratios[min(ratios.count - 1, max(0, Int(Double(ratios.count) * p)))]
}
print(String(format: "Excess over the sky model: p50 %+.2f  p90 %+.2f  p99 %+.2f  p99.9 %+.2f  max %+.2f",
             percentile(0.50), percentile(0.90), percentile(0.99),
             percentile(0.999), ratios.last ?? 0))

/// Nothing brighter than this multiple of the sky can be a reflection *of* the
/// sky's own brightness — beyond it, the pixel is an object seen through the
/// glass, not light added on top of it. Without this the aeroplane's thin white
/// wing, which the half-resolution matte does not cover, is subtracted away
/// entirely: it is far brighter than the sky, so it reads as an enormous
/// reflection.
let excessCap = percentile(0.999)
print(String(format: "Removal capped at %+.2f x the sky level.", excessCap))

var removedTotal = 0.0
var removedPeak: Float = 0
var affected = 0
var cappedPixels = 0

// Diagnostics, written alongside the result: where the correction was allowed
// to act, and how much it actually removed. Guessing at either from the output
// alone is how the last two rounds of parameter-fiddling went wrong.
var maskViz = [Float](repeating: 0, count: pixelCount * 4)
var removedViz = [Float](repeating: 0, count: pixelCount * 4)
/// The sky model itself, for comparing the removal against the level it is
/// removing from — a reflection is a modest addition to the sky, a white
/// aeroplane is many times brighter than it.
var modelViz = [Float](repeating: 0, count: pixelCount * 4)

for y in 0..<height {
    let ny = Float(y) / Float(height) * 2 - 1
    for x in 0..<width {
        let index = (y * width + x) * 4
        let coverage = applyMask[y * width + x]

        let nx = Float(x) / Float(width) * 2 - 1
        let terms = basis(x: nx, y: ny, degree: degree)

        var pixelRemoved: Float = 0
        var meanModel: Float = 0
        for channel in 0..<3 {
            var predicted = 0.0
            for i in 0..<termCount {
                predicted += models[channel][i] * Double(terms[i])
            }
            meanModel += Float(predicted) / 3

            guard coverage > 0.01 else { continue }
            let observed = pixels[index + channel]
            // Only ever removes light, never adds it: a pixel darker than the
            // model is sky the model got slightly wrong, not negative
            // reflection.
            let reflection = max(0, observed - Float(predicted))
            let ceiling = Float(predicted) * excessCap
            if reflection > ceiling { cappedPixels += 1 }
            let removed = min(reflection, ceiling) * strength * coverage
            pixels[index + channel] = observed - removed
            pixelRemoved = max(pixelRemoved, removed)
        }

        for channel in 0..<3 {
            maskViz[index + channel] = coverage
            // Exaggerated, since a veil is a small linear quantity and would
            // otherwise be invisible in the diagnostic.
            removedViz[index + channel] = min(pixelRemoved * 4, 1)
            modelViz[index + channel] = meanModel
        }
        maskViz[index + 3] = 1
        removedViz[index + 3] = 1
        modelViz[index + 3] = 1

        if pixelRemoved > 0.001 {
            affected += 1
            removedTotal += Double(pixelRemoved)
            removedPeak = max(removedPeak, pixelRemoved)
        }
    }
}

print("Removed something from \(affected) pixels "
      + "(\(Int(Double(affected) / Double(pixelCount) * 100))% of the frame).")
print(String(format: "Peak removed: %.4f linear; mean over affected: %.4f",
             removedPeak, affected > 0 ? removedTotal / Double(affected) : 0))

// MARK: - Write it out

let corrected = pixels.withUnsafeMutableBufferPointer { buffer -> CIImage in
    let data = Data(buffer: buffer)
    return CIImage(bitmapData: data,
                   bytesPerRow: width * 16,
                   size: CGSize(width: width, height: height),
                   format: .RGBAf,
                   colorSpace: linearSpace)
}

// Back to a display-referred space on the way out, so the TIFF looks like the
// photo rather than like linear data.
let outputSpace = CGColorSpace(name: CGColorSpace.sRGB)!
do {
    try context.writeTIFFRepresentation(of: corrected,
                                        to: outputURL,
                                        format: .RGBA8,
                                        colorSpace: outputSpace)
    print("Wrote \(outputURL.path)")
} catch {
    print("Could not write the result: \(error)")
    exit(1)
}

/// Writes a diagnostic beside the output, downscaled for looking at.
func writeDiagnostic(_ buffer: inout [Float], suffix: String) {
    let image = buffer.withUnsafeMutableBufferPointer { pointer -> CIImage in
        CIImage(bitmapData: Data(buffer: pointer),
                bytesPerRow: width * 16,
                size: CGSize(width: width, height: height),
                format: .RGBAf,
                colorSpace: linearSpace)
    }
    let scale = 1400.0 / Double(width)
    let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    let url = outputURL.deletingPathExtension()
        .appendingPathExtension(suffix)
        .appendingPathExtension("jpg")
    try? context.writeJPEGRepresentation(of: scaled, to: url, colorSpace: outputSpace)
    print("Wrote \(url.lastPathComponent)")
}

writeDiagnostic(&maskViz, suffix: "mask")
writeDiagnostic(&removedViz, suffix: "removed")
writeDiagnostic(&modelViz, suffix: "model")
