#if os(macOS)
import SwiftData
import SwiftUI

/// Turning Lightroom collections into events.
///
/// The catalogue is an archive of a workflow that ended years ago: the files it
/// names live on a disk somewhere, and this app only knows the photo library.
/// So nothing is imported by *file* — each collection's photographs are looked
/// for in the library by the moment they were taken, and what is found becomes
/// an event with fixed membership.
///
/// A collection that finds nothing is not an event worth making, and is dropped
/// from the proposal rather than created empty.
enum LightroomImport {
    struct Plan: Identifiable {
        var id: Int64
        var name: String
        /// Photographs in the library, in the order the collection held them.
        var assetIDs: [String]
        var missing: Int
        /// How far the camera's clock was from the library's idea of the time.
        var offset: TimeInterval

        var total: Int { assetIDs.count + missing }
    }

    struct Proposal {
        var plans: [Plan] = []
        /// Collections where nothing at all was found — worth showing, because
        /// dozens of them means the photographs were never imported rather than
        /// that the matching is broken.
        var empty: [String] = []

        var isEmpty: Bool { plans.isEmpty }
        var photoCount: Int { plans.reduce(0) { $0 + $1.assetIDs.count } }
        var missingCount: Int { plans.reduce(0) { $0 + $1.missing } }

        /// What the confirmation says.
        var message: String {
            guard !isEmpty else {
                return "None of the photographs in that catalogue are in this library."
            }
            return summary + """


                Each collection becomes an event holding exactly the photographs                 that were found. Nothing in Photos is changed.
                """
        }

        var summary: String {
            let found = photoCount
            let missing = missingCount
            var text = "\(plans.count) collection\(plans.count == 1 ? "" : "s"), "
            text += "\(found) photograph\(found == 1 ? "" : "s") found"
            if missing > 0 { text += ", \(missing) not in this library" }
            if !empty.isEmpty { text += ". \(empty.count) collection\(empty.count == 1 ? "" : "s") found nothing" }
            return text + "."
        }
    }

    /// Reads the catalogue and works out what could be made, without making it.
    static func proposal(for catalog: URL, library: [PhotoItem]) throws -> Proposal {
        let collections = try LightroomCatalog.collections(at: catalog)
        let index = LightroomMatch.LibraryIndex(library)

        var proposal = Proposal()
        for collection in collections {
            let outcome = LightroomMatch.match(collection.photos, in: index)
            guard outcome.count > 0 else {
                proposal.empty.append(collection.fullName)
                continue
            }
            // The collection's own order, kept: it is often the order the
            // photographs were arranged in, which is a judgement worth having.
            let assetIDs = collection.photos.compactMap { outcome.matched[$0.localID] }
            proposal.plans.append(Plan(id: collection.id,
                                       name: collection.fullName,
                                       assetIDs: assetIDs,
                                       missing: outcome.unmatched.count,
                                       offset: outcome.offset))
            if Debug.isEnabled { log(collection, outcome) }
        }
        if Debug.isEnabled {
            fputs("[lightroom] \(proposal.summary)\n", stderr)
        }
        return proposal
    }

    /// What a collection came to, in the terms that decide what to do next:
    /// how many were not in the library at all, how many were there but too
    /// alike to choose between, and what the file types of the missing were —
    /// all raws usually means a shoot that was never imported.
    private static func log(_ collection: LightroomCatalog.Collection,
                            _ outcome: LightroomMatch.Outcome) {
        var line = "[lightroom] \(collection.fullName) — "
        line += "\(outcome.count) of \(collection.photos.count) found"

        let hours = outcome.offset / 3600
        if hours != 0 { line += String(format: " (clock %+.1f h)", hours) }
        if outcome.absent > 0 { line += ", \(outcome.absent) absent" }
        if outcome.ambiguous > 0 { line += ", \(outcome.ambiguous) ambiguous" }

        var kinds: [String: Int] = [:]
        for photo in outcome.unmatched {
            let kind = (photo.fileName as NSString).pathExtension.uppercased()
            kinds[kind.isEmpty ? "?" : kind, default: 0] += 1
        }
        if !kinds.isEmpty {
            let listed = kinds.sorted { $0.value > $1.value }
                .prefix(3)
                .map { "\($0.value) \($0.key)" }
                .joined(separator: ", ")
            line += " [missing: \(listed)]"
        }
        fputs(line + "\n", stderr)
    }

    /// Makes an event per plan.
    ///
    /// Fixed membership, because that is what a collection is: a list somebody
    /// made by hand, not everything that happens to fall between two dates.
    @discardableResult
    static func apply(_ proposal: Proposal,
                      library: [PhotoItem],
                      context: ModelContext) -> Int {
        let dateByID = Dictionary(library.compactMap { item in
            item.creationDate.map { (item.id, $0) }
        }, uniquingKeysWith: { first, _ in first })

        for plan in proposal.plans {
            let dates = plan.assetIDs.compactMap { dateByID[$0] }
            let event = LightTableEvent(name: plan.name,
                                        startDate: dates.min() ?? .now,
                                        endDate: dates.max() ?? .now,
                                        pinnedAssetIDs: plan.assetIDs,
                                        explicitMembership: true)
            context.insert(event)
        }
        try? context.save()
        return proposal.plans.count
    }
}
#endif
