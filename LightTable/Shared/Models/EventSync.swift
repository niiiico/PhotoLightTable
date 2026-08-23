import Foundation

/// Keeping imported events in step with a catalogue that changes.
///
/// An import adds, and adding is not synchronising: a collection deleted in
/// Lightroom leaves an event behind that stands for nothing. Telling those from
/// the events somebody made by hand needs provenance rather than a guess about
/// names — an event called `Trips / Corsica` may be either.
enum EventSync {
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
