import Foundation

/// Whether an event still takes its name from the collection it came from.
///
/// Renaming a collection in Lightroom should rename its event here — that is
/// what makes the two one thing rather than two lists that started out alike.
/// But renaming an event *here* has to stick, or the app is arguing with the
/// person using it.
///
/// Both, from one fact: the name the event was given at import is kept beside
/// it. While the event still has that name, nobody here has touched it and the
/// catalogue may rename it at will. The moment they differ, the name is the
/// owner's and no import will overwrite it.
enum EventNaming {
    static func followsCatalogue(name: String, importedAs: String?) -> Bool {
        guard let importedAs else { return false }
        return name == importedAs
    }

    /// What an event should be called after an import, which is either the
    /// collection's current path or exactly what it is called now.
    static func name(for event: (name: String, importedAs: String?),
                     collection path: String) -> String {
        followsCatalogue(name: event.name, importedAs: event.importedAs) ? path : event.name
    }
}
