import Foundation
import Photos

/// Membership changes made in Photos since the last sync, to be folded back
/// into the app's own store.
struct RemoteRatingDelta {
    var pickedAdded: Set<String> = []
    var pickedRemoved: Set<String> = []
    var rejectedAdded: Set<String> = []
    var rejectedRemoved: Set<String> = []

    var isEmpty: Bool {
        pickedAdded.isEmpty && pickedRemoved.isEmpty
            && rejectedAdded.isEmpty && rejectedRemoved.isEmpty
    }

    mutating func formUnion(_ other: RemoteRatingDelta) {
        pickedAdded.formUnion(other.pickedAdded)
        pickedRemoved.formUnion(other.pickedRemoved)
        rejectedAdded.formUnion(other.rejectedAdded)
        rejectedRemoved.formUnion(other.rejectedRemoved)
    }
}

/// What one event should look like in Photos: a folder holding an album of
/// everything in the event and an album of the picks.
struct EventAlbumPlan {
    /// Stable prefix for this event's baseline records.
    let key: String
    let name: String
    let allIDs: Set<String>
    let pickedIDs: Set<String>
    /// Membership at the end of the last successful sync, per album.
    let allBaseline: Set<String>
    let pickedBaseline: Set<String>

    var folderID: String?
    var albumID: String?
    var pickedAlbumID: String?

    /// Writes newly created collection identifiers back onto the event, so a
    /// later rename updates the same folder instead of making another one.
    let persistIdentifiers: (_ folderID: String?, _ albumID: String?, _ pickedAlbumID: String?) -> Void
    /// Photos added to or removed from the event's album inside Photos.
    let applyMembershipDelta: (_ added: Set<String>, _ removed: Set<String>) -> Void
}

/// Everything the syncer needs for one pass.
struct SyncSnapshot {
    var picked: Set<String> = []
    var rejected: Set<String> = []
    var pickedBaseline: Set<String> = []
    var rejectedBaseline: Set<String> = []
    var events: [EventAlbumPlan] = []
}

