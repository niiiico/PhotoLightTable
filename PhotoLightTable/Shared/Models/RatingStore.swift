import Foundation
import SwiftData
import SwiftUI

/// Owns rating state for the whole library.
///
/// Everything is held in a dictionary so the grid can ask for a rating during
/// layout without touching SwiftData. Writes go to memory first (so a keypress
/// paints immediately), then to the store, then eventually to Photos albums via
/// `AlbumSyncer`.
@MainActor
final class RatingStore: ObservableObject {
    @Published private(set) var ratings: [String: RatingValue] = [:]
    /// Bumped on every mutation so views depending on many assets can refresh cheaply.
    @Published private(set) var revision: Int = 0

    private let context: ModelContext
    private var rows: [String: AssetRating] = [:]
    private let syncer: AlbumSyncer
    private var baselines: [String: AlbumBaseline] = [:]
    /// Label per asset that is a variant of another, for the grid's badge.
    @Published private(set) var variantLabels: [String: String] = [:]

    /// Set while folding remote changes in, so applying them doesn't schedule
    /// another sync and bounce the same edit back at Photos.
    private var isApplyingRemote = false

    /// Supplies the current library. Set to read from `PhotoLibraryService`,
    /// which is a reference type, so this always sees live data.
    var itemsProvider: (() -> [PhotoItem])?

    init(context: ModelContext, syncer: AlbumSyncer) {
        self.context = context
        self.syncer = syncer
        load()

        // Built when a pass runs rather than when one is scheduled: it walks
        // the library once per synced event, and scheduling happens on every
        // keypress. It also means a queued pass reads current baselines rather
        // than replaying the ones captured before the previous pass.
        syncer.snapshotProvider = { [weak self] in
            self?.snapshot() ?? SyncSnapshot()
        }
        syncer.onRemoteRatingChanges = { [weak self] delta in
            self?.applyRemote(delta)
        }
        syncer.onBaselineUpdate = { [weak self] key, members in
            self?.setBaseline(key, members: members)
        }
    }

    private func load() {
        if let existing = try? context.fetch(FetchDescriptor<AssetRating>()) {
            for row in existing {
                rows[row.assetID] = row
                ratings[row.assetID] = row.value
            }
        }
        if let stored = try? context.fetch(FetchDescriptor<AlbumBaseline>()) {
            for row in stored { baselines[row.key] = row }
        }
        reloadVariants()
    }

    func reloadVariants() {
        guard let rows = try? context.fetch(FetchDescriptor<PhotoVariant>()) else { return }
        variantLabels = Dictionary(rows.map { ($0.assetID, $0.label) },
                                   uniquingKeysWith: { _, latest in latest })
    }

    func variantLabel(for assetID: String) -> String? { variantLabels[assetID] }

    // MARK: - Baselines

    func baseline(_ key: String) -> Set<String> {
        Set(baselines[key]?.memberIDs ?? [])
    }

    private func setBaseline(_ key: String, members: Set<String>) {
        if let row = baselines[key] {
            row.memberIDs = Array(members)
            row.updatedAt = .now
        } else {
            let row = AlbumBaseline(key: key, memberIDs: Array(members))
            context.insert(row)
            baselines[key] = row
        }
        persist()
    }

    /// Folds edits made in Photos back into the store.
    ///
    /// A photo dropped into "LightTable — Picked" by hand becomes picked here;
    /// one dragged out stops being picked. Removals only clear the verdict they
    /// correspond to, so pulling a photo out of the Rejected album can't wipe a
    /// pick it never had.
    private func applyRemote(_ delta: RemoteRatingDelta) {
        guard !delta.isEmpty else { return }
        isApplyingRemote = true
        defer { isApplyingRemote = false }

        for id in delta.pickedAdded { assign(.picked, to: id) }
        for id in delta.rejectedAdded { assign(.rejected, to: id) }
        for id in delta.pickedRemoved where rating(for: id).pick == .picked { assign(.unrated, to: id) }
        for id in delta.rejectedRemoved where rating(for: id).pick == .rejected { assign(.unrated, to: id) }

        revision &+= 1
        persist()
    }

    /// Sets a verdict outright, unlike `setPick` which treats a repeat as undo.
    private func assign(_ pick: Pick, to id: String) {
        var value = ratings[id] ?? .empty
        value.pick = pick
        write(value, for: id)
    }

    func rating(for assetID: String) -> RatingValue {
        ratings[assetID] ?? .empty
    }

    // MARK: - Mutation

