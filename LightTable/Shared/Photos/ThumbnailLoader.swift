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

    /// Thumbnails as they arrive: the quick blurry one PhotoKit already has,
    /// then the real one.
    ///
    /// It used to wait for the final image and throw the first away, which is
    /// the right choice for judging a photograph and the wrong one for a grid
    /// being scrolled: the wait was a field of empty rectangles where the
    /// pictures should be. Both passes are yielded now — the first says which
    /// photograph this is, the second is the one you look at.
    ///
    /// A stream rather than a value because the request is also cancelled when
    /// nobody is listening any more: a cell scrolled past should stop competing
    /// for decode time with the cells now on screen.
    func thumbnails(for item: PhotoItem,
                    size: CGSize,
                    mode: ThumbnailFillMode) -> AsyncStream<PlatformImage> {
        let cacheKey = key(item.id, size, mode)
        let scale = Platform.screenScale
        let target = CGSize(width: size.width * scale, height: size.height * scale)

        return AsyncStream { continuation in
            if let hit = cache.object(forKey: cacheKey) {
                continuation.yield(hit)
                continuation.finish()
                return
            }

            let options = PHImageRequestOptions()
            options.deliveryMode = .opportunistic
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = true
            options.isSynchronous = false

            let requestID = manager.requestImage(for: item.asset,
                                                 targetSize: target,
                                                 contentMode: mode.contentMode,
                                                 options: options) { [weak self] image, info in
                guard let image else {
                    // No image and not a staging pass: nothing more is coming.
                    if ((info?[PHImageResultIsDegradedKey] as? Bool) ?? false) == false {
                        continuation.finish()
                    }
                    return
                }
                continuation.yield(image)

                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                guard !isDegraded else { return }
                if let self {
                    let cost = Int(target.width * target.height) * 4
                    self.cache.setObject(image, forKey: cacheKey, cost: cost)
                    self.cachedKeys[item.id, default: []].insert(cacheKey)
                }
                continuation.finish()
            }

            continuation.onTermination = { _ in
                Task { @MainActor [weak self] in
                    self?.manager.cancelImageRequest(requestID)
                }
            }
        }
    }

    /// Full-resolution-ish images for the loupe, as they arrive.
    ///
    /// Opportunistic for the same reason the grid is: arrowing through a take,
    /// a screen that goes empty between frames reads as the app having stopped,
    /// and the low-resolution pass arrives in a few milliseconds. The final
    /// image is what any judgement is made on, and it always follows.
    func fullImages(for item: PhotoItem, maxDimension: CGFloat) -> AsyncStream<PlatformImage> {
        let scale = Platform.screenScale
        let target = CGSize(width: maxDimension * scale, height: maxDimension * scale)

        return AsyncStream { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .opportunistic
            options.resizeMode = .exact
            options.isNetworkAccessAllowed = true

            let requestID = manager.requestImage(for: item.asset,
                                                 targetSize: target,
                                                 contentMode: .aspectFit,
                                                 options: options) { image, info in
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if let image { continuation.yield(image) }
                if !isDegraded { continuation.finish() }
            }

            continuation.onTermination = { _ in
                Task { @MainActor [weak self] in
                    self?.manager.cancelImageRequest(requestID)
                }
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
