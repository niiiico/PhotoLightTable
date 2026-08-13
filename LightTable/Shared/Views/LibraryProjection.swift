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
        var expandedStacks: Set<String>
        var eventsStamp: Int
    }

    private(set) var scoped: [PhotoItem] = []
    private(set) var visible: [PhotoItem] = []
    private(set) var tally = ScopeTally()
    /// Day grouping is O(n log n) over the visible set; it belongs here rather
    /// than in a view body that runs on every selection change.
    private(set) var sections: [DaySection] = []
    /// How many photos each family holds, keyed by the photo standing for it in
    /// the grid. Only present for families with more than one member showing.
    private(set) var stackSizes: [String: Int] = [:]
    /// Members of each family that is currently opened out, source first, in
    /// the order they are laid out. An opened stack is drawn *around* rather
    /// than having each of its photos framed: they are one frame seen several
    /// ways, and a border per cell says the opposite.
    private(set) var openFamilies: [[String]] = []

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
                         expandedStacks: app.expandedStacks,
                         eventsStamp: Self.stamp(of: events))
        guard newKey != key else { return }
        key = newKey

        scoped = app.scope(items, events: events)
        let ordered = app.sort(app.filter(scoped, ratings: ratings))
        let stacked = Self.stacked(ordered,
                                   rootOf: { ratings.rootAsset(of: $0) },
                                   variantsOf: { ratings.variants(of: $0) },
                                   isExpanded: { app.expandedStacks.contains($0) })
        visible = stacked.items
        stackSizes = stacked.sizes
        openFamilies = stacked.openFamilies
        tally = ScopeTally(items: scoped, ratings: ratings)
        sections = PhotoLibraryService.groupByDay(visible,
                                                  oldestFirst: app.sortOrder == .oldestFirst)
    }

    /// Collapses each family of photos sharing a pixel source into one cell,
    /// unless it has been opened out.
    ///
    /// A variant copies its source's creation date so it already sorts into the
    /// same day, but nothing within that day keeps the two together. Rather
    /// than emit them side by side — which makes one frame look like several —
    /// the source stands for the family and carries a count.
    ///
    /// Generic over the lookups rather than taking a `RatingStore`, so the rule
    /// can be exercised without a photo library behind it. The same move as
    /// `TemporalPhoto`.
    ///
    /// A variant whose source is *not* here — filtered out, or in another day —
    /// stays where it fell rather than vanishing with it. Hiding a photo
    /// because its parent is hidden would be a second, invisible filter.
    /// `nonisolated` because it reads nothing but its arguments. The class is
    /// `@MainActor` for the caches it holds; this rule has no such need, and
    /// inheriting the isolation would put it out of reach of a test.
    nonisolated static func stacked<Item: Identifiable>(
        _ items: [Item],
        rootOf: (String) -> String,
        variantsOf: (String) -> [String],
        isExpanded: (String) -> Bool
    ) -> (items: [Item], sizes: [String: Int], openFamilies: [[String]]) where Item.ID == String {
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var emitted = Set<String>()
        var result: [Item] = []
        var sizes: [String: Int] = [:]
        var openFamilies: [[String]] = []
        result.reserveCapacity(items.count)

        for item in items where !emitted.contains(item.id) {
            let root = rootOf(item.id)
            // Held back so it can be shown with its source below.
            if root != item.id, byID[root] != nil { continue }

            result.append(item)
            emitted.insert(item.id)

            // Claimed one at a time rather than filtered in bulk: a family that
            // names the same photo twice would otherwise pass the check twice
            // and emit it twice, and a duplicated id breaks selection and focus
            // rather than merely looking odd.
            var family: [Item] = []
            var claimed = Set<String>()
            for variantID in variantsOf(item.id) {
                guard !emitted.contains(variantID), claimed.insert(variantID).inserted,
                      let variant = byID[variantID] else { continue }
                family.append(variant)
            }
            guard !family.isEmpty else { continue }

            // Counted whether open or closed: the badge says how many photos
            // share these pixels, which is true either way.
            sizes[item.id] = family.count + 1

            if isExpanded(item.id) {
                // The source leads: the outline has to enclose the family
                // opened out, not the variants with their source left outside.
                openFamilies.append([item.id] + family.map(\.id))
                for variant in family {
                    result.append(variant)
                    emitted.insert(variant.id)
                }
            } else {
                for variant in family {
                    emitted.insert(variant.id)
                }
            }
        }

        // Anything held back whose source turned out not to be here after all.
        for item in items where !emitted.contains(item.id) {
            result.append(item)
        }
        return (result, sizes, openFamilies)
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
