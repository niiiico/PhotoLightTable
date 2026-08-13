import Foundation
import Photos

/// One event reconstructed from the folder that represents it in Photos.
struct ImportedEvent {
    let name: String
    let folderID: String
    let albumID: String
    let pickedAlbumID: String?
    let memberIDs: Set<String>
    let pickedIDs: Set<String>
}

/// The app's state as described by the albums currently in Photos.
struct PhotosImport {
    var picked: Set<String> = []
    var rejected: Set<String> = []
    var events: [ImportedEvent] = []

    var isEmpty: Bool { picked.isEmpty && rejected.isEmpty && events.isEmpty }

    var summary: String {
        var parts: [String] = []
        if !events.isEmpty { parts.append("\(events.count) event\(events.count == 1 ? "" : "s")") }
        if !picked.isEmpty { parts.append("\(picked.count) picked") }
        if !rejected.isEmpty { parts.append("\(rejected.count) rejected") }
        return parts.isEmpty ? "nothing to import" : parts.joined(separator: ", ")
    }
}

extension AlbumSyncer {
    /// Reads the LightTable folder back out of Photos.
    ///
    /// The albums are the durable record — they survive the app's own store
    /// being lost, moved, or set up fresh on another device — so this is both
    /// the recovery path and how a new install adopts existing work.
    func readFromPhotos() -> PhotosImport {
        var result = PhotosImport()
        guard let root = topLevelFolder(titled: Self.rootFolderTitle) else { return result }

        let children = PHCollection.fetchCollections(in: root, options: nil)
        children.enumerateObjects { collection, _, _ in
            switch collection {
            case let album as PHAssetCollection:
                switch album.localizedTitle {
                case Self.pickedAlbumTitle: result.picked = Self.assetIDs(in: album)
                case Self.rejectedAlbumTitle: result.rejected = Self.assetIDs(in: album)
                default: break
                }

            case let folder as PHCollectionList:
                if let event = Self.readEvent(from: folder) { result.events.append(event) }

            default:
                break
            }
        }
        return result
    }

    /// An event folder holds an album named after it and, optionally, a
    /// "— Picked" companion.
    private static func readEvent(from folder: PHCollectionList) -> ImportedEvent? {
        guard let name = folder.localizedTitle else { return nil }
        let pickedTitle = "\(name) — Picked"

        var main: PHAssetCollection?
        var picked: PHAssetCollection?
        PHCollection.fetchCollections(in: folder, options: nil).enumerateObjects { collection, _, _ in
            guard let album = collection as? PHAssetCollection else { return }
            switch album.localizedTitle {
            case name: main = album
            case pickedTitle: picked = album
            default: break
            }
        }

        guard let main else { return nil }
        return ImportedEvent(
            name: name,
            folderID: folder.localIdentifier,
            albumID: main.localIdentifier,
            pickedAlbumID: picked?.localIdentifier,
            memberIDs: assetIDs(in: main),
            pickedIDs: picked.map { assetIDs(in: $0) } ?? [])
    }

    private static func assetIDs(in album: PHAssetCollection) -> Set<String> {
        var ids: Set<String> = []
        PHAsset.fetchAssets(in: album, options: nil).enumerateObjects { asset, _, _ in
            ids.insert(asset.localIdentifier)
        }
        return ids
    }

    private func topLevelFolder(titled title: String) -> PHCollectionList? {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "localizedTitle == %@", title)
        return PHCollectionList.fetchCollectionLists(with: .folder,
                                                     subtype: .any,
                                                     options: options).firstObject
    }
}

extension Notification.Name {
    static let rebuildFromPhotos = Notification.Name("LightTable.rebuildFromPhotos")
    static let rebuildVariants = Notification.Name("LightTable.rebuildVariants")
}
