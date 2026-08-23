import Foundation

/// Recognising an event as a collection it has drifted away from.
///
/// Events made by an import are named after their collection, and matching them
/// by name works right up until somebody tidies up: move an event into another
/// folder here — which is a rename — and the next import no longer recognises
/// it, so it makes a second one beside it. That is the opposite of
/// synchronising.
///
/// What does not drift is what is in them. An event that holds the same
/// photographs as a collection is that collection, whatever either is called.
enum EventProvenance {
    /// How much of each side the two must share to be called the same thing.
    ///
    /// Both ways round, deliberately. A hand-made event of twelve picks from a
    /// four-hundred-frame shoot is entirely inside that collection, and is not
    /// that collection — requiring the collection to be mostly inside the event
    /// as well is what tells them apart.
    static let threshold = 0.75

    /// Pairs a collection with the event that already holds its photographs.
    ///
    /// Only events offered as candidates are considered — the caller passes
    /// those with no provenance and no name match — and each event is claimed
    /// at most once, by the collection it overlaps most.
    static func adopt<Event: Identifiable>(
        collections: [(id: Int64, members: [String])],
        candidates: [Event],
        members: (Event) -> [String]
    ) -> [Int64: Event.ID] {
        var byEvent: [Event.ID: (collection: Int64, score: Double)] = [:]

        for collection in collections {
            let wanted = Set(collection.members)
            guard !wanted.isEmpty else { continue }

            for candidate in candidates {
                let held = Set(members(candidate))
                guard !held.isEmpty else { continue }

                let shared = Double(held.intersection(wanted).count)
                let ofEvent = shared / Double(held.count)
                let ofCollection = shared / Double(wanted.count)
                guard ofEvent >= threshold, ofCollection >= threshold else { continue }

                let score = min(ofEvent, ofCollection)
                if let existing = byEvent[candidate.id], existing.score >= score { continue }
                byEvent[candidate.id] = (collection.id, score)
            }
        }

        // Inverted at the end so one collection cannot claim two events, and
        // the pairing is a function either way round.
        var byCollection: [Int64: (event: Event.ID, score: Double)] = [:]
        for (event, claim) in byEvent {
            if let existing = byCollection[claim.collection], existing.score >= claim.score { continue }
            byCollection[claim.collection] = (event, claim.score)
        }
        return byCollection.mapValues(\.event)
    }
}
