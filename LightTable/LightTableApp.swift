import SwiftData
import SwiftUI

@main
struct LightTableApp: App {
    private let container: ModelContainer

    /// Where the store lives, named after this app.
    ///
    /// SwiftData's default configuration puts it at
    /// `Application Support/default.store`. Inside a sandbox that is private to
    /// the app; without one — which is where dropping the sandbox for Sparkle
    /// left us ([ADR 008](../docs/adr-008-shipping-updates.md)) — it is a path
    /// every unsandboxed app taking the default shares. One of them opened it,
    /// migrated it to its own schema, and this app's ratings, events and
    /// families went with it.
    ///
    /// A name of our own costs nothing and cannot collide.
    static func storeURL() -> URL {
        let directory = URL.applicationSupportDirectory.appending(path: "LightTable",
                                                                 directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "LightTable.store")

        adoptDefaultStore(into: url)
        return url
    }

    /// Carries an existing store over the first time this runs.
    ///
    /// Only when the shared file still holds *our* schema: on iOS the default
    /// path is inside the container and perfectly safe, so there is real data
    /// there to bring across, while on this Mac it may by now belong to another
    /// app entirely. Copied rather than moved, so a mistake here costs nothing.
    private static func adoptDefaultStore(into url: URL) {
        let manager = FileManager.default
        guard !manager.fileExists(atPath: url.path) else { return }

        let old = URL.applicationSupportDirectory.appending(path: "default.store")
        guard manager.fileExists(atPath: old.path), holdsOurSchema(old) else { return }

        for suffix in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: old.path + suffix)
            let destination = URL(fileURLWithPath: url.path + suffix)
            guard manager.fileExists(atPath: source.path) else { continue }
            try? manager.copyItem(at: source, to: destination)
        }
    }

    /// Whether a store file is this app's rather than somebody else's.
    private static func holdsOurSchema(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        // The table names appear as plain text in the file header region; this
        // avoids opening the database, which is what would disturb an app that
        // has it open.
        guard let head = try? handle.read(upToCount: 512 * 1024) else { return false }
        return head.range(of: Data("ZASSETRATING".utf8)) != nil
    }
    @StateObject private var library: PhotoLibraryService
    @StateObject private var app = AppModel()
    @StateObject private var syncer: AlbumSyncer
    @StateObject private var ratings: RatingStore
    @StateObject private var clipboard: EditClipboard
    #if os(macOS)
    // Sparkle's controller has to outlive the scene, so it is owned here.
    @StateObject private var updater = Updater()
    #endif
    @AppStorage(PreferenceKeys.appearance) private var appearanceRaw = AppearancePreference.system.rawValue

    init() {
        let schema = Schema([AssetRating.self, LightTableEvent.self, AlbumBaseline.self, PhotoEditVersion.self, PhotoVariant.self])
        let configuration = ModelConfiguration(schema: schema, url: Self.storeURL())
        let container: ModelContainer
        do {
            container = try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Could not open the ratings store: \(error)")
        }
        self.container = container

        // Bound to locals so the StateObject autoclosures don't capture `self`
        // while it is still being initialised.
        let syncer = AlbumSyncer()
        let library = PhotoLibraryService()
        let ratings = RatingStore(context: container.mainContext, syncer: syncer)
        // A class reference, so the store always reads the current library
        // rather than a snapshot taken at launch.
        ratings.itemsProvider = { [weak library] in library?.items ?? [] }
        // Edits made in Photos only reach the store if something notices them.
        library.onLibraryChange = { [weak ratings] in ratings?.scheduleSync() }

        let clipboard = EditClipboard()
        clipboard.library = library
        clipboard.modelContext = container.mainContext

        _clipboard = StateObject(wrappedValue: clipboard)
        _syncer = StateObject(wrappedValue: syncer)
        _library = StateObject(wrappedValue: library)
        _ratings = StateObject(wrappedValue: ratings)
    }

    var body: some Scene {
        WindowGroup {
            rootView
                .preferredColorScheme(
                    (AppearancePreference(rawValue: appearanceRaw) ?? .system).colorScheme)
                // The greys the photographs sit on, resolved from the same
                // preference. Injected here so every view that draws a surface
                // reads one palette rather than each deciding for itself.
                .modifier(SurfacePalette())
                .environmentObject(library)
                .environmentObject(app)
                .environmentObject(ratings)
                .environmentObject(syncer)
                .environmentObject(clipboard)
        }
        .modelContainer(container)
        #if os(macOS)
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesCommand(updater: updater)
            }
            CommandGroup(after: .toolbar) {
                Toggle("Sync Picks to Photos Albums", isOn: $syncer.isEnabled)
                Button("Sync Now") { ratings.syncNow() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                Divider()
                // Posted rather than called directly: the command lives in the
                // App scene, the confirmation belongs to the window's view.
                Button("Rebuild from Photos Albums…") {
                    NotificationCenter.default.post(name: .rebuildFromPhotos, object: nil)
                }
                Button("Find Lost Versions…") {
                    NotificationCenter.default.post(name: .rebuildVariants, object: nil)
                }
            }

            // Absent entirely unless asked for, rather than present and
            // disabled: a menu nobody can use is still a menu everybody reads.
            if Debug.isEnabled {
                CommandMenu("Debug") {
                    Toggle("Only Photos With Versions", isOn: $app.showsOnlyFamilies)
                        .help("Narrows the grid to families, for checking what Find Lost Versions decided")
                    Toggle("Show Asset IDs", isOn: $app.showsAssetIDs)
                        .help("Prints each photo's identifier over it, for matching against the store")
                }
            }
        }
        #endif

        #if os(macOS)
        Settings {
            SettingsView()
        }
        #endif
    }

    /// The two platforms get different UIs rather than one reflowed layout: the
    /// Mac app is built around a keyboard and a pointer, the iOS app around
    /// touch.
    @ViewBuilder
    private var rootView: some View {
        #if os(macOS)
        ContentView()
        #else
        TouchRootView()
            .updateCheck()
        #endif
    }
}
