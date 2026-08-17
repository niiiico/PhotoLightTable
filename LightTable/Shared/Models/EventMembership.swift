import Foundation

/// Resolves which photos belong to an event.
///
/// Lives outside the model because both the UI and the album syncer need it, and
/// because doing it in bulk requires hoisting the pinned/excluded arrays into
/// sets — testing them per photo would rescan them once per asset in the library.
enum EventMembership {
    static func members(of event: LightTableEvent, in items: [PhotoItem]) -> [PhotoItem] {
        let pinned = Set(event.pinnedAssetIDs)

        if event.isExplicit {
            return items.filter { pinned.contains($0.id) }
        }

        let excluded = Set(event.excludedAssetIDs)
        let interval = event.dateInterval
        return items.filter { item in
            if pinned.contains(item.id) { return true }
            if excluded.contains(item.id) { return false }
            guard let date = item.creationDate else { return false }
            return interval.contains(date)
        }
    }

    /// Cheap structural summary of the events, so a change to a date range or to
    /// membership invalidates a cache keyed on it without a change counter
    /// threaded through every mutation site.
    static func stamp(of events: [LightTableEvent]) -> Int {
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
