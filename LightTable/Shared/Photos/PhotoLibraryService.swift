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

    /// The photographs in Photos' Hidden album, when it will say.
    private static func hiddenImages() -> [PHAsset] {
        let albums = PHAssetCollection.fetchAssetCollections(with: .smartAlbum,
                                                             subtype: .smartAlbumAllHidden,
                                                             options: nil)
        guard let album = albums.firstObject else { return [] }

        let options = PHFetchOptions()
        options.includeHiddenAssets = true
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        var assets: [PHAsset] = []
        PHAsset.fetchAssets(in: album, options: options).enumerateObjects { asset, _, _ in
            assets.append(asset)
        }
        return assets
    }

    func reload() async {
        isLoading = true
        defer { isLoading = false }

        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]

        let result = PHAsset.fetchAssets(with: options)
        fetchResult = result

        // Hidden photographs are not in that result and never will be. Apple's
        // documentation is exact about it: "Hidden assets are only available in
        // the hidden Smart Album or in user Smart Albums" — a general fetch
        // does not return them however the option is set, so they are collected
        // from the album itself and merged in.
        //
        // Even that only answers while the owner has turned off the
        // authentication the Hidden album asks for, which is on by default.
        let hidden = Debug.includesHidden ? Self.hiddenImages() : []

        // Snapshotting a large library blocks, so do it off the main actor and
        // hand back only the value types.
        let snapshot = await Task.detached(priority: .userInitiated) { () -> [PhotoItem] in
            var built: [PhotoItem] = []
            built.reserveCapacity(result.count + hidden.count)
            result.enumerateObjects { asset, _, _ in
                built.append(PhotoItem(asset: asset))
            }
            guard !hidden.isEmpty else { return built }

            // Merged and re-sorted rather than appended: everything downstream
            // relies on this list being newest first — the day sections, the
            // timeline rail, and `AppModel.sort`, which is a reverse rather
            // than a sort precisely because of it.
            built.append(contentsOf: hidden.map(PhotoItem.init))
            built.sort { ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) }
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
        grouped(items, dateOf: { $0.creationDate }, oldestFirst: oldestFirst)
            .map { DaySection(id: $0.day, items: $0.items) }
    }

    /// Groups a run of photographs into days.
    ///
    /// Written for a list that is already in date order, which is what the grid
    /// hands it: the day of the last photograph is nearly always the day of this
    /// one, so the common step is a date comparison and an append. Anything that
    /// arrives out of order — a variant held back from a source that is not
    /// showing, which the stacking pass puts at the end — still finds its own
    /// day through the index rather than opening a second section for it.
    ///
    /// Generic over the item so the rule can be exercised without `PHAsset`s,
    /// which cannot be made with a creation date.
    /// `nonisolated` because it reads nothing but its arguments — the class is
    /// on the main actor for the library it holds, and this rule has no such
    /// need. Inheriting the isolation would put it out of reach of a test.
    nonisolated static func grouped<T>(_ items: [T],
                                       dateOf: (T) -> Date?,
                                       oldestFirst: Bool,
                                       calendar: Calendar = .current) -> [(day: Date, items: [T])] {
        var keys = DayKeys(calendar: calendar)
        var days: [(day: Date, items: [T])] = []
        var indexByDay: [Date: Int] = [:]
        var currentDay: Date?
        var currentIndex = 0

        for item in items {
            let day = keys.day(of: dateOf(item) ?? .distantPast)
            if day != currentDay {
                if let existing = indexByDay[day] {
                    currentIndex = existing
                } else {
                    days.append((day, []))
                    currentIndex = days.count - 1
                    indexByDay[day] = currentIndex
                }
                currentDay = day
            }
            days[currentIndex].items.append(item)
        }

        return days.sorted { oldestFirst ? $0.day < $1.day : $0.day > $1.day }
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
