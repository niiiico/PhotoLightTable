import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

/// Picks a subject out of a photograph by tapping it.
///
/// `VNGenerateForegroundInstanceMaskRequest` is the subject lifting Photos uses
/// for "copy subject". Its `instanceMask` labels every pixel with the index of
/// the instance it belongs to, zero being background, so "which of these did
/// you mean" is a lookup rather than a guess — and several subjects in one
/// photograph cost nothing extra.
///
/// The result is turned into a stored `MaskRegion` immediately. Nothing is
/// re-derived later: the selection becomes an ordinary part of a brush mask, to
/// be added to and taken away from with the brush, and no future version of the
/// model can change an edit already made.
enum SubjectMask {
    /// The long edge of what gets stored.
    ///
    /// Vision analyses at 512 and upscales, so anything larger would be storing
    /// an interpolation of its answer rather than the answer.
    static let storedSize: CGFloat = 512

    enum Failure: LocalizedError {
        case noSubjects
        case nothingAtThatPoint

        var errorDescription: String? {
            switch self {
            case .noSubjects:
                return "Nothing in this photo stands out from its background."
            case .nothingAtThatPoint:
                return "That looks like background — tap the subject itself."
            }
        }
    }

    /// Finds the subject under a normalized, top-left point.
    static func region(in image: CIImage, at point: CGPoint) async throws -> MaskRegion {
        try await Task.detached(priority: .userInitiated) { () -> MaskRegion in
            let handler = VNImageRequestHandler(ciImage: image, options: [:])
            let request = VNGenerateForegroundInstanceMaskRequest()
            try handler.perform([request])

            guard let observation = request.results?.first,
                  !observation.allInstances.isEmpty else {
                throw Failure.noSubjects
            }

            let index = instance(in: observation, at: point)
            guard index != 0 else { throw Failure.nothingAtThatPoint }

            let mask = try observation.generateScaledMaskForImage(forInstances: [Int(index)],
                                                                  from: handler)
            return try encode(CIImage(cvPixelBuffer: mask), fitting: image.extent)
        }.value
    }

    /// Which instance sits under the point.
    ///
    /// The mask comes back square whatever the photo's shape, and a normalized
    /// coordinate lands in the right place regardless — it is the whole frame
    /// squashed, not letterboxed, which was checked rather than assumed.
    private static func instance(in observation: VNInstanceMaskObservation,
                                 at point: CGPoint) -> UInt8 {
        let buffer = observation.instanceMask
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return 0 }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)

        let x = min(max(Int(point.x * CGFloat(width)), 0), width - 1)
        let y = min(max(Int(point.y * CGFloat(height)), 0), height - 1)
        return base.advanced(by: y * rowBytes + x)
            .assumingMemoryBound(to: UInt8.self).pointee
    }

    /// Scales the mask down to what gets stored and encodes it.
    private static func encode(_ mask: CIImage, fitting extent: CGRect) throws -> MaskRegion {
        let longest = max(extent.width, extent.height)
        let scale = longest > 0 ? min(1, storedSize / longest) : 1
        let target = CGRect(x: 0, y: 0,
                            width: max(1, (extent.width * scale).rounded()),
                            height: max(1, (extent.height * scale).rounded()))

        // Fitted to the photo's own shape, so the stored region carries the
        // proportions and the rasteriser can simply stretch it to the frame.
        let fitted = mask
            .transformed(by: CGAffineTransform(scaleX: target.width / mask.extent.width,
                                               y: target.height / mask.extent.height))
            .cropped(to: target)

        let context = CIContext()
        guard let data = context.pngRepresentation(of: fitted,
                                                   format: .L8,
                                                   colorSpace: CGColorSpaceCreateDeviceGray()) else {
            throw Failure.noSubjects
        }
        return MaskRegion(png: data)
    }
}
