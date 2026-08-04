import Foundation
import SwiftUI

/// Memoises the expensive derivations from the library: what's in scope, what
/// survives the filter, and the tally.
///
/// Each is O(library), and the view needs all three several times per body
/// evaluation. Worse, they were recomputed on *selection* changes too — which
/// during a drag means several full passes over 90k photos per frame. Nothing
/// here depends on the selection, so the cache key deliberately excludes it.
@MainActor
final class LibraryProjection: ObservableObject {
    private struct Key: Equatable {
        var selection: LibrarySelection
        var pickFilter: PickFilter
        var colorFilter: Set<ColorLabel>
        var sortOrder: PhotoSortOrder
        var libraryVersion: Int
        var ratingsRevision: Int
        var variantsRevision: Int
        var eventsStamp: Int
    }

    private(set) var scoped: [PhotoItem] = []
    private(set) var visible: [PhotoItem] = []
    private(set) var tally = ScopeTally()
    /// Day grouping is O(n log n) over the visible set; it belongs here rather
    /// than in a view body that runs on every selection change.
    private(set) var sections: [DaySection] = []

    private var key: Key?

    func refresh(items: [PhotoItem],
                 libraryVersion: Int,
                 events: [LightTableEvent],
                 app: AppModel,
                 ratings: RatingStore) {
        let newKey = Key(selection: app.selection,
                         pickFilter: app.pickFilter,
                         colorFilter: app.colorFilter,
                         sortOrder: app.sortOrder,
                         libraryVersion: libraryVersion,
                         ratingsRevision: ratings.revision,
                         variantsRevision: ratings.variantsRevision,
                         eventsStamp: Self.stamp(of: events))
        guard newKey != key else { return }
        key = newKey

        scoped = app.scope(items, events: events)
        visible = Self.grouped(app.sort(app.filter(scoped, ratings: ratings)), ratings: ratings)
        tally = ScopeTally(items: scoped, ratings: ratings)
        sections = PhotoLibraryService.groupByDay(visible,
                                                  oldestFirst: app.sortOrder == .oldestFirst)
    }

    /// Keeps photos made from the same pixels next to each other.
    ///
    /// A variant copies its source's creation date so it already sorts into the
    /// same day, but within that day nothing keeps the two adjacent. Emitting a
    /// source together with its variants makes the relationship visible in the
    /// grid rather than something to be inferred from a badge.
    ///
    /// A variant whose source is filtered out stays where it fell — hiding it
    /// because its parent is hidden would be a second, invisible filter.
    private static func grouped(_ items: [PhotoItem], ratings: RatingStore) -> [PhotoItem] {
        guard !ratings.variantLabels.isEmpty else { return items }

        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var emitted = Set<String>()
        var result: [PhotoItem] = []
        result.reserveCapacity(items.count)

        for item in items where !emitted.contains(item.id) {
            let root = ratings.rootAsset(of: item.id)
            // Held back so it can follow its source below.
            if root != item.id, byID[root] != nil { continue }

            result.append(item)
            emitted.insert(item.id)

            for variantID in ratings.variants(of: item.id) {
                guard let variant = byID[variantID], !emitted.contains(variantID) else { continue }
                result.append(variant)
                emitted.insert(variantID)
            }
        }

        // Anything held back whose source turned out not to be here after all.
        for item in items where !emitted.contains(item.id) {
            result.append(item)
        }
        return result
    }

    /// Cheap structural summary of the events, so edits to a date range or to
    /// membership invalidate the cache without needing a change counter
    /// threaded through every mutation site.
    private static func stamp(of events: [LightTableEvent]) -> Int {
        var hasher = Hasher()
        hasher.combine(events.count)
        for event in events {
            hasher.combine(event.name)
            hasher.combine(event.startDate)
            hasher.combine(event.endDate)
            hasher.combine(event.pinnedAssetIDs.count)
            hasher.combine(event.excludedAssetIDs.count)
            hasher.combine(event.isExplicit)
        }
        return hasher.finalize()
    }
}
