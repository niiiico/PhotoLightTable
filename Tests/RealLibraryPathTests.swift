import CoreImage
import Foundation
import Photos
import Testing

@testable import LightTable

/// Measures the real path, against the real library, at each step a photograph
/// takes on its way to becoming a mask.
///
/// A subject mask was stored with the wrong shape twice, and every unit test
/// passed both times, because each of them supplied its own image. These
/// supply nothing: they ask PhotoKit for a photo, open a session on it, and
/// check the shape survives from the asset to the display image to the
/// rendered preview to the stored region.
///
/// They skip when the library is unavailable, so they are worth little on
/// another machine — but the failures they exist for were invisible to every
/// test that made up its own input.
@Suite("The path a photo takes to become a mask", .serialized)
struct RealLibraryPathTests {
    @Test("The display-size image keeps the photograph's shape")
    func displaySizeImageAspect() async throws {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        try #require(status == .authorized || status == .limited,
                     "no photo library access in this run")

        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        options.fetchLimit = 4
        let assets = PHAsset.fetchAssets(with: options)
        try #require(assets.count > 0, "no photos in the library")

        for index in 0..<assets.count {
            let asset = assets.object(at: index)
            let assetAspect = CGFloat(asset.pixelWidth) / CGFloat(asset.pixelHeight)

            let input = await PhotoEditSession.loadInput(for: asset)
            guard let input, let display = input.displaySizeImage else { continue }

            let displayAspect = display.size.width / display.size.height
            let converted = try #require(CIImage.from(display))
            let convertedAspect = converted.extent.width / converted.extent.height

            print("MEASURED asset \(asset.pixelWidth)x\(asset.pixelHeight) a=\(assetAspect) | display \(display.size) a=\(displayAspect) | converted \(converted.extent.size) a=\(convertedAspect)")

            #expect(abs(displayAspect - assetAspect) < 0.02,
                    "PhotoKit's display image is \(displayAspect), asset is \(assetAspect)")
            #expect(abs(convertedAspect - assetAspect) < 0.02,
                    "converted to \(convertedAspect), asset is \(assetAspect)")
        }
    }

    @MainActor
    @Test("The rendered preview keeps the photograph's shape")
    func renderedPreviewAspect() async throws {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        try #require(status == .authorized || status == .limited,
                     "no photo library access in this run")

        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        options.fetchLimit = 1
        let assets = PHAsset.fetchAssets(with: options)
        try #require(assets.count > 0, "no photos in the library")

        let asset = assets.object(at: 0)
        let assetAspect = CGFloat(asset.pixelWidth) / CGFloat(asset.pixelHeight)

        // The preview is what the tap is measured against and what is handed to
        // Vision — not the display-size image, and not the original.
        let session = PhotoEditSession()
        await session.begin(for: PhotoItem(asset: asset))

        for _ in 0..<80 where session.preview == nil {
            try? await Task.sleep(for: .milliseconds(50))
        }
        let preview = try #require(session.preview, "the preview never rendered")

        let previewAspect = preview.size.width / preview.size.height
        let converted = try #require(CIImage.from(preview))
        let convertedAspect = converted.extent.width / converted.extent.height

        print("MEASURED asset \(asset.pixelWidth)x\(asset.pixelHeight) a=\(assetAspect) | preview \(preview.size) a=\(previewAspect) | converted \(converted.extent.size) a=\(convertedAspect)")

        #expect(abs(previewAspect - assetAspect) < 0.02,
                "the preview is \(previewAspect), asset is \(assetAspect)")
        #expect(abs(convertedAspect - assetAspect) < 0.02,
                "converted to \(convertedAspect), asset is \(assetAspect)")
    }

    @MainActor
    @Test("A region captured through the real path keeps the photo's shape")
    func regionThroughTheRealPath() async throws {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        try #require(status == .authorized || status == .limited,
                     "no photo library access in this run")

        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        options.fetchLimit = 400
        let assets = PHAsset.fetchAssets(with: options)
        try #require(assets.count > 0, "no photos in the library")

        var checked = 0
        for index in 0..<assets.count where checked < 3 {
            let asset = assets.object(at: index)
            let assetAspect = CGFloat(asset.pixelWidth) / CGFloat(asset.pixelHeight)
            // Landscape 4:3 — the shape the reported failures were on. The
            // first photos in the library are all 9:16 and pass happily.
            guard assetAspect > 1.2, assetAspect < 1.4 else { continue }

            let session = PhotoEditSession()
            await session.begin(for: PhotoItem(asset: asset))
            for _ in 0..<80 where session.preview == nil {
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard let preview = session.preview,
                  let source = CIImage.from(preview) else { continue }

            // Exactly what the editor does when the photo is tapped.
            guard let region = try? await SubjectMask.region(
                in: source, at: CGPoint(x: 0.5, y: 0.5)),
                  let decoded = region.decoded() else { continue }

            let regionAspect = CGFloat(decoded.width) / CGFloat(decoded.height)
            print("MEASURED asset a=\(assetAspect) | source \(source.extent.size) | region \(decoded.width)x\(decoded.height) a=\(regionAspect)")
            #expect(abs(regionAspect - assetAspect) < 0.02,
                    "region \(regionAspect) vs asset \(assetAspect)")
            checked += 1
        }
    }
}
