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
/// Skipped wholesale without a photo library, which makes them close to
/// worthless on another machine. That is the trade: the failures they exist for
/// were invisible to every test that made up its own input.
private var hasLibraryAccess: Bool {
    let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    return status == .authorized || status == .limited
}

@Suite("The path a photo takes to become a mask", .serialized,
       .enabled(if: hasLibraryAccess))
struct RealLibraryPathTests {
    @Test("The display-size image keeps the photograph's shape")
    func displaySizeImageAspect() async throws {
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
            guard assetAspect > 0.7, assetAspect < 0.8 else { continue }

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

    @MainActor
    @Test("The loupe's own image keeps the photograph's shape")
    func loupeImageAspect() async throws {
        // What the editor falls back to when the preview has not rendered yet.
        // It is requested with a *square* target size and resizeMode .exact,
        // which is a very different question to ask PhotoKit than the one the
        // preview asks.
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        options.fetchLimit = 400
        let assets = PHAsset.fetchAssets(with: options)

        var checked = 0
        for index in 0..<assets.count where checked < 2 {
            let asset = assets.object(at: index)
            let aspect = CGFloat(asset.pixelWidth) / CGFloat(asset.pixelHeight)
            guard aspect > 0.7, aspect < 0.8 else { continue }

            guard let image = await ThumbnailLoader.shared.fullImage(
                for: PhotoItem(asset: asset), maxDimension: 2400) else { continue }
            let converted = try #require(CIImage.from(image))

            print("MEASURED loupe asset a=\(aspect) | image \(image.size) | converted \(converted.extent.size) a=\(converted.extent.width / converted.extent.height)")
            #expect(abs(converted.extent.width / converted.extent.height - aspect) < 0.02,
                    "loupe image is \(converted.extent.size) for a \(aspect) photo")
            checked += 1
        }
    }

    @MainActor
    @Test("A variant is built from the same picture the mask was drawn on")
    func variantBaseMatchesThePreview() async throws {
        // The invariant that was broken. A mask is placed against the image the
        // editor shows; a variant is built from `fullSizeImageURL` and the
        // recipe applied to it. If those two are different shapes — as they are
        // for a photo already cropped in Photos.app, where the editor sees the
        // render and the resource is still the original — the mask is stretched
        // onto the wrong frame and lands beside its subject.
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        options.fetchLimit = 400
        let assets = PHAsset.fetchAssets(with: options)

        var checked = 0
        for index in 0..<assets.count where checked < 6 {
            let asset = assets.object(at: index)
            guard let input = await PhotoEditSession.loadInput(for: asset),
                  let display = input.displaySizeImage,
                  let url = input.fullSizeImageURL else { continue }

            let base: CIImage?
            if let raw = CIRAWFilter(imageURL: url) {
                raw.orientation = CGImagePropertyOrientation(
                    rawValue: UInt32(input.fullSizeImageOrientation)) ?? .up
                base = raw.outputImage
            } else {
                base = CIImage(contentsOf: url)?
                    .oriented(forExifOrientation: input.fullSizeImageOrientation)
            }
            guard let base else { continue }

            let shown = display.size.width / display.size.height
            let built = base.extent.width / base.extent.height
            print("MEASURED base shown a=\(shown) | built a=\(built) | \(asset.localIdentifier.prefix(8))")
            #expect(abs(shown - built) < 0.02,
                    "the editor shows \(shown) but a variant would be built from \(built)")
            checked += 1
        }
    }

    /// Opt-in: it writes to the real photo library and then removes what it
    /// wrote, and on macOS `deleteAssets` puts up a confirmation the test host
    /// cannot answer — so an ordinary run hangs on a dialog nobody is looking
    /// at. Skipped is the right shape; failing every run would just be noise.
    ///
    ///     LIGHTTABLE_LIVE_TESTS=1 xcodebuild test -scheme LightTable \
    ///         -destination platform=macOS \
    ///         -only-testing:LightTableTests/RealLibraryPathTests
    @MainActor
    @Test("Making a variant of a real photo actually succeeds",
          .enabled(if: ProcessInfo.processInfo.environment["LIGHTTABLE_LIVE_TESTS"] == "1"))
    func variantCreationSucceeds() async throws {
        // Opt-in, because it writes to the real photo library and then removes
        // what it wrote — and on macOS `deleteAssets` puts up a confirmation
        // the test host cannot answer, so an ordinary run hangs on a dialog
        // nobody is looking at. Run it deliberately:
        //
        //     LIGHTTABLE_LIVE_TESTS=1 xcodebuild test -scheme LightTable \
        //         -destination platform=macOS \
        //         -only-testing:LightTableTests/RealLibraryPathTests
        //
        // and click through the prompt.

        // PHPhotosErrorInvalidResource, 3302: the resource set has to describe
        // a photograph that could exist. Pairing a rendered base with the
        // original's RAW sibling or Live Photo video does not, and no amount of
        // geometry checking catches a request PhotoKit simply refuses.
        //
        // This makes a real photo in the library and removes it again.
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        options.fetchLimit = 1
        let assets = PHAsset.fetchAssets(with: options)
        try #require(assets.count > 0, "no photos in the library")

        var recipe = PhotoEditRecipe()
        recipe.tone.exposure = 0.2

        let item = PhotoItem(asset: assets.object(at: 0))
        let newID = try await PhotoVariants.create(from: item,
                                                   applying: recipe,
                                                   label: "TestVariant",
                                                   context: nil,
                                                   library: nil)
        #expect(!newID.isEmpty)

        // Cleaned up, so running the tests does not litter the library.
        if let created = PHAsset.fetchAssets(withLocalIdentifiers: [newID], options: nil).firstObject {
            try? await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets([created] as NSArray)
            }
        }
    }

    @MainActor
    @Test("What the editor gets for a photo edited somewhere else")
    func foreignEditBase() async throws {
        // Photos edited years ago in another app show up now that families are
        // detected. The question is what the editor is handed for one: the
        // result of that edit, or the original underneath it. The wording of
        // any warning depends on the answer, so it is measured.
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        options.fetchLimit = 600
        let assets = PHAsset.fetchAssets(with: options)

        var found = 0
        for index in 0..<assets.count where found < 4 {
            let asset = assets.object(at: index)
            guard asset.adjustmentsState != .none else { continue }

            guard let input = await PhotoEditSession.loadInput(for: asset),
                  let url = input.fullSizeImageURL else { continue }
            let ours = PhotoEditSession.decode(input.adjustmentData) != nil

            let resource = PHAssetResource.assetResources(for: asset)
                .first { $0.type == .photo }
            let source = CGImageSourceCreateWithURL(url as CFURL, nil)
            let properties = source.flatMap {
                CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any]
            }
            let baseWidth = properties?[kCGImagePropertyPixelWidth] as? Int ?? -1
            let baseHeight = properties?[kCGImagePropertyPixelHeight] as? Int ?? -1

            // The finding this pins: for an edit this app cannot read, PhotoKit
            // hands over the *result* rather than the original underneath it —
            // the base matches the asset's current size, not the resource's. So
            // opening such a photo keeps the old work rather than discarding
            // it; what is lost is the parameters, not the picture.
            #expect(!ours, "expected a foreign edit")
            #expect(baseWidth == asset.pixelWidth && baseHeight == asset.pixelHeight,
                    "base \(baseWidth)x\(baseHeight) is not the edited photo \(asset.pixelWidth)x\(asset.pixelHeight)")
            _ = resource
            found += 1
        }
    }
}