/// Keeps the app's ratings and the Photos albums in step, in both directions.
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

    static let globalPickedKey = "global.picked"
    static let globalRejectedKey = "global.rejected"

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

    /// Called with anything that changed in Photos since the last sync.
    var onRemoteRatingChanges: ((RemoteRatingDelta) -> Void)?
    /// Called with an album's membership once it has converged, to be stored as
    /// the next baseline.
    var onBaselineUpdate: ((_ key: String, _ members: Set<String>) -> Void)?

    /// Produces the desired state. Called once per pass rather than per
    /// schedule: building it walks the library for every synced event, and
    /// scheduling happens on every keypress.
    var snapshotProvider: (() -> SyncSnapshot)?

    /// Identifiers of the two global albums, remembered so a later pass can tell
    /// "the album was emptied" from "the album is gone".
    private static let pickedAlbumIDKey = "AlbumSync.pickedAlbumID"
    private static let rejectedAlbumIDKey = "AlbumSync.rejectedAlbumID"
    private static let enabledKey = "AlbumSyncEnabled"
    private let debounce: Duration = .seconds(2)
    private var pendingTask: Task<Void, Never>?
    private var isReconciling = false
    private var needsAnotherPass = false
    /// Survives across passes so a failure stays visible even when another pass
    /// is queued behind it.
    @Published private(set) var lastError: String?

    init() {
        if UserDefaults.standard.object(forKey: Self.enabledKey) != nil {
            isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        }
    }

    // MARK: - Scheduling

    func schedule() {
        guard isEnabled else { return }
        // Cancelling a running reconcile would abort it between two albums,
        // leaving a baseline recorded for one and not the other. Queue instead —
        // and the queued pass builds its own snapshot when it runs, so it can't
        // replay stale baselines over newer work.
        guard !isReconciling else { needsAnotherPass = true; return }

        pendingTask?.cancel()
        status = .pending
        pendingTask = Task { [debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            await self.reconcileAll()
        }
    }

    func syncNow() {
        guard !isReconciling else { needsAnotherPass = true; return }
        pendingTask?.cancel()
        pendingTask = Task { await self.reconcileAll() }
    }

    // MARK: - Reconcile

    private func reconcileAll() async {
        guard let snapshot = snapshotProvider?() else { return }

        status = .syncing
        isReconciling = true
        defer {
            isReconciling = false
            // A change that arrived mid-pass was deferred rather than dropped.
            if needsAnotherPass {
                needsAnotherPass = false
                schedule()
            }
        }
        var delta = RemoteRatingDelta()

        do {
            let root = try await findOrCreateFolder(id: nil, title: Self.rootFolderTitle, parent: nil)
            let defaults = UserDefaults.standard

            let picked = try await reconcileAlbum(
                id: defaults.string(forKey: Self.pickedAlbumIDKey),
                title: Self.pickedAlbumTitle, desired: snapshot.picked,
                baseline: snapshot.pickedBaseline, in: root, adoptLibraryWide: true,
                storeIDAt: Self.pickedAlbumIDKey)
            delta.pickedAdded = picked.remoteAdded
            delta.pickedRemoved = picked.remoteRemoved
            onBaselineUpdate?(Self.globalPickedKey, picked.members)

            let rejected = try await reconcileAlbum(
                id: defaults.string(forKey: Self.rejectedAlbumIDKey),
                title: Self.rejectedAlbumTitle, desired: snapshot.rejected,
                baseline: snapshot.rejectedBaseline, in: root, adoptLibraryWide: true,
                storeIDAt: Self.rejectedAlbumIDKey)
            delta.rejectedAdded = rejected.remoteAdded
            delta.rejectedRemoved = rejected.remoteRemoved
            onBaselineUpdate?(Self.globalRejectedKey, rejected.members)

            for plan in snapshot.events {
                delta.formUnion(try await reconcile(plan, under: root))
            }

            if !delta.isEmpty { onRemoteRatingChanges?(delta) }
            lastError = nil
            status = .idle
        } catch is CancellationError {
            status = .idle
        } catch {
            // Kept outside `status`, which the queued pass resets to .pending.
            lastError = error.localizedDescription
            status = .failed(error.localizedDescription)
        }
    }

    private func reconcile(_ plan: EventAlbumPlan,
                           under root: PHCollectionList) async throws -> RemoteRatingDelta {
        let folder = try await findOrCreateFolder(id: plan.folderID, title: plan.name, parent: root)
        let album = try await findOrCreateAlbum(id: plan.albumID, title: plan.name, in: folder)
        let pickedAlbum = try await findOrCreateAlbum(
            id: plan.pickedAlbumID, title: "\(plan.name) — Picked", in: folder)

        let all = try await merge(album: album.album, desired: plan.allIDs,
                                  baseline: plan.allBaseline,
                                  trustRemovals: !album.wasCreated)
        let picked = try await merge(album: pickedAlbum.album, desired: plan.pickedIDs,
                                     baseline: plan.pickedBaseline,
                                     trustRemovals: !pickedAlbum.wasCreated)

        plan.persistIdentifiers(folder.localIdentifier,
                                album.album.localIdentifier,
                                pickedAlbum.album.localIdentifier)
        if !all.remoteAdded.isEmpty || !all.remoteRemoved.isEmpty {
            plan.applyMembershipDelta(all.remoteAdded, all.remoteRemoved)
        }
        onBaselineUpdate?("\(plan.key).all", all.members)
        onBaselineUpdate?("\(plan.key).picked", picked.members)

        // A photo dropped into an event's Picked album in Photos is a pick, the
        // same as pressing P here.
        return RemoteRatingDelta(pickedAdded: picked.remoteAdded,
                                 pickedRemoved: picked.remoteRemoved)
    }

    private struct MergeResult {
        var members: Set<String> = []
        var remoteAdded: Set<String> = []
        var remoteRemoved: Set<String> = []
    }

    /// An album plus whether this pass had to create it.
    private struct ResolvedAlbum {
        var album: PHAssetCollection
        var wasCreated: Bool
    }

    private func reconcileAlbum(id: String?,
                                title: String,
                                desired: Set<String>,
                                baseline: Set<String>,
                                in folder: PHCollectionList?,
                                adoptLibraryWide: Bool = false,
                                storeIDAt key: String? = nil) async throws -> MergeResult {
        let resolved = try await findOrCreateAlbum(id: id, title: title, in: folder,
                                                   adoptLibraryWide: adoptLibraryWide)
        if let key {
            UserDefaults.standard.set(resolved.album.localIdentifier, forKey: key)
        }
        return try await merge(album: resolved.album,
                               desired: desired,
                               baseline: baseline,
                               trustRemovals: !resolved.wasCreated)
    }

    /// Three-way merge of one album.
    ///
    /// `baseline` is what the album held when the app last agreed with it, so
    /// anything added or removed since was done by hand in Photos and must be
    /// preserved. Without a baseline this could only overwrite, and every edit
    /// made in Photos would be silently undone on the next pass.
    private func merge(album: PHAssetCollection,
                       desired: Set<String>,
                       baseline: Set<String>,
                       trustRemovals: Bool) async throws -> MergeResult {
        // An album that can't take content is not one whose emptiness means
        // anything. Attempting the write anyway succeeds with zero mutations,
        // which would then be recorded as agreement.
        guard album.canPerform(.addContent),
              album.canPerform(.removeContent) else {
            throw SyncError.notEditable(album.localizedTitle ?? "album")
        }

        let existingAssets = PHAsset.fetchAssets(in: album, options: nil)
        var existingByID: [String: PHAsset] = [:]
        existingAssets.enumerateObjects { asset, _, _ in
            existingByID[asset.localIdentifier] = asset
        }
        let remote = Set(existingByID.keys)

        var result = MergeResult()
        result.remoteAdded = remote.subtracting(baseline)
        // Only believe a removal when the album we are reading is the one the
        // baseline describes. A freshly created album is empty because it is
        // new — reading that as "the user removed everything" is how deleting
        // the LightTable folder in Photos would wipe every rating.
        result.remoteRemoved = trustRemovals ? baseline.subtracting(remote) : []

        // Remote edits win for the assets they touch; every other asset keeps
        // whatever the app says.
        let final = desired.union(result.remoteAdded).subtracting(result.remoteRemoved)
        result.members = final

        let toAddIDs = final.subtracting(remote)
        let toRemoveIDs = remote.subtracting(final)
        guard !toAddIDs.isEmpty || !toRemoveIDs.isEmpty else { return result }

        let toAdd = toAddIDs.isEmpty ? [] : assets(withIDs: Array(toAddIDs))
        let toRemove = toRemoveIDs.compactMap { existingByID[$0] }

        let didWrite = Flag()
        try await PHPhotoLibrary.shared().performChanges {
            guard let request = PHAssetCollectionChangeRequest(for: album, assets: existingAssets) else { return }
            didWrite.value = true
            if !toAdd.isEmpty { request.addAssets(toAdd as NSFastEnumeration) }
            if !toRemove.isEmpty { request.removeAssets(toRemove as NSFastEnumeration) }
        }

        // The guard above returns from the *change block*, not from here, so
        // performChanges reports success having done nothing. Storing `final` as
        // the baseline after that would tell the next pass those assets had been
        // removed by hand, and it would delete the ratings to match.
        guard didWrite.value else {
            throw SyncError.notEditable(album.localizedTitle ?? "album")
        }
        return result
    }

    /// A reference box, so the change block's result survives back to the caller.
    private final class Flag: @unchecked Sendable {
        var value = false
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
                                   adoptLibraryWide: Bool = false) async throws -> ResolvedAlbum {
        if let id,
           let existing = PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: [id], options: nil).firstObject {
            if existing.localizedTitle != title {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetCollectionChangeRequest(for: existing)?.title = title
                }
            }
            if let folder { try await ensure(existing, isChildOf: folder) }
            return ResolvedAlbum(album: existing, wasCreated: false)
        }

        if let matching = album(titled: title, in: folder, adoptLibraryWide: adoptLibraryWide) {
            if let folder { try await ensure(matching, isChildOf: folder) }
            // Adopted rather than created, but not the album the baseline was
            // written against either — so its contents are not evidence of what
            // the user removed.
            return ResolvedAlbum(album: matching, wasCreated: id != nil)
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
        return ResolvedAlbum(album: created, wasCreated: true)
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
        case notEditable(String)

        var errorDescription: String? {
            switch self {
            case .creationFailed(let title):
                return "Could not create “\(title)” in Photos."
            case .notEditable(let title):
                return "“\(title)” can't be changed by this app — a shared or system album can't be kept in step."
            }
        }
    }
}
