import Foundation

/// A photograph as the Lightroom matcher sees it: a moment and a shape.
///
/// Deliberately not `PhotoItem`, so the rule can be exercised without a photo
/// library behind it. `PHAsset` cannot be made with a creation date, which is
/// the same reason `TemporalPhoto` exists.
protocol MatchablePhoto {
    var id: String { get }
    var creationDate: Date? { get }
    var pixelWidth: Int { get }
    var pixelHeight: Int { get }
}

extension PhotoItem: MatchablePhoto {}

/// Finding the photographs a Lightroom catalogue is talking about.
///
/// The catalogue names files on a NAS; this app knows a photo library. The only
/// things both ends agree on are when the shutter opened and how many pixels
/// came out — the file has usually been renamed, re-wrapped as a JPEG, or
/// imported twice.
///
/// The moment does nearly all the work: a second is a fine sieve, and two
/// photographs from one camera cannot share one. Shape is the tie-breaker for
/// the frames that do collide — a burst written by two bodies, or the same file
/// imported twice at different sizes.
enum LightroomMatch {
    /// What a catalogue knows about one photograph.
    struct CatalogPhoto: Equatable {
        var localID: Int64
        var fileName: String
        /// The camera's own clock, with no timezone on it — which is exactly
        /// the problem `offsets` exists to solve.
        var captureTime: Date?
        var pixelWidth: Int
        var pixelHeight: Int
    }

    struct Outcome {
        /// Catalogue id to the photograph in the library it turned out to be.
        var matched: [Int64: String] = [:]
        /// The shift that made the most of them line up, in seconds.
        var offset: TimeInterval = 0
        var unmatched: [CatalogPhoto] = []

        var count: Int { matched.count }
    }

    /// Whole hours either way, and the half-hour zones.
    ///
    /// A camera's clock is set to wherever it was bought and left there; a photo
    /// library records the moment the shutter opened, absolutely. A fortnight in
    /// Japan therefore lands nine hours from where the catalogue says it did,
    /// consistently, for every frame in the collection — so the shift is worth
    /// looking for once per collection rather than being treated as a hundred
    /// separate failures.
    static let offsets: [TimeInterval] = {
        var offsets: [TimeInterval] = [0]
        for hours in 1...14 {
            offsets.append(TimeInterval(hours) * 3600)
            offsets.append(TimeInterval(-hours) * 3600)
        }
        for half in [1.5, -1.5, 5.5, -5.5, 9.5, -9.5, 10.5, -10.5] {
            offsets.append(half * 3600)
        }
        return offsets
    }()

    /// An index of the library by the second each photograph was taken.
    ///
    /// Built once and handed to every collection: a catalogue has hundreds of
    /// them, and the library has ninety thousand photographs.
    ///
    /// Floored, not rounded, and that is the whole game. Lightroom writes the
    /// capture time with the fraction attached — `12:15:07.26` — and truncates
    /// when asked for a second; a photo library keeps the fraction. Rounding
    /// this side filed every photograph whose fraction was past the halfway
    /// mark one second late, so a shoot from a camera that records sub-seconds
    /// matched at almost exactly fifty per cent while a 2007 shoot from a body
    /// that does not matched at a hundred. Two shoots in the same catalogue,
    /// 94 of 192 and 58 of 58, which is what pointed at it.
    struct LibraryIndex {
        fileprivate var bySecond: [Int: [any MatchablePhoto]] = [:]

        init(_ photos: [any MatchablePhoto]) {
            for photo in photos {
                guard let date = photo.creationDate else { continue }
                bySecond[Self.second(of: date.timeIntervalSince1970), default: []].append(photo)
            }
        }

        fileprivate static func second(of time: TimeInterval) -> Int {
            Int(time.rounded(.down))
        }

        fileprivate func photos(at second: Int) -> [any MatchablePhoto] {
            bySecond[second] ?? []
        }
    }

    /// Matches one collection's photographs, choosing the shift that lines up
    /// most of them.
    ///
    /// A shift is only taken over no shift at all when it does better by a
    /// clear margin: half the frames of a collection shot across a timezone
    /// change would otherwise drag the whole set an hour sideways on the
    /// strength of one extra hit.
    static func match(_ photos: [CatalogPhoto], in index: LibraryIndex) -> Outcome {
        let dated = photos.filter { $0.captureTime != nil }
        guard !dated.isEmpty else {
            return Outcome(matched: [:], offset: 0, unmatched: photos)
        }

        var best = matched(dated, in: index, offset: 0)
        var bestOffset: TimeInterval = 0
        // Comfortably more than a rounding difference, and far less than a
        // timezone: a shift has to explain most of the collection.
        let margin = max(2, dated.count / 10)

        for offset in offsets where offset != 0 {
            let candidate = matched(dated, in: index, offset: offset)
            if candidate.count > best.count + margin {
                best = candidate
                bestOffset = offset
            }
        }

        let matchedIDs = Set(best.keys)
        return Outcome(matched: best,
                       offset: bestOffset,
                       unmatched: photos.filter { !matchedIDs.contains($0.localID) })
    }

    private static func matched(_ photos: [CatalogPhoto],
                                in index: LibraryIndex,
                                offset: TimeInterval) -> [Int64: String] {
        var result: [Int64: String] = [:]
        for photo in photos {
            guard let captureTime = photo.captureTime else { continue }
            let second = LibraryIndex.second(of: captureTime.timeIntervalSince1970 + offset)

            if let chosen = choose(from: index.photos(at: second), like: photo) {
                result[photo.localID] = chosen.id
                continue
            }
            // Nothing on that second at all: allow a second either way, for the
            // frames where the two ends disagree about where the fraction
            // rounded. Only when the second itself is empty, so a burst is
            // never resolved by reaching into its neighbours.
            guard index.photos(at: second).isEmpty else { continue }
            for neighbour in [second - 1, second + 1] {
                guard let chosen = choose(from: index.photos(at: neighbour), like: photo) else { continue }
                result[photo.localID] = chosen.id
                break
            }
        }
        return result
    }

    /// One photograph, or none.
    ///
    /// Ambiguity is left unmatched rather than guessed at: an event built from
    /// the wrong frames is worse than an event that says it is missing some.
    private static func choose(from candidates: [any MatchablePhoto],
                               like photo: CatalogPhoto) -> (any MatchablePhoto)? {
        if candidates.count == 1 { return candidates[0] }
        guard candidates.count > 1 else { return nil }

        // Rotation is metadata in a raw file and pixels in an export, so a
        // portrait frame can be the same photograph either way round.
        let sameShape = candidates.filter {
            ($0.pixelWidth == photo.pixelWidth && $0.pixelHeight == photo.pixelHeight)
                || ($0.pixelWidth == photo.pixelHeight && $0.pixelHeight == photo.pixelWidth)
        }
        return sameShape.count == 1 ? sameShape[0] : nil
    }
}
