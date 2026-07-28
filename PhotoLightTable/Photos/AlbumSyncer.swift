import Foundation
import Photos

/// What one event should look like in Photos: a folder holding an album of
/// everything in the event and an album of the picks.
struct EventAlbumPlan {
    let name: String
    let allIDs: Set<String>
    let pickedIDs: Set<String>

    var folderID: String?
    var albumID: String?
    var pickedAlbumID: String?

    /// Writes newly created collection identifiers back onto the event, so a
    /// later rename updates the same folder instead of making another one.
    let persistIdentifiers: (_ folderID: String?, _ albumID: String?, _ pickedAlbumID: String?) -> Void
}

/// Mirrors pick/reject state into real Photos albums.
///
/// Album mutations are `performChanges` transactions that notify observers and
/// queue an iCloud sync, so they cost far too much to run on every keypress.
/// Rating changes only arm a timer; the reconcile runs once the user pauses.
@MainActor
final class AlbumSyncer: ObservableObject {
    /// Everything the app creates lives under this one top-level folder, so it
    /// stays out of the way of the user's own albums.
    static let rootFolderTitle = "LightTable"
    static let pickedAlbumTitle = "LightTable — Picked"
    static let rejectedAlbumTitle = "LightTable — Rejected"

    enum Status: Equatable {
        case idle
        case pending
        case syncing
        case failed(String)
    }

