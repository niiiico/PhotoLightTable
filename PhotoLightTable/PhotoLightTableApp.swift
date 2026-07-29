import SwiftData
import SwiftUI

@main
struct PhotoLightTableApp: App {
    private let container: ModelContainer
    @StateObject private var library = PhotoLibraryService()
    @StateObject private var app = AppModel()
    @StateObject private var syncer: AlbumSyncer
    @StateObject private var ratings: RatingStore

    init() {
        let schema = Schema([AssetRating.self, LightTableEvent.self, AlbumBaseline.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
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
        let context = container.mainContext
        _syncer = StateObject(wrappedValue: syncer)
        _ratings = StateObject(wrappedValue: RatingStore(context: context, syncer: syncer))
    }

    var body: some Scene {
        WindowGroup {
            rootView
                .environmentObject(library)
                .environmentObject(app)
                .environmentObject(ratings)
                .environmentObject(syncer)
        }
        .modelContainer(container)
        #if os(macOS)
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(after: .toolbar) {
                Toggle("Sync Picks to Photos Albums", isOn: $syncer.isEnabled)
                Button("Sync Now") { ratings.syncNow() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
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
        #endif
    }
}
