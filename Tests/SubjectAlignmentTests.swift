import CoreImage
import Foundation
import Testing

@testable import LightTable

/// Runs the real capture path against a real photograph and checks the mask
/// lands on the subject.
///
/// The unit tests cover the rasteriser with regions this file makes up, which
/// is why they all passed while the feature put the mask beside the aeroplane
/// rather than on it. The fault was upstream of anything they touched, so this
/// exercises the part they cannot: Vision's answer, encoded, stored, and
/// rasterised back.
///
/// Skipped when the photo is not on this machine.
@Suite("A selection lands on its subject")
struct SubjectAlignmentTests {
    static let photo = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Desktop/IMG_6112.DNG")

    /// Centre of mass of everything bright, in top-left normalized terms.
    static func centroid(of image: CIImage, threshold: UInt8 = 128) -> CGPoint? {
        let extent = image.extent
        let width = Int(extent.width)
        let height = Int(extent.height)
        guard width > 0, height > 0 else { return nil }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        CIContext().render(image, toBitmap: &pixels, rowBytes: width * 4,
                           bounds: extent, format: .RGBA8,
                           colorSpace: CGColorSpaceCreateDeviceRGB())

        var sumX = 0.0, sumY = 0.0, count = 0.0
        for y in 0..<height {
            for x in 0..<width where pixels[(y * width + x) * 4] > threshold {
                sumX += Double(x)
                // Rendered bottom-up; reported top-down, as a person would.
                sumY += Double(height - 1 - y)
                count += 1
            }
        }
        guard count > 0 else { return nil }
        return CGPoint(x: sumX / count / Double(width),
                       y: sumY / count / Double(height))
    }

    @Test("The stored region covers the subject that was tapped")
    func alignsWithTheSubject() async throws {
        try #require(FileManager.default.fileExists(atPath: Self.photo.path),
                     "IMG_6112.DNG is not on this machine")
        let raw = try #require(CIRAWFilter(imageURL: Self.photo)?.outputImage)

        // Where the aeroplane is in this photograph, in top-left terms.
        let tap = CGPoint(x: 0.583, y: 0.513)
        let region = try await SubjectMask.region(in: raw, at: tap)

        var mask = EditMask()
        mask.kind = .brush
        mask.softness = 0
        mask.region = region

        // Rasterised the way a render does it, at the photo's own extent.
        let rendered = try #require(mask.maskImage(for: raw.extent))
        let centre = try #require(Self.centroid(of: rendered))

        // The aeroplane occupies a small part of the frame, so its centre of
        // mass should be close to where the tap was. Anywhere else means the
        // mask is on the wrong part of the picture — which is what a second,
        // floating aeroplane looks like.
        let drift = hypot(centre.x - tap.x, centre.y - tap.y)
        #expect(drift < 0.10,
                "mask centred at \(centre), tapped at \(tap) — adrift by \(drift)")
    }

    @Test("The stored region has the photograph's shape")
    func regionKeepsTheAspect() async throws {
        // The failure this exists for: a region stored at 9:16 for a 3:4
        // photograph. The silhouette inside it was perfect, so nothing looked
        // wrong until it was stretched onto the frame — 0.5625 being 0.75
        // squared, the photo's own aspect applied a second time.
        try #require(FileManager.default.fileExists(atPath: Self.photo.path),
                     "IMG_6112.DNG is not on this machine")
        let raw = try #require(CIRAWFilter(imageURL: Self.photo)?.outputImage)

        let scale = 1400 / max(raw.extent.width, raw.extent.height)
        let small = raw.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let cgPreview = try #require(CIContext().createCGImage(small, from: small.extent))
        let roundTripped = try #require(CIImage.from(PlatformImage.from(cgPreview)))

        // The conversion itself has to keep the shape, whatever it does to the
        // resolution.
        let photoAspect = raw.extent.width / raw.extent.height
        let previewAspect = roundTripped.extent.width / roundTripped.extent.height
        #expect(abs(previewAspect - photoAspect) < 0.01,
                "the preview came back at \(previewAspect), photo is \(photoAspect)")

        let region = try await SubjectMask.region(in: roundTripped,
                                                  at: CGPoint(x: 0.583, y: 0.513))
        let stored = try #require(region.decoded())
        let storedAspect = CGFloat(stored.width) / CGFloat(stored.height)
        #expect(abs(storedAspect - photoAspect) < 0.02,
                "region stored at \(storedAspect), photo is \(photoAspect)")
    }

    @Test("It still lands when captured from the preview, as the editor does")
    func alignsFromThePreview() async throws {
        try #require(FileManager.default.fileExists(atPath: Self.photo.path),
                     "IMG_6112.DNG is not on this machine")
        let raw = try #require(CIRAWFilter(imageURL: Self.photo)?.outputImage)

        // The editor never has the original in hand. It has a display-sized
        // preview, held as a PlatformImage and converted back for analysis —
        // the one link the other test skips, and where the picture picks up
        // whatever the platform's image types do to it.
        let scale = 1400 / max(raw.extent.width, raw.extent.height)
        let small = raw.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let cgPreview = try #require(CIContext().createCGImage(small, from: small.extent))
        let preview = PlatformImage.from(cgPreview)
        let roundTripped = try #require(CIImage.from(preview))

        let tap = CGPoint(x: 0.583, y: 0.513)
        let region = try await SubjectMask.region(in: roundTripped, at: tap)

        var mask = EditMask()
        mask.kind = .brush
        mask.softness = 0
        mask.region = region

        // Rasterised against the *full* photo, which is what a commit does:
        // the region is captured from a preview and used at full size.
        let rendered = try #require(mask.maskImage(for: raw.extent))
        let centre = try #require(Self.centroid(of: rendered))

        let drift = hypot(centre.x - tap.x, centre.y - tap.y)
        #expect(drift < 0.10,
                "mask centred at \(centre), tapped at \(tap) — adrift by \(drift)")
    }
}