    @Published private(set) var status: Status = .idle
    @Published var isEnabled: Bool = true {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey) }
    }

    private static let enabledKey = "AlbumSyncEnabled"
    private let debounce: Duration = .seconds(2)
    private var pendingTask: Task<Void, Never>?

    // Latest desired state. Global picks and per-event plans are updated from
    // different places but share one timer, so they can't race each other.
    private var latestPicked: Set<String> = []
    private var latestRejected: Set<String> = []
    private var latestPlans: [EventAlbumPlan] = []

    init() {
        if UserDefaults.standard.object(forKey: Self.enabledKey) != nil {
            isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        }
    }

    // MARK: - Scheduling

    func scheduleSync(picked: Set<String>, rejected: Set<String>) {
        latestPicked = picked
        latestRejected = rejected
        arm()
    }

    func scheduleEventSync(_ plans: [EventAlbumPlan]) {
        latestPlans = plans
        arm()
    }

    func syncNow(picked: Set<String>, rejected: Set<String>) {
        latestPicked = picked
        latestRejected = rejected
        pendingTask?.cancel()
        pendingTask = Task { await self.reconcileAll() }
    }

    private func arm() {
        guard isEnabled else { return }
        pendingTask?.cancel()
        status = .pending
        pendingTask = Task { [debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            await self.reconcileAll()
        }
    }

    // MARK: - Reconcile

    private func reconcileAll() async {
        status = .syncing
        do {
            let root = try await findOrCreateFolder(id: nil, title: Self.rootFolderTitle, parent: nil)
            try await reconcileAlbum(id: nil, title: Self.pickedAlbumTitle,
                                     desired: latestPicked, in: root, adoptLibraryWide: true)
            try await reconcileAlbum(id: nil, title: Self.rejectedAlbumTitle,
                                     desired: latestRejected, in: root, adoptLibraryWide: true)
            for plan in latestPlans {
                try await reconcile(plan, under: root)
            }
            status = .idle
        } catch is CancellationError {
            status = .idle
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    private func reconcile(_ plan: EventAlbumPlan, under root: PHCollectionList) async throws {
        let folder = try await findOrCreateFolder(id: plan.folderID, title: plan.name, parent: root)

        let album = try await findOrCreateAlbum(id: plan.albumID,
                                                title: plan.name,
                                                in: folder)
        let pickedAlbum = try await findOrCreateAlbum(id: plan.pickedAlbumID,
                                                      title: "\(plan.name) — Picked",
                                                      in: folder)

        try await reconcileMembership(of: album, desired: plan.allIDs)
        try await reconcileMembership(of: pickedAlbum, desired: plan.pickedIDs)

        plan.persistIdentifiers(folder.localIdentifier,
                                album.localIdentifier,
                                pickedAlbum.localIdentifier)
    }

    /// Convenience for the two global albums, which live at the top level.
    private func reconcileAlbum(id: String?,
                                title: String,
                                desired: Set<String>,
                                in folder: PHCollectionList?,
                                adoptLibraryWide: Bool = false) async throws {
        let album = try await findOrCreateAlbum(id: id, title: title, in: folder,
                                                adoptLibraryWide: adoptLibraryWide)
        try await reconcileMembership(of: album, desired: desired)
    }

    /// Brings one album's membership in line with `desired`, adding and removing
    /// only the difference so unrelated edits made in Photos survive.
    private func reconcileMembership(of album: PHAssetCollection, desired: Set<String>) async throws {
        let existingAssets = PHAsset.fetchAssets(in: album, options: nil)
        var existingByID: [String: PHAsset] = [:]
        existingAssets.enumerateObjects { asset, _, _ in
            existingByID[asset.localIdentifier] = asset
        }
        let existingIDs = Set(existingByID.keys)

        let toAddIDs = desired.subtracting(existingIDs)
        let toRemoveIDs = existingIDs.subtracting(desired)
        guard !toAddIDs.isEmpty || !toRemoveIDs.isEmpty else { return }

        let toAdd = toAddIDs.isEmpty ? [] : assets(withIDs: Array(toAddIDs))
        let toRemove = toRemoveIDs.compactMap { existingByID[$0] }

        try await PHPhotoLibrary.shared().performChanges {
            guard let request = PHAssetCollectionChangeRequest(for: album, assets: existingAssets) else { return }
            if !toAdd.isEmpty { request.addAssets(toAdd as NSFastEnumeration) }
            if !toRemove.isEmpty { request.removeAssets(toRemove as NSFastEnumeration) }
        }
    }

    private func assets(withIDs ids: [String]) -> [PHAsset] {
        let result = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var assets: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in assets.append(asset) }
        return assets
    }

    // MARK: - Finding and creating collections

    private func findOrCreateFolder(id: String?,
                                    title: String,
                                    parent: PHCollectionList?) async throws -> PHCollectionList {
        // Prefer the folder we made before, so renaming the event renames it.
        if let id,
           let existing = PHCollectionList.fetchCollectionLists(
            withLocalIdentifiers: [id], options: nil).firstObject {
            if existing.localizedTitle != title {
                try await PHPhotoLibrary.shared().performChanges {
                    PHCollectionListChangeRequest(for: existing)?.title = title
                }
            }
            if let parent { try await ensure(existing, isChildOf: parent) }
            return existing
        }

        // Adopt only a folder already sitting under our parent. A library-wide
        // search would let an event named "Geneve" hijack the user's own Geneve
        // folder and drag it in here.
        if let matching = folder(titled: title, in: parent) {
            return matching
        }

        var placeholder: PHObjectPlaceholder?
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHCollectionListChangeRequest.creationRequestForCollectionList(withTitle: title)
            let created = request.placeholderForCreatedCollectionList
            placeholder = created
            if let parent {
                PHCollectionListChangeRequest(for: parent)?
                    .addChildCollections([created] as NSFastEnumeration)
            }
        }
        guard let newID = placeholder?.localIdentifier,
              let created = PHCollectionList.fetchCollectionLists(
                withLocalIdentifiers: [newID], options: nil).firstObject else {
            throw SyncError.creationFailed(title)
        }
        return created
    }

    /// Moves a collection under `parent` if it isn't already there. Photos allows
    /// only one parent per collection, so adding is a move — which is what
    /// relocates albums created before the LightTable folder existed.
    private func ensure(_ collection: PHCollection, isChildOf parent: PHCollectionList) async throws {
        let parents = PHCollectionList.fetchCollectionListsContaining(collection, options: nil)
        var alreadyChild = false
        parents.enumerateObjects { list, _, stop in
            if list.localIdentifier == parent.localIdentifier {
                alreadyChild = true
                stop.pointee = true
            }
        }
        guard !alreadyChild else { return }

        try await PHPhotoLibrary.shared().performChanges {
            PHCollectionListChangeRequest(for: parent)?
                .addChildCollections([collection] as NSFastEnumeration)
        }
    }

    /// `adoptLibraryWide` is only set for the two global albums, which may still
    /// be sitting at the top level from before the LightTable folder existed.
    /// Event albums must never adopt library-wide: an event called "Geneve"
    /// would take over the user's own Geneve album and start pruning it.
    private func findOrCreateAlbum(id: String?,
                                   title: String,
                                   in folder: PHCollectionList?,
                                   adoptLibraryWide: Bool = false) async throws -> PHAssetCollection {
        if let id,
           let existing = PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: [id], options: nil).firstObject {
            if existing.localizedTitle != title {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetCollectionChangeRequest(for: existing)?.title = title
                }
            }
            if let folder { try await ensure(existing, isChildOf: folder) }
            return existing
        }

        if let matching = album(titled: title, in: folder, adoptLibraryWide: adoptLibraryWide) {
            if let folder { try await ensure(matching, isChildOf: folder) }
            return matching
        }

        var placeholder: PHObjectPlaceholder?
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title)
            let created = request.placeholderForCreatedAssetCollection
            placeholder = created
            // Nesting has to happen in the same change block, using the
            // placeholder — the album doesn't exist to fetch until this commits.
            if let folder {
                PHCollectionListChangeRequest(for: folder)?
                    .addChildCollections([created] as NSFastEnumeration)
            }
        }
        guard let newID = placeholder?.localIdentifier,
              let created = PHAssetCollection.fetchAssetCollections(
                withLocalIdentifiers: [newID], options: nil).firstObject else {
            throw SyncError.creationFailed(title)
        }
        return created
    }

    /// With a parent, looks only among its children. Without one (the root
    /// LightTable folder) it searches the top level of the library.
    private func folder(titled title: String, in parent: PHCollectionList?) -> PHCollectionList? {
        if let parent {
            let children = PHCollection.fetchCollections(in: parent, options: nil)
            var match: PHCollectionList?
            children.enumerateObjects { collection, _, stop in
                if let list = collection as? PHCollectionList, list.localizedTitle == title {
                    match = list
                    stop.pointee = true
                }
            }
            return match
        }

        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "localizedTitle == %@", title)
        return PHCollectionList.fetchCollectionLists(with: .folder,
                                                     subtype: .any,
                                                     options: options).firstObject
    }

    /// Looks inside the folder first, so an event album doesn't collide with a
    /// same-named album elsewhere, then falls back to a library-wide search to
    /// adopt an album that hasn't been filed into the folder yet.
    private func album(titled title: String,
                       in folder: PHCollectionList?,
                       adoptLibraryWide: Bool) -> PHAssetCollection? {
        if let folder {
            let children = PHCollection.fetchCollections(in: folder, options: nil)
            var match: PHAssetCollection?
            children.enumerateObjects { collection, _, stop in
                if let album = collection as? PHAssetCollection, album.localizedTitle == title {
                    match = album
                    stop.pointee = true
                }
            }
            if let match { return match }
        }

        guard adoptLibraryWide || folder == nil else { return nil }

        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "title == %@", title)
        return PHAssetCollection.fetchAssetCollections(with: .album,
                                                       subtype: .albumRegular,
                                                       options: options).firstObject
    }

    enum SyncError: LocalizedError {
        case creationFailed(String)

        var errorDescription: String? {
            switch self {
            case .creationFailed(let title):
                return "Could not create “\(title)” in Photos."
            }
        }
    }
}
