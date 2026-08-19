#if os(macOS)
import Photos
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
        let probe = Debug.isEnabled ? NearestPhoto(library) : nil
        let names = Debug.isEnabled ? NameProbe(library) : nil

        if Debug.isEnabled {
            // Photos keeps hidden photographs in a smart album of their own.
            // Asking it directly says whether they can be seen at all, which is
            // a different question to whether the ordinary fetch returns them.
            let hidden = PHAssetCollection.fetchAssetCollections(
                with: .smartAlbum, subtype: .smartAlbumAllHidden, options: nil)
            if let album = hidden.firstObject {
                let options = PHFetchOptions()
                options.includeHiddenAssets = true
                let assets = PHAsset.fetchAssets(in: album, options: options)
                var oldest: Date?
                var newest: Date?
                assets.enumerateObjects { asset, _, _ in
                    guard let date = asset.creationDate else { return }
                    if oldest == nil || date < oldest! { oldest = date }
                    if newest == nil || date > newest! { newest = date }
                }
                fputs("[lightroom] hidden album: \(assets.count) photographs" +
                      (oldest.map { ", \($0.formatted(.iso8601.year().month().day()))" } ?? "") +
                      (newest.map { " to \($0.formatted(.iso8601.year().month().day()))" } ?? "") +
                      "\n", stderr)
            } else {
                fputs("[lightroom] hidden album: not available\n", stderr)
            }

            probeAlbum()

            let dated = library.compactMap(\.creationDate)
            fputs("[lightroom] library: \(library.count) photographs" +
                  (Debug.includesHidden ? " (hidden included)" : "") +
                  (dated.min().map { ", \($0.formatted(.iso8601.year().month().day()))" } ?? "") +
                  (dated.max().map { " to \($0.formatted(.iso8601.year().month().day()))" } ?? "") +
                  "\n", stderr)
        }

        var proposal = Proposal()
        for collection in collections {
            let outcome = LightroomMatch.match(collection.photos, in: index)
            guard outcome.count > 0 else {
                proposal.empty.append(collection.fullName)
                if Debug.isEnabled { log(collection, outcome, probe, names) }
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
            if Debug.isEnabled { log(collection, outcome, probe, names) }
        }
        if Debug.isEnabled {
            fputs("[lightroom] \(proposal.summary)\n", stderr)
        }
        return proposal
    }

    /// Asks a named album what it holds, hidden photographs included.
    ///
    /// Two counts, because the difference between them is the whole answer: how
    /// many the album vends with hidden photographs allowed, and how many of
    /// those say they are hidden.
    private static func probeAlbum() {
        guard let name = Debug.probeAlbum else { return }

        let albums = PHAssetCollection.fetchAssetCollections(with: .album,
                                                             subtype: .any,
                                                             options: nil)
        var found: PHAssetCollection?
        albums.enumerateObjects { album, _, stop in
            if album.localizedTitle == name {
                found = album
                stop.pointee = true
            }
        }
        guard let album = found else {
            fputs("[lightroom] album \"\(name)\": not found\n", stderr)
            return
        }

        let options = PHFetchOptions()
        options.includeHiddenAssets = true
        let assets = PHAsset.fetchAssets(in: album, options: options)
        var hidden = 0
        var earliest: Date?
        assets.enumerateObjects { asset, _, _ in
            if asset.isHidden { hidden += 1 }
            if let date = asset.creationDate, earliest == nil || date < earliest! { earliest = date }
        }
        fputs("[lightroom] album \"\(name)\": \(assets.count) photographs, \(hidden) of them hidden" +
              (earliest.map { ", from \($0.formatted(.iso8601.year().month().day()))" } ?? "") +
              "\n", stderr)
    }

    /// What a collection came to, in the terms that decide what to do next:
    /// how many were not in the library at all, how many were there but too
    /// alike to choose between, and what the file types of the missing were —
    /// all raws usually means a shoot that was never imported.
    private static func log(_ collection: LightroomCatalog.Collection,
                            _ outcome: LightroomMatch.Outcome,
                            _ probe: NearestPhoto?,
                            _ names: NameProbe?) {
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
        // How far the missing frames are from the nearest photograph the
        // library does hold. A wall of "not here" from an archive that was
        // re-imported folder by folder is a claim worth testing: if the nearest
        // photograph is always some round number of hours away, the clock is
        // the problem, not the library.
        if let probe, !outcome.unmatched.isEmpty {
            line += " " + probe.describe(outcome.unmatched)

            // The days the missing frames were shot on, and what the library
            // holds across them.
            let times = outcome.unmatched.compactMap { $0.captureTime?.timeIntervalSince1970 }
            if let first = times.min(), let last = times.max() {
                let day: TimeInterval = 86_400
                let held = probe.count(from: Int((first / day).rounded(.down) * day),
                                       to: Int((last / day).rounded(.down) * day + day))
                let span = Int((last - first) / day) + 1
                line += " {library holds \(held) across those \(span) day\(span == 1 ? "" : "s")}"
            }
        }
        // The decisive question, asked only where it is worth the cost: a day
        // the library holds hundreds of photographs from, none of which this
        // matched. Either the catalogue's frames are there under other times —
        // in which case their file names are there too — or the library holds
        // different photographs of the same afternoon.
        if let names, outcome.count == 0, outcome.unmatched.count >= 20 {
            line += " " + names.describe(outcome.unmatched)
        }
        fputs(line + "\n", stderr)
    }

    /// Reads the original file names of the photographs the library holds on a
    /// given day.
    ///
    /// A resource lookup per asset, which is far too slow to do across a
    /// library — so it is done for one day at a time, and only to answer a
    /// question a whole collection is riding on.
    private struct NameProbe {
        private let byDay: [Int: [PhotoItem]]

        init(_ library: [PhotoItem]) {
            byDay = Dictionary(grouping: library.filter { $0.creationDate != nil }) {
                Int(($0.creationDate!.timeIntervalSince1970 / 86_400).rounded(.down))
            }
        }

        func describe(_ unmatched: [LightroomMatch.CatalogPhoto]) -> String {
            let days = Set(unmatched.compactMap { photo -> Int? in
                guard let time = photo.captureTime else { return nil }
                return Int((time.timeIntervalSince1970 / 86_400).rounded(.down))
            })
            let assets = days.flatMap { byDay[$0] ?? [] }
            guard !assets.isEmpty, assets.count <= 800 else { return "" }

            var libraryNames: Set<String> = []
            for item in assets {
                guard let resource = PHAssetResource.assetResources(for: item.asset).first else { continue }
                libraryNames.insert(
                    (resource.originalFilename as NSString).deletingPathExtension.uppercased())
            }
            let wanted = Set(unmatched.map {
                ($0.fileName as NSString).deletingPathExtension.uppercased()
            })
            let shared = wanted.intersection(libraryNames).count
            return "{names: \(shared) of \(wanted.count) also in the library that day}"
        }
    }

    /// The library's capture times, sorted, so the nearest one to a given
    /// moment can be found without walking ninety thousand photographs per
    /// frame.
    private struct NearestPhoto {
        private let seconds: [Int]

        init(_ library: [PhotoItem]) {
            seconds = library.compactMap { $0.creationDate }
                .map { Int($0.timeIntervalSince1970.rounded(.down)) }
                .sorted()
        }

        /// How many photographs the library holds between two moments.
        ///
        /// The question a wall of "not here" actually poses: is the shoot
        /// missing, or is it there under different times? A day that holds
        /// nothing says the first; a day holding two hundred says the second,
        /// and points at the clock rather than at the library.
        func count(from start: Int, to end: Int) -> Int {
            lowerBound(end + 1) - lowerBound(start)
        }

        private func lowerBound(_ value: Int) -> Int {
            var low = 0, high = seconds.count
            while low < high {
                let middle = (low + high) / 2
                if seconds[middle] < value { low = middle + 1 } else { high = middle }
            }
            return low
        }

        /// The signed distance to the closest photograph, in seconds.
        func delta(to second: Int) -> Int? {
            guard !seconds.isEmpty else { return nil }
            var low = 0, high = seconds.count - 1
            while low < high {
                let middle = (low + high) / 2
                if seconds[middle] < second { low = middle + 1 } else { high = middle }
            }
            let after = seconds[low] - second
            let before = low > 0 ? seconds[low - 1] - second : after
            return abs(before) < abs(after) ? before : after
        }

        /// The distances the missing frames sit at, commonest first — and the
        /// single commonest distance to the second.
        ///
        /// The exact number is the one that decides: frames scattered a few
        /// minutes from their neighbours are frames the library does not hold,
        /// while a hundred frames all exactly thirty-two seconds out is a clock.
        func describe(_ unmatched: [LightroomMatch.CatalogPhoto]) -> String {
            var buckets: [String: Int] = [:]
            var exact: [Int: Int] = [:]
            var undated = 0

            for photo in unmatched.prefix(400) {
                guard let time = photo.captureTime else { undated += 1; continue }
                guard let delta = delta(to: Int(time.timeIntervalSince1970.rounded(.down))) else { continue }
                buckets[label(for: delta), default: 0] += 1
                exact[delta, default: 0] += 1
            }
            if undated > 0 { buckets["undated", default: 0] += undated }

            let listed = buckets.sorted { $0.value > $1.value }.prefix(3)
                .map { "\($0.value) \($0.key)" }
                .joined(separator: ", ")
            var text = "{nearest: \(listed)"
            if let (delta, count) = exact.max(by: { $0.value < $1.value }), count > 1 {
                text += "; commonest \(delta)s ×\(count)"
            }
            return text + "}"
        }

        private func label(for delta: Int) -> String {
            let magnitude = abs(delta)
            switch magnitude {
            case 0...2: return "same second"
            case 3...300: return "minutes"
            case 301...7200: return String(format: "%+.1f h", Double(delta) / 3600)
            case 7201...172_800: return String(format: "%+.0f h", (Double(delta) / 3600).rounded())
            default: return String(format: "%+.0f days", (Double(delta) / 86_400).rounded())
            }
        }
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
