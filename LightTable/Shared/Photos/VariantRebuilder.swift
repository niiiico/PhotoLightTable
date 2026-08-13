import Foundation
import Photos
import SwiftData

/// Recovers families of photos that share a pixel source, when the records that
/// described them are gone.
///
/// Photos itself records nothing about one asset being made from another —
/// `PHAsset` has no parent, and there is no duplicate-detection API. So the
/// relationship normally lives only in this app's store, and losing it loses
/// the families. This puts them back.
///
/// It works because a copy made here is the source's file **copied verbatim**:
/// same bytes, and `creationDate` and `location` deliberately carried over so
/// the variant sorts beside its original. Two assets that agree on all of that
/// are not similar photographs — they are the same photograph twice.
///
/// Direction comes from `addedDate`: `creationDate` is copied, so it cannot say
/// which came first, but the date an asset entered the library is its own. The
/// one added earliest is the original.
enum VariantRebuilder {
    /// What the matcher needs to know about a photo. Nothing here requires
    /// opening a file.
    struct Candidate: Equatable {
        let id: String
        /// Copied verbatim onto a variant, so family members agree exactly.
        let creationDate: Date?
        /// Original filename and pixel dimensions of the primary resource —
        /// enough to separate two photos that merely share a timestamp.
        let signature: String
        /// When the asset entered the library, which a copy does not inherit.
        let addedDate: Date?
    }

    struct Family: Equatable {
        let rootID: String
        let variantIDs: [String]
    }

    /// Groups candidates into families.
    ///
    /// `known` holds every photo already accounted for by an existing record.
    /// A family touching any of them is left alone: the store is the better
    /// authority where it still has an answer, and re-deriving over the top of
    /// it could rename or re-parent something the user set deliberately.
    static func families(from candidates: [Candidate], known: Set<String>) -> [Family] {
        // Two photos can only be the same photograph if they agree on both the
        // moment and the file. Grouping on the pair costs one pass.
        var buckets: [String: [Candidate]] = [:]
        for candidate in candidates {
            guard let creationDate = candidate.creationDate else { continue }
            let key = "\(creationDate.timeIntervalSinceReferenceDate)#\(candidate.signature)"
            buckets[key, default: []].append(candidate)
        }

        var families: [Family] = []
        for (_, members) in buckets where members.count > 1 {
            guard !members.contains(where: { known.contains($0.id) }) else { continue }

            // Earliest into the library is the original. An unknown added date
            // sorts last rather than winning by accident.
            let ordered = members.sorted { lhs, rhs in
                switch (lhs.addedDate, rhs.addedDate) {
                case let (left?, right?): return left == right ? lhs.id < rhs.id : left < right
                case (nil, _?): return false
                case (_?, nil): return true
                case (nil, nil): return lhs.id < rhs.id
                }
            }
            families.append(Family(rootID: ordered[0].id,
                                   variantIDs: Array(ordered.dropFirst()).map(\.id)))
        }

        // Stable output, so the same library always proposes the same thing.
        return families.sorted { $0.rootID < $1.rootID }
    }
}

@MainActor
extension VariantRebuilder {
    /// What a rebuild would do, without doing it.
    struct Proposal {
        var families: [Family] = []

        var photoCount: Int { families.reduce(0) { $0 + $1.variantIDs.count + 1 } }
        var isEmpty: Bool { families.isEmpty }

        var summary: String {
            let groups = families.count == 1 ? "1 group" : "\(families.count) groups"
            return "\(groups) covering \(photoCount) photos"
        }
    }

    /// Looks for families among the photos on hand.
    ///
    /// Deliberately two passes. The first buckets on creation date alone, which
    /// is already in memory and costs nothing; only photos that collide with
    /// another are asked about further. A library of ten thousand photos where
    /// nothing was ever duplicated therefore reads no resources at all, rather
    /// than ten thousand.
    static func proposal(for items: [PhotoItem], ratings: RatingStore) -> Proposal {
        var byDate: [Date: [PhotoItem]] = [:]
        for item in items {
            guard let creationDate = item.creationDate else { continue }
            byDate[creationDate, default: []].append(item)
        }

        let colliding = byDate.values.filter { $0.count > 1 }.flatMap { $0 }
        guard !colliding.isEmpty else { return Proposal() }

        let candidates = colliding.map { item -> Candidate in
            Candidate(id: item.id,
                      creationDate: item.creationDate,
                      signature: signature(of: item.asset),
                      addedDate: addedDate(of: item.asset))
        }

        // Anything the store already speaks for, either as a variant or as the
        // source of one.
        var known = Set(ratings.variantLabels.keys)
        for id in ratings.variantLabels.keys {
            known.insert(ratings.rootAsset(of: id))
        }

        return Proposal(families: families(from: candidates, known: known))
    }

    /// Writes the proposed families into the store.
    ///
    /// Labelled "Version" rather than guessed at: what a recovered copy was
    /// called is not recoverable, and inventing "B&W" from the pixels would be
    /// asserting something this does not know.
    static func apply(_ proposal: Proposal, context: ModelContext?, ratings: RatingStore?) {
        guard let context else { return }
        for family in proposal.families {
            for variantID in family.variantIDs {
                context.insert(PhotoVariant(assetID: variantID,
                                            originalAssetID: family.rootID,
                                            label: "Version"))
            }
        }
        try? context.save()
        ratings?.reloadVariants()
    }

    private static func signature(of asset: PHAsset) -> String {
        let resources = PHAssetResource.assetResources(for: asset)
        let primary = resources.first { $0.type == .photo } ?? resources.first
        let name = primary?.originalFilename.lowercased() ?? "?"
        return "\(name)#\(asset.pixelWidth)x\(asset.pixelHeight)"
    }

    private static func addedDate(of asset: PHAsset) -> Date? {
        // New in macOS 26 / iOS 26, and the only thing that can say which of
        // two photos with the same creation date arrived first. Without it the
        // grouping still works; only the choice of which one is the original
        // falls back to being arbitrary but stable.
        if #available(macOS 26.0, iOS 26.0, *) {
            return asset.addedDate
        }
        return nil
    }
}
