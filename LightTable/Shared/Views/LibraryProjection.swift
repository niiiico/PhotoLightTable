import Foundation
import SwiftUI

/// The timeline rail's scale, and the day sizes behind it.
struct TimelineData {
    var ticks: [TimelineIndex.Tick] = []
    /// Photographs per day section, in display order — what a fraction of the
    /// way down the rail is measured against.
    var counts: [Int] = []
}

/// Memoises the expensive derivations from the library: what's in scope, what
/// survives the filter, and the tally.
///
/// Each is O(library), and the view needs all three several times per body
/// evaluation. Worse, they were recomputed on *selection* changes too — which
/// during a drag means several full passes over 90k photos per frame. Nothing
/// here depends on the selection, so the cache key deliberately excludes it.
@MainActor
final class LibraryProjection: ObservableObject {
    /// What the grid's contents depend on.
    ///
    /// The verdicts are in here only when a filter is reading them. Otherwise
    /// picking a photograph changes nothing about which photographs are shown
    /// or how they are grouped — and rebuilding all of that on every P and X,
    /// which is what including the revision unconditionally meant, is half a
    /// second of the culling rhythm gone.
    private struct StructureKey: Equatable {
        var selection: LibrarySelection
        var pickFilter: PickFilter
        var showsOnlyFamilies: Bool
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

    /// The span the visible grid covers, oldest to newest, for anything that
    /// has to offer a date inside it.
    private(set) var dateBounds: ClosedRange<Date>?

    /// The scale down the side of the grid, and the day sizes it is drawn from.
    ///
    /// Here rather than in the view: building it walks every day section
    /// pulling calendar components out, and the grid's body runs whenever a
    /// cell scrolls into view. It changes only when the sections do.
    private(set) var timeline = TimelineData()

    /// The ids in scope, for counting verdicts against without walking the
    /// library again.
    private var scopedIDs: Set<String> = []

    private var structureKey: StructureKey?
    private var tallyKey: (structure: StructureKey, ratingsRevision: Int)?

    func refresh(items: [PhotoItem],
                 libraryVersion: Int,
                 events: [LightTableEvent],
                 app: AppModel,
                 ratings: RatingStore) {
        // Only a filter that reads verdicts makes the contents depend on them.
        let filterReadsVerdicts = app.pickFilter != .all || !app.colorFilter.isEmpty
        let newKey = StructureKey(selection: app.selection,
                                  pickFilter: app.pickFilter,
                                  showsOnlyFamilies: app.showsOnlyFamilies,
                                  colorFilter: app.colorFilter,
                                  sortOrder: app.sortOrder,
                                  libraryVersion: libraryVersion,
                                  ratingsRevision: filterReadsVerdicts ? ratings.revision : 0,
                                  variantsRevision: ratings.variantsRevision,
                                  expandedStacks: app.expandedStacks,
                                  eventsStamp: EventMembership.stamp(of: events))

        if newKey != structureKey {
            structureKey = newKey
            rebuild(items: items, events: events, app: app, ratings: ratings)
        }

        // Cheap, and the only thing a verdict actually changes when no filter
        // is reading them.
        let newTallyKey = (newKey, ratings.revision)
        if tallyKey == nil || tallyKey! != newTallyKey {
            tallyKey = newTallyKey
            tally = ScopeTally(total: scoped.count,
                               scopedIDs: scopedIDs,
                               verdicts: ratings.ratings)
        }
    }

    private func rebuild(items: [PhotoItem],
                         events: [LightTableEvent],
                         app: AppModel,
                         ratings: RatingStore) {
        Debug.time("scope") { scoped = app.scope(items, events: events) }
        let ordered = Debug.time("filter+sort") { app.sort(app.filter(scoped, ratings: ratings)) }
        Debug.time("scoped ids") { scopedIDs = Set(scoped.map(\.id)) }
        let stacked = Debug.time("stack") {
            Self.stacked(ordered,
                         isFamilyMember: { ratings.isInFamily($0) },
                         rootOf: { ratings.rootAsset(of: $0) },
                         variantsOf: { ratings.variants(of: $0) },
                         isExpanded: { app.expandedStacks.contains($0) })
        }
        visible = stacked.items
        stackSizes = stacked.sizes
        openFamilies = stacked.openFamilies
        Debug.time("group by day") {
            sections = PhotoLibraryService.groupByDay(visible,
                                                      oldestFirst: app.sortOrder == .oldestFirst)
        }
        Debug.time("timeline") {
        timeline = TimelineData(ticks: TimelineIndex.ticks(for: sections.map { ($0.id, $0.items.count) }),
                                counts: sections.map(\.items.count))
        }
        // Taken from the ends rather than by scanning: the sections are already
        // sorted, whichever way round.
        if let first = sections.first?.id, let last = sections.last?.id {
            dateBounds = min(first, last)...max(first, last)
        } else {
            dateBounds = nil
        }
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
    /// `isFamilyMember` is asked first about every photograph, and nearly all
    /// of them answer no: in a library of ninety thousand, a few dozen have
    /// variants. Indexing all of them by id — which is what this did — cost a
    /// third of a second on every album change and every keystroke that
    /// invalidated the grid. Only what can possibly stack is indexed now, and
    /// everything else goes straight through.
    nonisolated static func stacked<Item: Identifiable>(
        _ items: [Item],
        isFamilyMember: (String) -> Bool,
        rootOf: (String) -> String,
        variantsOf: (String) -> [String],
        isExpanded: (String) -> Bool
    ) -> (items: [Item], sizes: [String: Int], openFamilies: [[String]]) where Item.ID == String {
        var byID: [String: Item] = [:]
        for item in items where isFamilyMember(item.id) {
            // First wins, as before: a duplicated id would otherwise change
            // which photo stands for the family.
            if byID[item.id] == nil { byID[item.id] = item }
        }
        // Nothing here shares its pixels with anything else: the grid is the
        // list it was handed.
        guard !byID.isEmpty else { return (items, [:], []) }

        var emitted = Set<String>()
        var result: [Item] = []
        var sizes: [String: Int] = [:]
        var openFamilies: [[String]] = []
        result.reserveCapacity(items.count)

        for item in items {
            // Not in a family: it stands for itself, wherever it fell.
            guard isFamilyMember(item.id) else {
                result.append(item)
                continue
            }
            guard !emitted.contains(item.id) else { continue }
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
        for item in items where isFamilyMember(item.id) && !emitted.contains(item.id) {
            result.append(item)
        }
        return (result, sizes, openFamilies)
    }
}
