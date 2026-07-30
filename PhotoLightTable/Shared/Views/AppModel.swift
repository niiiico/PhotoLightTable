import Foundation
import SwiftData
import SwiftUI

enum PickFilter: String, CaseIterable, Identifiable {
    case all, picked, rejected, unrated

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "All"
        case .picked: return "Picked"
        case .rejected: return "Rejected"
        case .unrated: return "Unrated"
        }
    }
}

enum LibrarySelection: Hashable {
    case allPhotos
    case event(PersistentIdentifier)
}

enum PhotoSortOrder: String, CaseIterable, Identifiable {
    case oldestFirst, newestFirst

    var id: String { rawValue }

    var label: String {
        switch self {
        case .oldestFirst: return "Oldest first"
        case .newestFirst: return "Newest first"
        }
    }

    var symbolName: String {
        switch self {
        case .oldestFirst: return "arrow.up"
        case .newestFirst: return "arrow.down"
        }
    }
}

/// View-layer state: what's selected, what's filtered, how big the cells are.
/// Deliberately separate from `RatingStore`, which owns persisted judgements.
@MainActor
final class AppModel: ObservableObject {
    @Published var selection: LibrarySelection = .allPhotos {
        didSet {
            // Each scope carries its own natural order, so a manual override
            // shouldn't leak across when you switch to a different event.
            if selection != oldValue { sortOverride = nil }
        }
    }
    /// Set only when the user picks an order by hand; otherwise the scope decides.
    @Published var sortOverride: PhotoSortOrder?
    @Published var pickFilter: PickFilter = .all
    @Published var colorFilter: Set<ColorLabel> = []
    @Published var thumbnailSize: Double = 180
    @Published var isLoupePresented = false
    /// Looseness used by the "select related" shortcut in the grid.
    @Published var relatedGranularity: ClusterGranularity = .day

    /// Multi-selection in the grid, in the order the user built it.
    @Published var selectedIDs: Set<String> = []
    /// The cell the keyboard acts on and that anchors shift-range selection.
    @Published var focusID: String?

    /// Number of columns the grid last laid out, so up/down arrows can move a row.
    var columnCount: Int = 1

    var hasActiveFilter: Bool { pickFilter != .all || !colorFilter.isEmpty }

    /// An event reads as a story, so it runs forwards; the whole library reads as
    /// a feed, so the most recent work is at the top.
    var defaultSortOrder: PhotoSortOrder {
        switch selection {
        case .allPhotos: return .newestFirst
        case .event: return .oldestFirst
        }
    }

    var sortOrder: PhotoSortOrder { sortOverride ?? defaultSortOrder }

    func resetFilters() {
        pickFilter = .all
        colorFilter = []
    }

    func toggleColorFilter(_ color: ColorLabel) {
        if colorFilter.contains(color) { colorFilter.remove(color) }
        else { colorFilter.insert(color) }
    }

    /// Assets the keyboard shortcuts apply to: the multi-selection if there is
    /// one, otherwise just the focused cell.
    func targetIDs() -> [String] {
        if !selectedIDs.isEmpty { return Array(selectedIDs) }
        if let focusID { return [focusID] }
        return []
    }

    // MARK: - Filtering

    func filter(_ items: [PhotoItem], ratings: RatingStore) -> [PhotoItem] {
        guard hasActiveFilter else { return items }
        return items.filter { item in
            let rating = ratings.rating(for: item.id)
            switch pickFilter {
            case .all: break
            case .picked: if rating.pick != .picked { return false }
            case .rejected: if rating.pick != .rejected { return false }
            case .unrated: if rating.pick != .unrated { return false }
            }
            if !colorFilter.isEmpty {
                guard let color = rating.color, colorFilter.contains(color) else { return false }
            }
            return true
        }
    }

    /// Applies the current order.
    ///
    /// `PhotoLibraryService` fetches sorted by creation date descending, and both
    /// `scope` and `filter` preserve order, so the input is always newest-first
    /// already. That makes this a reverse rather than a re-sort — O(n) instead of
    /// O(n log n) on every redraw, which matters while dragging the size slider.
    func sort(_ items: [PhotoItem]) -> [PhotoItem] {
        sortOrder == .oldestFirst ? Array(items.reversed()) : items
    }

    /// Narrows the library to whatever the sidebar has selected.
    func scope(_ items: [PhotoItem], events: [LightTableEvent]) -> [PhotoItem] {
        switch selection {
        case .allPhotos:
            return items
        case .event(let id):
            guard let event = events.first(where: { $0.persistentModelID == id }) else { return [] }
            return EventMembership.members(of: event, in: items)
        }
    }

    // MARK: - Navigation

    func move(by offset: Int, in items: [PhotoItem], extendSelection: Bool) {
        guard !items.isEmpty else { return }
        let currentIndex = focusID.flatMap { id in items.firstIndex { $0.id == id } } ?? -1
        let target = max(0, min(items.count - 1, currentIndex + offset))
        // A first keypress with nothing focused should land on the first cell,
        // not offset away from it.
        let index = currentIndex < 0 ? 0 : target
        let item = items[index]
        focusID = item.id
        if extendSelection {
            selectedIDs.insert(item.id)
        } else {
            selectedIDs = [item.id]
        }
    }

    func selectAll(_ items: [PhotoItem]) {
        selectedIDs = Set(items.map(\.id))
    }

    /// Selects everything between two photos in display order, as dragging
    /// across the grid does.
    ///
    /// `addingTo` is the selection as it stood when the drag began. Unioning
    /// against that rather than against the live selection means shrinking the
    /// drag back releases photos again, instead of the run only ever growing.
    func selectRange(from anchorID: String,
                     to targetID: String,
                     in items: [PhotoItem],
                     addingTo base: Set<String>? = nil) {
        guard let from = items.firstIndex(where: { $0.id == anchorID }),
              let to = items.firstIndex(where: { $0.id == targetID }) else { return }
        let range = from <= to ? from...to : to...from

        var ids = Set(items[range].map(\.id))
        if let base { ids.formUnion(base) }
        selectedIDs = ids
        focusID = targetID
    }

    /// Grows the selection to everything shot around the same time and place.
    /// Repeating it widens the net one granularity at a time, so a photo can be
    /// expanded from its session up to the whole trip by pressing R again.
    @discardableResult
    func selectRelated(in items: [PhotoItem]) -> Int {
        let seeds = targetIDs()
        guard !seeds.isEmpty else { return 0 }

        let group = EventSuggester.related(to: seeds, in: items, granularity: relatedGranularity)
        let ids = Set(group.map(\.id))

        // Already covered by this granularity? Widen instead of doing nothing.
        if ids == selectedIDs, let wider = relatedGranularity.next {
            relatedGranularity = wider
            return selectRelated(in: items)
        }

        selectedIDs = ids
        if focusID == nil { focusID = group.first?.id }
        return ids.count
    }

    func click(_ item: PhotoItem, in items: [PhotoItem], modifiers: EventModifiers) {
        if modifiers.contains(.command) {
            if selectedIDs.contains(item.id) { selectedIDs.remove(item.id) }
            else { selectedIDs.insert(item.id) }
            focusID = item.id
        } else if modifiers.contains(.shift), let anchor = focusID,
                  let from = items.firstIndex(where: { $0.id == anchor }),
                  let to = items.firstIndex(where: { $0.id == item.id }) {
            let range = from <= to ? from...to : to...from
            selectedIDs.formUnion(items[range].map(\.id))
        } else {
            selectedIDs = [item.id]
            focusID = item.id
        }
    }
}