    func setPick(_ pick: Pick, for assetIDs: [String]) {
        mutate(assetIDs) { value in
            // Re-applying the same verdict clears it, so P on an already-picked
            // photo reads as "undo" rather than doing nothing.
            value.pick = (value.pick == pick) ? .unrated : pick
        }
    }

    func setColor(_ color: ColorLabel?, for assetIDs: [String]) {
        mutate(assetIDs) { value in
            value.color = (value.color == color) ? nil : color
        }
    }

    func clear(_ assetIDs: [String]) {
        mutate(assetIDs) { $0 = .empty }
    }

    private func mutate(_ ids: [String], _ transform: (inout RatingValue) -> Void) {
        guard !ids.isEmpty else { return }
        for id in ids {
            var value = ratings[id] ?? .empty
            transform(&value)
            write(value, for: id)
        }
        revision &+= 1
        persist()
        scheduleSync()
    }

    private func write(_ value: RatingValue, for id: String) {
        if value.isEmpty {
            ratings.removeValue(forKey: id)
            if let row = rows.removeValue(forKey: id) {
                context.delete(row)
            }
        } else {
            ratings[id] = value
            if let row = rows[id] {
                row.pickRaw = value.pick.rawValue
                row.colorRaw = value.color?.rawValue
                row.updatedAt = .now
            } else {
                let row = AssetRating(assetID: id,
                                      pickRaw: value.pick.rawValue,
                                      colorRaw: value.color?.rawValue)
                context.insert(row)
                rows[id] = row
            }
        }
    }

    /// Cheap: the snapshot is produced later, by the pass itself.
    ///
    /// The guard only suppresses the synchronous re-entry from folding remote
    /// changes in. A later pass may still be scheduled by the view observing
    /// `revision`, which is harmless — reconciliation converges.
    func scheduleSync() {
        guard !isApplyingRemote else { return }
        syncer.schedule()
    }

    private func snapshot() -> SyncSnapshot {
        SyncSnapshot(picked: assetIDs(matching: .picked),
                     rejected: assetIDs(matching: .rejected),
                     pickedBaseline: baseline(AlbumSyncer.globalPickedKey),
                     rejectedBaseline: baseline(AlbumSyncer.globalRejectedKey),
                     events: eventPlans())
    }

    /// Builds a plan per opted-in event.
    ///
    /// Events are fetched from this store's own context rather than handed in by
    /// a view. A SwiftUI `View` is a value recreated on every update, so a
    /// closure captured from one holds a stale copy of its `@Query` results —
    /// which silently yields no events, and therefore no event albums.
    private func eventPlans() -> [EventAlbumPlan] {
        guard let items = itemsProvider?(),
              let events = try? context.fetch(FetchDescriptor<LightTableEvent>()) else { return [] }

        let picked = assetIDs(matching: .picked)
        let synced = events.filter(\.isSyncedToPhotos)

        // Minted here and saved immediately. Left to a later, unrelated save, a
        // crash in between would mean a different key next launch — and every
        // baseline for the event orphaned.
        var mintedKey = false
        for event in synced where event.eventKey == nil {
            event.eventKey = UUID().uuidString
            mintedKey = true
        }
        if mintedKey { persist() }

        pruneBaselines(keeping: synced)
        return synced.map { event in
            let key = "event.\(event.stableKey)"
            let memberIDs = Set(EventMembership.members(of: event, in: items).map(\.id))
            return EventAlbumPlan(
                key: key,
                name: event.name,
                allIDs: memberIDs,
                pickedIDs: memberIDs.intersection(picked),
                allBaseline: baseline("\(key).all"),
                pickedBaseline: baseline("\(key).picked"),
                folderID: event.photosFolderID,
                albumID: event.photosAlbumID,
                pickedAlbumID: event.photosPickedAlbumID,
                persistIdentifiers: { [weak self] folderID, albumID, pickedAlbumID in
                    event.photosFolderID = folderID
                    event.photosAlbumID = albumID
                    event.photosPickedAlbumID = pickedAlbumID
                    self?.persist()
                },
                applyMembershipDelta: { [weak self] added, removed in
                    // Dropping a photo into the event's album in Photos is the
                    // same statement as "Add to Event" here.
                    var pinned = Set(event.pinnedAssetIDs)
                    pinned.formUnion(added)
                    pinned.subtract(removed)
                    event.pinnedAssetIDs = Array(pinned)

                    var excluded = Set(event.excludedAssetIDs)
                    excluded.subtract(added)
                    if !event.isExplicit { excluded.formUnion(removed) }
                    event.excludedAssetIDs = Array(excluded)

                    self?.persist()
                }
            )
        }
    }

