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

    /// Set while folding remote changes in, so applying them doesn't schedule
    /// another sync and bounce the same edit back at Photos.
    private var isApplyingRemote = false

    /// Event plans are assembled by the view layer, which knows about events;
    /// this keeps the most recent set so a rating change can re-sync them too.
    var eventPlanProvider: (() -> [EventAlbumPlan])?

    init(context: ModelContext, syncer: AlbumSyncer) {
        self.context = context
        self.syncer = syncer
        load()

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
    }

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

    func scheduleSync() {
        guard !isApplyingRemote else { return }
        syncer.schedule(snapshot())
    }

    private func snapshot() -> SyncSnapshot {
        SyncSnapshot(picked: assetIDs(matching: .picked),
                     rejected: assetIDs(matching: .rejected),
                     pickedBaseline: baseline(AlbumSyncer.globalPickedKey),
                     rejectedBaseline: baseline(AlbumSyncer.globalRejectedKey),
                     events: eventPlanProvider?() ?? [])
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
        syncer.syncNow(snapshot())
    }
}
