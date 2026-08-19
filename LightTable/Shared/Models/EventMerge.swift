import Foundation

/// Folding a fresh import into an event that already exists.
///
/// The catalogue is imported more than once on purpose: photographs arrive in
/// the library in batches, and each run finds more of what a collection was
/// always talking about. So a second run has to add to the event it made the
/// first time rather than making another one beside it.
enum EventMerge {
    /// The members an event should hold after an import.
    ///
    /// A union, in a deliberate order: what the event already held stays where
    /// it was, and what the run found is appended. Two reasons for union rather
    /// than replacement — a photograph that stopped matching has usually not
    /// left the library, it is a frame whose neighbour got hidden or whose file
    /// was replaced; and an event is somebody's list, which an import has no
    /// business shortening.
    static func merged(existing: [String], incoming: [String]) -> [String] {
        var seen = Set(existing)
        var result = existing
        for id in incoming where seen.insert(id).inserted {
            result.append(id)
        }
        return result
    }

    /// Whether merging would change anything, so a run that finds nothing new
    /// can say so instead of touching the store.
    static func adds(existing: [String], incoming: [String]) -> Int {
        let held = Set(existing)
        return Set(incoming).subtracting(held).count
    }
}