    private func persist() {
        do {
            try context.save()
        } catch {
            // A failed save must not take the UI down; in-memory state is still
            // correct and the next mutation retries.
            NSLog("PhotoLightTable: failed to save ratings — \(error)")
        }
    }

    // MARK: - Queries

    func assetIDs(matching pick: Pick) -> Set<String> {
        Set(ratings.compactMap { $0.value.pick == pick ? $0.key : nil })
    }

    func count(of pick: Pick) -> Int {
        ratings.reduce(into: 0) { $0 += ($1.value.pick == pick ? 1 : 0) }
    }

    /// Reconciles with Photos immediately, bypassing the debounce.
    func syncNow() {
        syncer.syncNow()
    }

    /// Drops baseline rows that belong to no current event.
    ///
    /// Needed once because unstable keys orphaned a set on every launch, and
    /// worth keeping so deleting an event doesn't leave its baselines behind.
    private func pruneBaselines(keeping events: [LightTableEvent]) {
        var live: Set<String> = [AlbumSyncer.globalPickedKey, AlbumSyncer.globalRejectedKey]
        for event in events {
            live.insert("event.\(event.stableKey).all")
            live.insert("event.\(event.stableKey).picked")
        }

        let stale = baselines.keys.filter { !live.contains($0) }
        guard !stale.isEmpty else { return }
        for key in stale {
            if let row = baselines.removeValue(forKey: key) { context.delete(row) }
        }
        persist()
    }

    // MARK: - Rebuilding from Photos

    func readImportFromPhotos() -> PhotosImport {
        syncer.readFromPhotos()
    }

    /// Rebuilds events and ratings from what the Photos albums say.
    ///
    /// Merges rather than replaces: album membership is added to what's already
    /// here, and an event whose folder is already known is updated rather than
    /// duplicated. Nothing local is discarded, so running this twice is safe.
    @discardableResult
    func applyImport(_ imported: PhotosImport) -> Int {
        guard !imported.isEmpty else { return 0 }
        let items = itemsProvider?() ?? []
        let datesByID = Dictionary(items.compactMap { item in
            item.creationDate.map { (item.id, $0) }
        }, uniquingKeysWith: { first, _ in first })

        isApplyingRemote = true
        var changed = 0

        for id in imported.picked { assign(.picked, to: id); changed += 1 }
        for id in imported.rejected { assign(.rejected, to: id); changed += 1 }

        let existing = (try? context.fetch(FetchDescriptor<LightTableEvent>())) ?? []
        for imported in imported.events {
            // Match on the folder we created; fall back to the name so a folder
            // the user made by hand is still adopted rather than duplicated.
            let event = existing.first { $0.photosFolderID == imported.folderID }
                ?? existing.first { $0.name == imported.name }
                ?? {
                    let dates = imported.memberIDs.compactMap { datesByID[$0] }.sorted()
                    let new = LightTableEvent(name: imported.name,
                                              startDate: dates.first ?? .now,
                                              endDate: dates.last ?? .now)
                    context.insert(new)
                    return new
                }()

            event.explicitMembership = true
            event.pinnedAssetIDs = Array(imported.memberIDs)
            event.syncsToPhotos = true
            event.photosFolderID = imported.folderID
            event.photosAlbumID = imported.albumID
            event.photosPickedAlbumID = imported.pickedAlbumID

            let dates = imported.memberIDs.compactMap { datesByID[$0] }.sorted()
            if let first = dates.first, let last = dates.last {
                event.startDate = first
                event.endDate = last
            }

            for id in imported.pickedIDs { assign(.picked, to: id) }
            changed += imported.memberIDs.count
        }

        revision &+= 1
        persist()

        // Record what was read as the baseline, so the next reconcile sees the
        // albums as already agreed rather than as a pile of remote additions.
        setBaseline(AlbumSyncer.globalPickedKey, members: imported.picked)
        setBaseline(AlbumSyncer.globalRejectedKey, members: imported.rejected)
        for importedEvent in imported.events {
            guard let event = (try? context.fetch(FetchDescriptor<LightTableEvent>()))?
                .first(where: { $0.photosFolderID == importedEvent.folderID }) else { continue }
            let key = "event.\(event.stableKey)"
            setBaseline("\(key).all", members: importedEvent.memberIDs)
            setBaseline("\(key).picked", members: importedEvent.pickedIDs)
        }

        isApplyingRemote = false
        return changed
    }
}
