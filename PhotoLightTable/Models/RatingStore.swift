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

    init(context: ModelContext, syncer: AlbumSyncer) {
        self.context = context
        self.syncer = syncer
        load()
    }

    private func load() {
        let descriptor = FetchDescriptor<AssetRating>()
        guard let existing = try? context.fetch(descriptor) else { return }
        for row in existing {
            rows[row.assetID] = row
            ratings[row.assetID] = row.value
        }
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
        revision &+= 1
        persist()
        syncer.scheduleSync(picked: assetIDs(matching: .picked),
                            rejected: assetIDs(matching: .rejected))
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

    /// Pushes current state to Photos immediately, bypassing the debounce.
    func syncNow() {
        syncer.syncNow(picked: assetIDs(matching: .picked),
                       rejected: assetIDs(matching: .rejected))
    }
}
