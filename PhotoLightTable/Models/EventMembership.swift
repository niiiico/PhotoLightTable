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
}
