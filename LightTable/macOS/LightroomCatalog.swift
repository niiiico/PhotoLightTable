#if os(macOS)
import Foundation
import SQLite3

/// Reads collections out of a Lightroom Classic catalogue.
///
/// A `.lrcat` is a SQLite database, and everything needed here is in three
/// tables: the collections, what is in them, and when each photograph was
/// taken. Nothing is written, ever — this reads someone else's library.
///
/// It reads a *copy*, for two reasons. Lightroom keeps the catalogue open with a
/// write-ahead log beside it, often hundreds of megabytes of it, and a reader
/// that ignores the log sees a stale library. And a WAL database cannot be
/// opened read-only at all without write access to the directory it sits in,
/// which is someone else's library folder.
enum LightroomCatalog {
    struct Collection: Identifiable {
        var id: Int64
        /// The groups it sits under, outermost first — Lightroom's collection
        /// sets, which read as a path.
        var path: [String]
        var name: String
        var photos: [LightroomMatch.CatalogPhoto]

        /// What an event made from this should be called.
        var fullName: String { (path + [name]).joined(separator: " / ") }
    }

    enum Failure: LocalizedError {
        case cannotOpen(String)
        case cannotCopy(String)

        var errorDescription: String? {
            switch self {
            case .cannotOpen(let detail): return "That catalogue could not be opened: \(detail)"
            case .cannotCopy(let detail): return "That catalogue could not be copied to read: \(detail)"
            }
        }
    }

    /// Every ordinary collection with something in it.
    ///
    /// Smart collections are left out: they are a saved question rather than a
    /// list of photographs, and the answer depends on metadata this app does not
    /// have. Groups become the path, not collections of their own.
    static func collections(at url: URL) throws -> [Collection] {
        let copy = try copyAside(url)
        defer { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) }

        // The copy is opened for writing, which sounds worse than it is: a
        // catalogue is kept in WAL mode, and opening a WAL database read-only
        // means SQLite has to attach the shared-memory file that goes with it —
        // which it cannot create without write access, so the open fails with
        // "unable to open database file" before a single row is read. The
        // original is never opened at all; this is a copy in a temporary
        // directory, deleted on the way out.
        var handle: OpaquePointer?
        guard sqlite3_open_v2(copy.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let db = handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(handle)
            throw Failure.cannotOpen(message)
        }
        defer { sqlite3_close(db) }

        let parents = try groups(in: db)
        var photosByCollection: [Int64: [LightroomMatch.CatalogPhoto]] = [:]
        try each(db, """
            SELECT ci.collection, i.id_local, fi.idx_filename, i.captureTime,
                   i.fileWidth, i.fileHeight
            FROM AgLibraryCollectionImage ci
            JOIN Adobe_images i ON i.id_local = ci.image
            JOIN AgLibraryFile fi ON fi.id_local = i.rootFile
            """) { row in
            let photo = LightroomMatch.CatalogPhoto(
                localID: row.int(1),
                fileName: row.text(2) ?? "",
                captureTime: captureTime(row.text(3)),
                pixelWidth: Int(row.int(4)),
                pixelHeight: Int(row.int(5)))
            photosByCollection[row.int(0), default: []].append(photo)
        }

        var collections: [Collection] = []
        try each(db, """
            SELECT id_local, name, parent FROM AgLibraryCollection
            WHERE creationId = 'com.adobe.ag.library.collection'
            """) { row in
            let id = row.int(0)
            guard let photos = photosByCollection[id], !photos.isEmpty else { return }
            collections.append(Collection(id: id,
                                          path: path(of: row.int(2), in: parents),
                                          name: row.text(1) ?? "Untitled",
                                          photos: photos))
        }
        return collections.sorted { $0.fullName.localizedStandardCompare($1.fullName) == .orderedAscending }
    }

    // MARK: - Reading

    /// The catalogue, its log and its shared memory, side by side in a
    /// temporary directory so SQLite sees a complete database.
    private static func copyAside(_ url: URL) throws -> URL {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory
            .appendingPathComponent("lightroom-import-\(UUID().uuidString)")
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent("catalog.lrcat")
            try manager.copyItem(at: url, to: destination)
            for suffix in ["-wal", "-shm"] {
                let companion = URL(fileURLWithPath: url.path + suffix)
                guard manager.fileExists(atPath: companion.path) else { continue }
                try manager.copyItem(at: companion,
                                     to: URL(fileURLWithPath: destination.path + suffix))
            }
            return destination
        } catch {
            throw Failure.cannotCopy(error.localizedDescription)
        }
    }

    private static func groups(in db: OpaquePointer) throws -> [Int64: (name: String, parent: Int64?)] {
        var parents: [Int64: (name: String, parent: Int64?)] = [:]
        try each(db, """
            SELECT id_local, name, parent FROM AgLibraryCollection
            WHERE creationId = 'com.adobe.ag.library.group'
            """) { row in
            parents[row.int(0)] = (row.text(1) ?? "Untitled", row.isNull(2) ? nil : row.int(2))
        }
        return parents
    }

    private static func path(of parent: Int64,
                             in groups: [Int64: (name: String, parent: Int64?)]) -> [String] {
        var path: [String] = []
        var current: Int64? = parent
        // A group that names itself as its own ancestor would otherwise be a
        // loop; a catalogue is someone else's data and does not have to be sane.
        var seen: Set<Int64> = []
        while let id = current, let group = groups[id], seen.insert(id).inserted {
            path.insert(group.name, at: 0)
            current = group.parent
        }
        return path
    }

    /// Lightroom writes the camera's own clock, sometimes with fractions of a
    /// second on it, and never with a timezone.
    private static func captureTime(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        return formatter.date(from: String(text.prefix(19)))
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter
    }()

    // MARK: - SQLite

    private struct Row {
        let statement: OpaquePointer

        func int(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
        func isNull(_ column: Int32) -> Bool { sqlite3_column_type(statement, column) == SQLITE_NULL }
        func text(_ column: Int32) -> String? {
            sqlite3_column_text(statement, column).map { String(cString: $0) }
        }
    }

    private static func each(_ db: OpaquePointer,
                             _ sql: String,
                             _ body: (Row) -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw Failure.cannotOpen(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            body(Row(statement: statement))
        }
    }
}
#endif
