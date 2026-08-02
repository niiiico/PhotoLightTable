import CoreLocation
import Foundation
import Photos
import SwiftUI

/// A snapshot of one asset. Reading properties off `PHAsset` repeatedly during
/// grid layout is slow, so everything the UI needs is lifted out once.
struct PhotoItem: Identifiable, Hashable {
    let id: String
    let asset: PHAsset
    let creationDate: Date?
    let pixelWidth: Int
    let pixelHeight: Int
    let isFavorite: Bool
    let mediaSubtypes: PHAssetMediaSubtype
    /// Used by `EventSuggester` to split groups across a change of place.
    let location: CLLocation?

    init(asset: PHAsset) {
        self.id = asset.localIdentifier
        self.asset = asset
        self.creationDate = asset.creationDate
        self.pixelWidth = asset.pixelWidth
        self.pixelHeight = asset.pixelHeight
        self.isFavorite = asset.isFavorite
        self.mediaSubtypes = asset.mediaSubtypes
        self.location = asset.location
    }

    var aspectRatio: CGFloat {
        guard pixelWidth > 0, pixelHeight > 0 else { return 1 }
        return CGFloat(pixelWidth) / CGFloat(pixelHeight)
    }

    static func == (lhs: PhotoItem, rhs: PhotoItem) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// A day's worth of photos, used for the grid's section headers.
struct DaySection: Identifiable {
    let id: Date
    let items: [PhotoItem]

    var title: String {
        id.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
    }
}

@MainActor
final class PhotoLibraryService: NSObject, ObservableObject {
    enum AuthState: Equatable {
        case undetermined
        case authorized
        case limited
        case denied
    }

    @Published private(set) var authState: AuthState = .undetermined
    @Published private(set) var items: [PhotoItem] = []
    @Published private(set) var isLoading = false
    /// Bumped on each successful reload, so derived state can be invalidated
    /// without comparing the whole array.
    @Published private(set) var version = 0

    /// Fires on any photo-library change, including ones that only touch albums.
    var onLibraryChange: (() -> Void)?

    private var fetchResult: PHFetchResult<PHAsset>?
    /// Position of each asset in `items`, so a content change can be applied
    /// without scanning the whole library.
    private var indexByID: [String: Int] = [:]
    private var isObserving = false

    // MARK: - Authorization

    func requestAccess() async {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        let resolved: PHAuthorizationStatus
        if status == .notDetermined {
            resolved = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        } else {
            resolved = status
        }
        apply(resolved)
        if authState == .authorized || authState == .limited {
            startObserving()
            await reload()
        }
    }

    private func apply(_ status: PHAuthorizationStatus) {
        switch status {
        case .authorized: authState = .authorized
        case .limited: authState = .limited
        case .denied, .restricted: authState = .denied
        case .notDetermined: authState = .undetermined
        @unknown default: authState = .denied
        }
    }

    private func startObserving() {
        guard !isObserving else { return }
        PHPhotoLibrary.shared().register(self)
        isObserving = true
    }

    // MARK: - Fetching

    func reload() async {
        isLoading = true
        defer { isLoading = false }

        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.includeHiddenAssets = false

        let result = PHAsset.fetchAssets(with: options)
        fetchResult = result

        // Snapshotting a large library blocks, so do it off the main actor and
        // hand back only the value types.
        let snapshot = await Task.detached(priority: .userInitiated) { () -> [PhotoItem] in
            var built: [PhotoItem] = []
            built.reserveCapacity(result.count)
            result.enumerateObjects { asset, _, _ in
                built.append(PhotoItem(asset: asset))
            }
            return built
        }.value

        items = snapshot
        indexByID = Dictionary(uniqueKeysWithValues: snapshot.enumerated().map { ($1.id, $0) })
        version &+= 1
    }

    /// Re-reads one asset and replaces its entry.
    ///
    /// After editing, the `PHAsset` held in `items` describes the version from
    /// before the edit, and asking the image manager for a stale asset yields
    /// the stale image. The change notification would eventually deliver a
    /// fresh one, but not before the grid has already redrawn.
    func refreshAsset(withID id: String) {
        guard let index = indexByID[id],
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
        else { return }

        items[index] = PhotoItem(asset: asset)
        ThumbnailLoader.shared.forget(assetID: id)
        version &+= 1
    }

    private func apply(changed assets: [PHAsset]) {
        guard !assets.isEmpty else { return }
        var touched = false
        for asset in assets {
            guard let index = indexByID[asset.localIdentifier] else { continue }
            items[index] = PhotoItem(asset: asset)
            ThumbnailLoader.shared.forget(assetID: asset.localIdentifier)
            touched = true
        }
        if touched { version &+= 1 }
    }

    // MARK: - Grouping

    /// Groups into calendar days. This is the plain date view; events are a
    /// separate, user-defined layer on top.
    ///
    /// Photos within a day keep the order they arrived in, so only the sections
    /// need reordering to match the caller's sort.
    static func groupByDay(_ items: [PhotoItem], oldestFirst: Bool) -> [DaySection] {
        let cal = Calendar.current
        var buckets: [Date: [PhotoItem]] = [:]
        for item in items {
            let day = cal.startOfDay(for: item.creationDate ?? .distantPast)
            buckets[day, default: []].append(item)
        }
        return buckets
            .map { DaySection(id: $0.key, items: $0.value) }
            .sorted { oldestFirst ? $0.id < $1.id : $0.id > $1.id }
    }
}

extension PhotoLibraryService: PHPhotoLibraryChangeObserver {
    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor in
            if let current = fetchResult,
               let details = changeInstance.changeDetails(for: current) {
                fetchResult = details.fetchResultAfterChanges

                // Only assets appearing or disappearing needs a re-snapshot.
                // Photos fires change notifications constantly — analysis,
                // iCloud, and our own album writes — and the previous condition
                // was true for nearly all of them, so a 75k-asset library was
                // re-snapshotted every few seconds, several seconds at a time.
                let isStructural = details.hasIncrementalChanges
                    ? !(details.insertedObjects.isEmpty && details.removedObjects.isEmpty)
                    : true
                if isStructural {
                    await reload()
                } else if details.hasIncrementalChanges {
                    // An edit replaces an asset's image while its identifier
                    // stays the same, so nothing above would notice. Refresh
                    // just those entries — this covers edits made in Photos as
                    // well as our own.
                    apply(changed: details.changedObjects)
                }
            }

            // Album membership changes without touching the asset fetch at all,
            // so this fires on every notification. It is what lets an edit made
            // in Photos find its way back into the store.
            onLibraryChange?()
        }
    }
}
