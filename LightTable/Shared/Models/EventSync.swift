import Foundation

/// Keeping imported events in step with a catalogue that changes.
///
/// An import adds, and adding is not synchronising: a collection deleted in
/// Lightroom leaves an event behind that stands for nothing. Telling those from
/// the events somebody made by hand needs provenance rather than a guess about
/// names — an event called `Trips / Corsica` may be either.
enum EventSync {
    /// Members an event should lose when it is made to match its collection.
    ///
    /// Not simply "everything the run did not match": a photograph the run
    /// failed to place is not a photograph the collection has given up. The
    /// matcher refuses whatever it cannot be sure of — a second holding two
    /// frames of the same shape, a raw whose JPEG is beside it, a frame hidden
    /// while the run was measuring — and treating those as deletions would take
    /// photographs out of an event for being hard to identify.
    ///
    /// So a member survives if the collection still holds *something taken at
    /// that moment*, whether or not this run could say which. Only a member the
    /// collection has nothing at all at is genuinely gone.
    static func removable(members: [String],
                          matched: Set<String>,
                          collectionSeconds: Set<Int>,
                          secondOf: (String) -> Int?) -> [String] {
        members.filter { member in
            guard !matched.contains(member) else { return false }
            guard let second = secondOf(member) else { return true }
            return !collectionSeconds.contains(second)
        }
    }

    /// Events that came from a catalogue which no longer holds their
    /// collection.
    ///
    /// Only events carrying a path are considered, so nothing made here is ever
    /// a candidate for removal, however much its name looks like a catalogue's.
    static func vanished<Event>(_ events: [Event],
                                origin: (Event) -> String?,
                                catalogPaths: Set<String>) -> [Event] {
        events.filter { event in
            guard let path = origin(event) else { return false }
            return !catalogPaths.contains(path)
        }
    }
}
