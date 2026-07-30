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
                         eventsStamp: Self.stamp(of: events))
        guard newKey != key else { return }
        key = newKey

        scoped = app.scope(items, events: events)
        visible = app.sort(app.filter(scoped, ratings: ratings))
        tally = ScopeTally(items: scoped, ratings: ratings)
        sections = PhotoLibraryService.groupByDay(visible,
                                                  oldestFirst: app.sortOrder == .oldestFirst)
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
