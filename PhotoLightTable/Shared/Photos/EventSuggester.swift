import CoreLocation
import Foundation

/// How wide a gap is allowed inside one group of related photos.
///
/// Which one is right depends entirely on what you shot: a wedding reception is
/// one *outing*, a two-week trip is one *trip*. Rather than guess, the app
/// offers all four and shows the resulting count live.
enum ClusterGranularity: String, CaseIterable, Identifiable {
    case session, outing, day, trip

    var id: String { rawValue }

    /// A new group starts when consecutive photos are further apart than this.
    var maximumGap: TimeInterval {
        switch self {
        case .session: return 60 * 60 * 2      // a ceremony, a golden hour
        case .outing: return 60 * 60 * 8       // a day out, a shoot
        case .day: return 60 * 60 * 20         // overnight break
        case .trip: return 60 * 60 * 48        // a holiday with quiet days
        }
    }

    var label: String {
        switch self {
        case .session: return "Session"
        case .outing: return "Outing"
        case .day: return "Day"
        case .trip: return "Trip"
        }
    }

    /// The next looser setting, or nil at the widest.
    var next: ClusterGranularity? {
        switch self {
        case .session: return .outing
        case .outing: return .day
        case .day: return .trip
        case .trip: return nil
        }
    }

    var help: String {
        switch self {
        case .session: return "Breaks whenever you stopped shooting for 2 hours."
        case .outing: return "One outing or shoot; breaks after 8 hours."
        case .day: return "Breaks overnight, so each day stays together."
        case .trip: return "Whole trips, tolerating up to 2 quiet days."
        }
    }
}

/// The part of a photo that clustering actually looks at.
///
/// Grouping is a question about clocks and places, so it is expressed over the
/// two fields that answer it rather than over `PhotoItem`. That keeps the rules
/// exercisable without a `PHAsset` behind every item — there is no way to make
/// a `PHAsset` with a chosen date, so a concrete parameter would make the whole
/// of this file reachable only against a real photo library.
protocol TemporalPhoto: Identifiable where ID == String {
    var id: String { get }
    var creationDate: Date? { get }
    var location: CLLocation? { get }
}

extension PhotoItem: TemporalPhoto {}

enum EventSuggester {
    /// Photos taken more than this far apart are treated as a different place
    /// even when they're close in time — a flight or a drive splits the group.
    private static let maximumDistance: CLLocationDistance = 60_000

    /// Splits photos into runs of temporally (and geographically) adjacent shots.
    /// Input order doesn't matter; output is oldest group first, each group
    /// sorted oldest first.
    static func clusters<Item: TemporalPhoto>(in items: [Item],
                                              granularity: ClusterGranularity) -> [[Item]] {
        let dated = items
            .filter { $0.creationDate != nil }
            .sorted { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
        guard !dated.isEmpty else { return [] }

        var groups: [[Item]] = []
        var current: [Item] = [dated[0]]

        for item in dated.dropFirst() {
            if shouldSplit(previous: current[current.count - 1],
                           next: item,
                           granularity: granularity) {
                groups.append(current)
                current = [item]
            } else {
                current.append(item)
            }
        }
        groups.append(current)
        return groups
    }

    private static func shouldSplit<Item: TemporalPhoto>(previous: Item,
                                                         next: Item,
                                                         granularity: ClusterGranularity) -> Bool {
        guard let previousDate = previous.creationDate,
              let nextDate = next.creationDate else { return false }

        if nextDate.timeIntervalSince(previousDate) > granularity.maximumGap { return true }

        // A big jump in location means a new place even if the clock says
        // otherwise. Only consulted when both photos actually have a fix.
        if let a = previous.location, let b = next.location,
           a.distance(from: b) > maximumDistance {
            return true
        }
        return false
    }

    /// Grows a set of seed photos outward to every photo in the same group(s).
    /// Seeds spanning two groups pull in both, which is what the user means when
    /// they select across a boundary they disagree with.
    static func related<Item: TemporalPhoto>(to seedIDs: some Collection<String>,
                                             in items: [Item],
                                             granularity: ClusterGranularity) -> [Item] {
        guard !seedIDs.isEmpty else { return [] }
        let seeds = Set(seedIDs)
        let matching = clusters(in: items, granularity: granularity)
            .filter { group in group.contains { seeds.contains($0.id) } }
        return matching.flatMap { $0 }
    }

    /// Inclusive day-granularity bounds covering `items`.
    static func dateRange<Item: TemporalPhoto>(of items: [Item]) -> (start: Date, end: Date)? {
        let dates = items.compactMap(\.creationDate).sorted()
        guard let first = dates.first, let last = dates.last else { return nil }
        return (first, last)
    }
}
