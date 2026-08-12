import Foundation
import SwiftData

/// One row per rated asset. Assets with no rating have no row at all, so the
/// store stays proportional to work done rather than library size.
@Model
final class AssetRating {
    /// `PHAsset.localIdentifier`.
    @Attribute(.unique) var assetID: String
    var pickRaw: Int
    var colorRaw: Int?
    var updatedAt: Date

    init(assetID: String, pickRaw: Int = 0, colorRaw: Int? = nil, updatedAt: Date = .now) {
        self.assetID = assetID
        self.pickRaw = pickRaw
        self.colorRaw = colorRaw
        self.updatedAt = updatedAt
    }

    var value: RatingValue {
        RatingValue(pick: Pick(rawValue: pickRaw) ?? .unrated,
                    color: colorRaw.flatMap(ColorLabel.init(rawValue:)))
    }
}

/// One edit applied to a photo, kept so any earlier state can be returned to.
///
/// Photos itself keeps only the original and the current render — there is no
/// intermediate history to read back — so a stack of every recipe this app has
/// applied has to be ours.
@Model
final class PhotoEditVersion {
    var assetID: String
    /// An encoded `PhotoEditRecipe`, stored rather than referenced so an old
    /// version stays readable after the recipe type grows new fields.
    var recipeData: Data
    var createdAt: Date

    init(assetID: String, recipeData: Data, createdAt: Date = .now) {
        self.assetID = assetID
        self.recipeData = recipeData
        self.createdAt = createdAt
    }

    var recipe: PhotoEditRecipe? {
        try? JSONDecoder().decode(PhotoEditRecipe.self, from: recipeData)
    }
}

/// A photo created as an alternative treatment of another.
///
/// Photos has no notion of one asset being a version of another — the duplicate
/// is an ordinary photo in the library — so the relationship is ours to keep.
@Model
final class PhotoVariant {
    /// The new asset.
    var assetID: String
    /// The asset it was made from.
    var originalAssetID: String
    var label: String
    var createdAt: Date

    init(assetID: String, originalAssetID: String, label: String, createdAt: Date = .now) {
        self.assetID = assetID
        self.originalAssetID = originalAssetID
        self.label = label
        self.createdAt = createdAt
    }
}

/// What an album contained at the end of the last successful sync.
///
/// Without this, sync can only overwrite: the app cannot tell a photo you added
/// in Photos from one it hasn't pushed yet, so it deletes the former. Comparing
/// the album against this baseline turns that into a three-way merge.
@Model
final class AlbumBaseline {
    /// Stable key: "global.picked", "global.rejected", "event.<id>.all", …
    var key: String
    var memberIDs: [String]
    var updatedAt: Date

    init(key: String, memberIDs: [String] = [], updatedAt: Date = .now) {
        self.key = key
        self.memberIDs = memberIDs
        self.updatedAt = updatedAt
    }
}

/// A user-defined event: a name over a date range, plus manual overrides for
/// the stragglers that fall outside it.
@Model
final class LightTableEvent {
    var name: String
    var startDate: Date
    var endDate: Date
    /// Assets forced into the event even though their date falls outside the range.
    var pinnedAssetIDs: [String]
    /// Assets inside the range that the user pushed out.
    var excludedAssetIDs: [String]
    var createdAt: Date
    /// When true, membership is exactly `pinnedAssetIDs` and the date range is
    /// only descriptive. Optional so that adding it migrates cleanly over an
    /// existing store. Read it through `isExplicit`.
    var explicitMembership: Bool?

    /// Stable identity for keys that must survive relaunches.
    ///
    /// `persistentModelID.hashValue` cannot be used for this: Swift seeds its
    /// hasher per process, so that value changes on every launch. Baselines
    /// keyed by it were orphaned each time the app started.
    var eventKey: String?

    /// Mirror this event into a folder of albums in Photos.
    var syncsToPhotos: Bool?
    /// Identifiers of the Photos collections we created, so a renamed event
    /// renames its folder instead of orphaning it and making a second one.
    var photosFolderID: String?
    var photosAlbumID: String?
    var photosPickedAlbumID: String?

    init(name: String,
         startDate: Date,
         endDate: Date,
         pinnedAssetIDs: [String] = [],
         excludedAssetIDs: [String] = [],
         explicitMembership: Bool = false,
         createdAt: Date = .now) {
        self.eventKey = UUID().uuidString
        self.name = name
        self.startDate = startDate
        self.endDate = endDate
        self.pinnedAssetIDs = pinnedAssetIDs
        self.excludedAssetIDs = excludedAssetIDs
        self.explicitMembership = explicitMembership
        self.createdAt = createdAt
    }

    /// Membership is a fixed list of photos rather than a date range.
    var isExplicit: Bool { explicitMembership ?? false }

    var isSyncedToPhotos: Bool { syncsToPhotos ?? false }

    /// Assigns a key on first use, for events created before this existed.
    var stableKey: String {
        if let eventKey { return eventKey }
        let generated = UUID().uuidString
        eventKey = generated
        return generated
    }

    /// Inclusive of the whole final day, so a range picked as 3–14 Aug covers
    /// everything shot on the 14th rather than stopping at midnight.
    var dateInterval: DateInterval {
        let cal = Calendar.current
        let start = cal.startOfDay(for: startDate)
        let end = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: endDate)) ?? endDate
        return DateInterval(start: start, end: max(start, end))
    }

    /// Single-asset membership test. For filtering a whole library prefer the
    /// set-based path in `AppModel.scope`, which avoids rescanning these arrays
    /// once per photo.
    func contains(assetID: String, date: Date?) -> Bool {
        if isExplicit { return pinnedAssetIDs.contains(assetID) }
        if pinnedAssetIDs.contains(assetID) { return true }
        if excludedAssetIDs.contains(assetID) { return false }
        guard let date else { return false }
        return dateInterval.contains(date)
    }
}
