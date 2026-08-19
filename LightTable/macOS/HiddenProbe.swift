#if os(macOS)
import Photos
import SwiftUI

/// An experiment on one photograph: hide it, then see what is left of it.
///
/// Whether a photograph stays reachable by identifier once Photos hides it
/// decides whether anything can be built on identifiers captured before the
/// fact. Apple's header says `fetchAssets(withLocalIdentifiers:)` "includes
/// hidden assets by default", but that sentence predates the Hidden album being
/// locked, and every other read this app has tried has come back empty.
///
/// Debug only, one photograph, and it says which one so it can be put back.
enum HiddenProbe {
    /// Hides the newest photograph and reports what survives, in this process.
    static func hideNewest(in library: [PhotoItem]) {
        guard let item = library.first else {
            fputs("[hidden] nothing in the library to hide\n", stderr)
            return
        }
        let name = PHAssetResource.assetResources(for: item.asset).first?.originalFilename ?? "?"
        fputs("[hidden] hiding \(name), \(item.creationDate?.description ?? "no date")\n", stderr)
        fputs("[hidden] identifier \(item.id)\n", stderr)

        PHPhotoLibrary.shared().performChanges {
            let request = PHAssetChangeRequest(for: item.asset)
            request.isHidden = true
        } completionHandler: { success, error in
            guard success else {
                fputs("[hidden] hiding failed: \(error?.localizedDescription ?? "unknown")\n", stderr)
                return
            }
            fputs("[hidden] hidden. Now asking for it back:\n", stderr)
            Task { @MainActor in report(item.id) }
        }
    }

    /// What is still reachable for an identifier: the asset, its hidden flag,
    /// its place in an ordinary fetch, and its pixels.
    static func report(_ identifier: String) {
        let plain = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
        fputs("[hidden] fetch by identifier: \(plain.count) asset(s)"
              + (plain.firstObject.map { ", isHidden \($0.isHidden)" } ?? "") + "\n", stderr)

        let options = PHFetchOptions()
        options.includeHiddenAssets = true
        let allowed = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: options)
        fputs("[hidden] fetch by identifier, hidden allowed: \(allowed.count) asset(s)\n", stderr)

        let everything = PHFetchOptions()
        everything.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        let listed = PHAsset.fetchAssets(with: everything)
        var found = false
        listed.enumerateObjects { asset, _, stop in
            if asset.localIdentifier == identifier { found = true; stop.pointee = true }
        }
        fputs("[hidden] listed by an ordinary library fetch: \(found)\n", stderr)

        guard let asset = plain.firstObject ?? allowed.firstObject else {
            fputs("[hidden] no asset, so no pixels to ask for\n", stderr)
            return
        }
        let manager = PHImageManager.default()
        let request = PHImageRequestOptions()
        request.isSynchronous = true
        request.deliveryMode = .highQualityFormat
        manager.requestImage(for: asset,
                             targetSize: CGSize(width: 256, height: 256),
                             contentMode: .aspectFit,
                             options: request) { image, info in
            let failed = (info?[PHImageErrorKey] as? NSError)?.localizedDescription
            fputs("[hidden] pixels: \(image == nil ? "none" : "loaded")"
                  + (failed.map { " (\($0))" } ?? "") + "\n", stderr)
        }
    }

    /// Puts it back.
    static func unhide(_ identifier: String) {
        let options = PHFetchOptions()
        options.includeHiddenAssets = true
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier],
                                              options: options).firstObject else {
            fputs("[hidden] cannot unhide: the identifier no longer resolves at all\n", stderr)
            return
        }
        PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest(for: asset).isHidden = false
        } completionHandler: { success, error in
            fputs("[hidden] unhide: \(success ? "done" : error?.localizedDescription ?? "failed")\n",
                  stderr)
        }
    }
}
#endif
