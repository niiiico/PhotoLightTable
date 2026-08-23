import Foundation

/// Events that hold exactly the same photographs as another.
///
/// Renaming a collection in Lightroom used to produce one: the import did not
/// recognise the new name, made a second event beside the first, and left the
/// old one behind for ever. Identity fixes that going forward and does nothing
/// about the copies already made — this finds them.
///
/// Identical membership, not similar: two events holding the same photographs in
/// the same set are the same event by any useful definition, while two that
/// merely overlap are a judgement nobody asked this to make.
enum EventDuplicates {
    /// The copies worth removing, keeping one of each set.
    ///
    /// What is kept is the one the catalogue still knows — an event carrying
    /// provenance — and failing that the one whose name matches a collection
    /// that exists, and failing that the first, so the answer never depends on
    /// the order a database happened to return rows in.
    static func redundant<Event: Identifiable>(
        _ events: [Event],
        members: (Event) -> [String],
        isKnownToCatalogue: (Event) -> Bool,
        name: (Event) -> String,
        catalogNames: Set<String>
    ) -> [Event] {
        var groups: [Set<String>: [Event]] = [:]
        for event in events {
            let held = Set(members(event))
            guard !held.isEmpty else { continue }
            groups[held, default: []].append(event)
        }

        var redundant: [Event] = []
        for (_, group) in groups where group.count > 1 {
            let keeper = group.first(where: isKnownToCatalogue)
                ?? group.first { catalogNames.contains(name($0)) }
                ?? group[0]
            redundant.append(contentsOf: group.filter { $0.id != keeper.id })
        }
        return redundant
    }
}
