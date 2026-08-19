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

    /// What this app and Photos each say about particular photographs.
    ///
    /// For the case where the two disagree — a photograph that should be
    /// covered and is not. Three answers per photograph: what the library
    /// snapshot here believes, what the asset itself says when asked directly,
    /// and whether Photos' Hidden album lists it.
    static func report(prefixes: [String], library: [PhotoItem]) {
        guard !prefixes.isEmpty else { return }

        var inHiddenAlbum: Set<String> = []
        let albums = PHAssetCollection.fetchAssetCollections(with: .smartAlbum,
                                                             subtype: .smartAlbumAllHidden,
                                                             options: nil)
        if let album = albums.firstObject {
            let options = PHFetchOptions()
            options.includeHiddenAssets = true
            PHAsset.fetchAssets(in: album, options: options).enumerateObjects { asset, _, _ in
                inHiddenAlbum.insert(asset.localIdentifier)
            }
        }

        for prefix in prefixes {
            let matches = library.filter { $0.id.hasPrefix(prefix) }
            if matches.isEmpty {
                fputs("[hidden] \(prefix): not in the library this app holds\n", stderr)
                continue
            }
            for item in matches {
                let fresh = PHAsset.fetchAssets(withLocalIdentifiers: [item.id], options: nil).firstObject
                fputs("[hidden] \(prefix): snapshot says hidden=\(item.isHidden), "
                      + "the asset says hidden=\(fresh.map { String(describing: $0.isHidden) } ?? "gone"), "
                      + "Hidden album lists it=\(inHiddenAlbum.contains(item.id)), "
                      + "\(item.creationDate?.formatted(.iso8601.year().month().day()) ?? "no date")\n",
                      stderr)
            }
        }
    }

    /// Photographs out in the open on a day that is otherwise hidden.
    ///
    /// The earlier version of this asked the same question of a Lightroom
    /// collection and missed the two that prompted it: they were in the library
    /// but not among the frames that collection matched, so nothing looked at
    /// them. A day is the better unit — it needs no catalogue, it covers the
    /// whole library, and "everything from that afternoon is hidden except
    /// these two" is exactly what an accidental unhide looks like.
    static func findStrays(in library: [PhotoItem]) {
        let byDay = Dictionary(grouping: library.filter { $0.creationDate != nil }) {
            Int(($0.creationDate!.timeIntervalSince1970 / 86_400).rounded(.down))
        }

        var found = 0
        for (_, photographs) in byDay.sorted(by: { $0.key < $1.key }) {
            let hidden = photographs.filter(\.isHidden).count
            let visible = photographs.filter { !$0.isHidden }
            // Nearly all of the day hidden, and only a handful not: a day with
            // half of each is a day with some private photographs on it, which
            // is nobody's mistake.
            guard hidden > 0, !visible.isEmpty,
                  visible.count <= 5, hidden >= photographs.count * 9 / 10 else { continue }

            let day = visible[0].creationDate?.formatted(.iso8601.year().month().day()) ?? "?"
            for item in visible {
                fputs("[hidden] stray on \(day): \(item.id)\n", stderr)
                found += 1
            }
        }
        fputs("[hidden] \(found) photograph(s) not hidden on days that otherwise are\n", stderr)
    }

    /// Puts a list of photographs back into the Hidden album.
    ///
    /// One change request for all of them, so the system asks once rather than
    /// once each. Repairing what a button of this app's own did is still a
    /// change to someone's library, and the system should ask.
    static func hide(identifiers: [String]) {
        guard !identifiers.isEmpty else { return }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        guard assets.count > 0 else {
            fputs("[hidden] none of those identifiers resolve\n", stderr)
            return
        }
        fputs("[hidden] asking Photos to hide \(assets.count) photograph(s)\n", stderr)

        PHPhotoLibrary.shared().performChanges {
            assets.enumerateObjects { asset, _, _ in
                PHAssetChangeRequest(for: asset).isHidden = true
            }
        } completionHandler: { success, error in
            fputs("[hidden] hide: \(success ? "done" : error?.localizedDescription ?? "failed")\n",
                  stderr)
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
