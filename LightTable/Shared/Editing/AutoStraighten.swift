import CoreImage
import Foundation
import Vision

/// Finds how far a photo's horizon is off level.
///
/// `VNDetectHorizonRequest` has been in Vision since macOS 10.13 and does the
/// whole job: it looks for the dominant horizon and reports the angle that
/// would upright it.
enum AutoStraighten {
    /// Degrees to put into `PhotoEditRecipe.straighten`, or nil when no horizon
    /// could be found.
    ///
    /// **The sign is measured, not assumed.** The header says only "use the
    /// transform or angle to upright the image", so it was checked against
    /// drawn horizons of known tilt: Vision reports the negative of the tilt,
    /// which is already the correction, so the angle goes in as it comes out.
    /// Guessing this wrong would have doubled a tilt rather than removing it,
    /// and looked plausible on any nearly-level photo.
    ///
    /// A level photo returns **nil rather than zero**: Vision finds no horizon
    /// in one, which is indistinguishable from finding no horizon in a portrait
    /// of a wall. The caller decides what to say about that; this cannot tell
    /// the two apart.
    static func angle(in image: CIImage) async -> Double? {
        await Task.detached(priority: .userInitiated) { () -> Double? in
            let request = VNDetectHorizonRequest()
            let handler = VNImageRequestHandler(ciImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                return nil
            }
            guard let observation = request.results?.first else { return nil }

            let degrees = Double(observation.angle) * 180 / .pi
            // Beyond the slider's own range it is not a horizon that is out by
            // a little — it is a photo taken at an angle on purpose, and
            // levelling it would be a guess about intent.
            guard PhotoEditRecipe.straightenRange.contains(degrees) else { return nil }
            return degrees
        }.value
    }
}
