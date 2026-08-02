import Photos
import SwiftUI

/// Serves thumbnails for the grid and full-size images for the loupe.
///
/// `PHCachingImageManager` is told which assets are about to be visible so it
/// can decode ahead of scrolling; a small NSCache in front of it keeps
/// already-seen cells instant when scrolling back up.
@MainActor
final class ThumbnailLoader: ObservableObject {
    static let shared = ThumbnailLoader()

    /// Bumped whenever an asset's image changes underneath a stable identifier.
    /// Views include it in their identity so they re-request rather than
    /// trusting a cache entry that is no longer the same photo.
    @Published private(set) var versions: [String: Int] = [:]

    private let manager = PHCachingImageManager()
    private let cache = NSCache<NSString, PlatformImage>()
    private var cachedAssets: [PHAsset] = []
    /// Which cache keys exist per asset, so one asset can be evicted precisely.
    private var cachedKeys: [String: Set<NSString>] = [:]
    private var cachedSize: CGSize = .zero

    private init() {
        // A count limit alone doesn't bound memory: 1500 thumbnails is a few
        // hundred megabytes at 90pt and well over a gigabyte at 360pt. Costing
        // each entry by its pixels bounds it regardless of thumbnail size.
        cache.countLimit = 1500
        cache.totalCostLimit = 384 * 1024 * 1024
        manager.allowsCachingHighQualityImages = false
    }

    /// Fill mode is part of the key: the same cell size yields a different image
    /// cropped versus letterboxed.
    private func key(_ id: String, _ size: CGSize, _ mode: ThumbnailFillMode) -> NSString {
        "\(id)@\(Int(size.width))x\(Int(size.height))#\(mode.rawValue)" as NSString
    }

    func cachedThumbnail(for item: PhotoItem, size: CGSize, mode: ThumbnailFillMode) -> PlatformImage? {
        cache.object(forKey: key(item.id, size, mode))
    }

    /// Drops every cached size and fill mode for one asset.
    ///
    /// Editing replaces the asset's image while its identifier stays the same,
    /// so without this the grid would keep showing the version from before the
    /// edit until something else happened to evict it.
    func forget(_ item: PhotoItem) { forget(assetID: item.id) }

    func forget(assetID: String) {
        for key in cachedKeys.removeValue(forKey: assetID) ?? [] {
            cache.removeObject(forKey: key)
        }
        versions[assetID, default: 0] += 1

        // PhotoKit keeps its own prefetch cache, which would keep serving the
        // pre-edit rendition however thoroughly ours is cleared. There is no
        // per-asset eviction, and the prefetch is only an optimisation, so
        // dropping it wholesale is the honest option; scrolling re-primes it.
        manager.stopCachingImagesForAllAssets()
        cachedAssets = []
    }

    func version(of assetID: String) -> Int { versions[assetID] ?? 0 }

    func thumbnail(for item: PhotoItem, size: CGSize, mode: ThumbnailFillMode) async -> PlatformImage? {
        let cacheKey = key(item.id, size, mode)
        if let hit = cache.object(forKey: cacheKey) { return hit }

        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false

        let scale = Platform.screenScale
        let target = CGSize(width: size.width * scale, height: size.height * scale)

        let image = await withCheckedContinuation { (continuation: CheckedContinuation<PlatformImage?, Never>) in
            var resumed = false
            manager.requestImage(for: item.asset,
                                 targetSize: target,
                                 contentMode: mode.contentMode,
                                 options: options) { image, info in
                // Opportunistic delivery calls back more than once; the degraded
                // pass is discarded and only the final image resumes.
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                guard !isDegraded, !resumed else { return }
                resumed = true
                continuation.resume(returning: image)
            }
        }

        if let image {
            let cost = Int(target.width * target.height) * 4
            cache.setObject(image, forKey: cacheKey, cost: cost)
            cachedKeys[item.id, default: []].insert(cacheKey)
        }
        return image
    }

    /// Full-resolution-ish image for the loupe. Not cached — one at a time.
    func fullImage(for item: PhotoItem, maxDimension: CGFloat) async -> PlatformImage? {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        options.isNetworkAccessAllowed = true

        let scale = Platform.screenScale
        let target = CGSize(width: maxDimension * scale, height: maxDimension * scale)

        return await withCheckedContinuation { (continuation: CheckedContinuation<PlatformImage?, Never>) in
            var resumed = false
            manager.requestImage(for: item.asset,
                                 targetSize: target,
                                 contentMode: .aspectFit,
                                 options: options) { image, info in
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                guard !isDegraded, !resumed else { return }
                resumed = true
                continuation.resume(returning: image)
            }
        }
    }

    /// Tells PhotoKit which assets are in or near the viewport.
    func updateCaching(visible items: [PhotoItem], size: CGSize, mode: ThumbnailFillMode) {
        guard size.width > 0 else { return }
        let scale = Platform.screenScale
        let target = CGSize(width: size.width * scale, height: size.height * scale)

        if target != cachedSize {
            manager.stopCachingImagesForAllAssets()
            cachedAssets = []
            cachedSize = target
        }

        let incoming = items.map(\.asset)
        let incomingIDs = Set(incoming.map(\.localIdentifier))
        let currentIDs = Set(cachedAssets.map(\.localIdentifier))

        let toStart = incoming.filter { !currentIDs.contains($0.localIdentifier) }
        let toStop = cachedAssets.filter { !incomingIDs.contains($0.localIdentifier) }

        if !toStop.isEmpty {
            manager.stopCachingImages(for: toStop, targetSize: target,
                                      contentMode: mode.contentMode, options: nil)
        }
        if !toStart.isEmpty {
            manager.startCachingImages(for: toStart, targetSize: target,
                                       contentMode: mode.contentMode, options: nil)
        }
        cachedAssets = incoming
    }
}
