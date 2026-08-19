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
        /// An event of this name already exists, so this run adds to it.
        var isUpdate = false
        /// How many of the matched photographs it does not already hold.
        var newMembers = 0
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
        var updates: [Plan] { plans.filter(\.isUpdate) }
        var fresh: [Plan] { plans.filter { !$0.isUpdate } }
        var photoCount: Int { plans.reduce(0) { $0 + $1.assetIDs.count } }
        var missingCount: Int { plans.reduce(0) { $0 + $1.missing } }

        /// What the confirmation says.
        var message: String {
            guard !isEmpty else {
                return "None of the photographs in that catalogue are in this library."
            }
            var text = summary
            if !updates.isEmpty {
                let added = updates.reduce(0) { $0 + $1.newMembers }
                text += " \(updates.count) of them already exist and would gain "
                text += added == 0 ? "nothing new" : "\(added) photograph\(added == 1 ? "" : "s")"
                text += "."
            }
            return text + """


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
    @MainActor
    static func proposal(for catalog: URL,
                         library: [PhotoItem],
                         ratings: RatingStore,
                         events: [LightTableEvent] = []) throws -> Proposal {
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
            probeIdentifiers(library: library, ratings: ratings)

            let dated = library.compactMap(\.creationDate)
            let hiddenHere = library.filter(\.isHidden).count
            fputs("[lightroom] library: \(library.count) photographs, \(hiddenHere) of them hidden" +
                  (PhotoLibraryService.includesHidden ? " (hidden included)" : "") +
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
            // Matched by name, which is what a second run has to recognise:
            // the same collection in the same catalogue makes the same name.
            let existing = events.first { $0.name == collection.fullName }
            proposal.plans.append(Plan(id: collection.id,
                                       name: collection.fullName,
                                       isUpdate: existing != nil,
                                       newMembers: EventMerge.adds(
                                           existing: existing?.pinnedAssetIDs ?? [],
                                           incoming: assetIDs),
                                       assetIDs: assetIDs,
                                       missing: outcome.unmatched.count,
                                       offset: outcome.offset))
            if Debug.isEnabled {
                log(collection, outcome, probe, names)
                logStrays(collection, assetIDs: assetIDs, library: library)
            }
        }
        if Debug.isEnabled {
            fputs("[lightroom] \(proposal.summary)\n", stderr)
        }
        return proposal
    }

    /// Whether a photograph this app has seen before can still be fetched by
    /// its identifier once the library stops listing it.
    ///
    /// The question the whole unhide-and-re-hide plan rests on, and it can be
    /// asked without unhiding anything: the store holds identifiers of
    /// photographs judged in the past, and any of those the visible library no
    /// longer lists is exactly the case in question. If they come back by
    /// identifier and say they are hidden, the header's promise holds. If
    /// nothing comes back, hiding is a wall on both sides of the fetch.
    /// Photographs that are visible in a collection where nearly all of them
    /// are hidden.
    ///
    /// Which is what an accidental unhide looks like from the outside: a shoot
    /// somebody hid, with two frames of it out in the open. Named rather than
    /// counted, since the point is to be able to go and put them back.
    private static func logStrays(_ collection: LightroomCatalog.Collection,
                                  assetIDs: [String],
                                  library: [PhotoItem]) {
        let byID = Dictionary(library.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let members = assetIDs.compactMap { byID[$0] }
        let hidden = members.filter(\.isHidden)
        let visible = members.filter { !$0.isHidden }
        guard !hidden.isEmpty, !visible.isEmpty,
              hidden.count >= members.count * 9 / 10 else { return }

        let listed = visible.prefix(6).map { item in
            item.creationDate.map { $0.formatted(.iso8601.year().month().day()) } ?? item.id
        }.joined(separator: ", ")
        fputs("[lightroom] \(collection.fullName): \(visible.count) of \(members.count) "
              + "are not hidden while the rest are — \(listed)\n", stderr)
    }

    @MainActor
    private static func probeIdentifiers(library: [PhotoItem], ratings: RatingStore) {
        let visible = Set(library.map(\.id))
        let known = Set(ratings.ratings.keys)
        let missing = Array(known.subtracting(visible))
        guard !missing.isEmpty else {
            fputs("[lightroom] identifiers: every photograph the store knows is in the library\n", stderr)
            return
        }

        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: missing, options: nil)
        var hidden = 0
        fetched.enumerateObjects { asset, _, _ in if asset.isHidden { hidden += 1 } }
        fputs("[lightroom] identifiers: \(missing.count) judged photographs are not in the library; "
              + "fetching them by identifier returns \(fetched.count), \(hidden) of which say hidden\n",
              stderr)
    }

    /// Asks a named album what it holds, hidden photographs included.
    ///
    /// Two counts, because the difference between them is the whole answer: how
    /// many the album vends with hidden photographs allowed, and how many of
    /// those say they are hidden.
    private static func probeAlbum() {
        guard let wanted = Debug.probeAlbum else { return }

        // "*" asks every album rather than one by name: whether an album can
        // carry a hidden photograph at all is the question, and hunting for the
        // right title is a round trip that answers nothing.
        let all = wanted == "*"
        // Smart albums as well as ordinary ones. Apple's documentation is
        // specific about this: "Hidden assets are only available in the hidden
        // Smart Album or in user Smart Albums" — and a smart album is something
        // a Mac user can make, with a rule. Scanning only regular albums, as
        // this did, was looking in the one place the answer could not be.
        var albums: [PHAssetCollection] = []
        for type in [PHAssetCollectionType.album, .smartAlbum] {
            PHAssetCollection.fetchAssetCollections(with: type, subtype: .any, options: nil)
                .enumerateObjects { album, _, _ in albums.append(album) }
        }
        let withHidden = PHFetchOptions()
        withHidden.includeHiddenAssets = true

        var scanned = 0
        var reported = 0
        for album in albums {
            let title = album.localizedTitle ?? "untitled"
            guard all || title == wanted else { continue }
            scanned += 1

            let open = PHAsset.fetchAssets(in: album, options: withHidden)
            let plain = PHAsset.fetchAssets(in: album, options: nil)
            // Only albums where the two disagree, or where one was asked for by
            // name: everything else is an album of ordinary photographs.
            guard !all || open.count != plain.count else { continue }

            var hidden = 0
            open.enumerateObjects { asset, _, _ in if asset.isHidden { hidden += 1 } }
            fputs("[lightroom] album \"\(title)\": \(open.count) with hidden allowed, "
                  + "\(plain.count) without, \(hidden) say they are hidden\n", stderr)
            reported += 1
        }
        if all {
            fputs("[lightroom] albums scanned: \(scanned), "
                  + "\(reported) vend anything a plain fetch does not\n", stderr)
        } else if scanned == 0 {
            fputs("[lightroom] album \"\(wanted)\": not found\n", stderr)
        }
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
    /// Makes an event per plan, or adds to the one already there.
    ///
    /// Runnable as often as you like, which is the point: photographs arrive in
    /// the library in batches, and each run finds more of what a collection was
    /// always talking about. An event of the same name is added to rather than
    /// duplicated, and a run that finds nothing new writes nothing.
    @discardableResult
    static func apply(_ proposal: Proposal,
                      library: [PhotoItem],
                      events: [LightTableEvent],
                      context: ModelContext) -> Int {
        let dateByID = Dictionary(library.compactMap { item in
            item.creationDate.map { (item.id, $0) }
        }, uniquingKeysWith: { first, _ in first })
        let byName = Dictionary(events.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })

        var touched = 0
        for plan in proposal.plans {
            if let event = byName[plan.name] {
                let merged = EventMerge.merged(existing: event.pinnedAssetIDs,
                                               incoming: plan.assetIDs)
                guard merged.count != event.pinnedAssetIDs.count else { continue }
                event.pinnedAssetIDs = merged
                event.excludedAssetIDs.removeAll { merged.contains($0) }
                let dates = merged.compactMap { dateByID[$0] }
                if let first = dates.min() { event.startDate = first }
                if let last = dates.max() { event.endDate = last }
                touched += 1
                continue
            }

            let dates = plan.assetIDs.compactMap { dateByID[$0] }
            context.insert(LightTableEvent(name: plan.name,
                                           startDate: dates.min() ?? .now,
                                           endDate: dates.max() ?? .now,
                                           pinnedAssetIDs: plan.assetIDs,
                                           explicitMembership: true))
            touched += 1
        }
        try? context.save()
        return touched
    }
}
#endif
