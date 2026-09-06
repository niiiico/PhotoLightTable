#if !os(macOS)
import SwiftData
import SwiftUI

/// The iOS app's shell: events down the side, the light table beside them.
///
/// A separate design from the Mac rather than a reflow of it. The Mac app is
/// driven by a keyboard and a pointer; here a verdict is a swipe and the photo
/// has to stay reachable with a thumb.
struct TouchRootView: View {
    @EnvironmentObject private var library: PhotoLibraryService
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var ratings: RatingStore
    @EnvironmentObject private var syncer: AlbumSyncer
    @State private var pendingImport: PhotosImport?

    @Query private var events: [LightTableEvent]
    @StateObject private var projection = LibraryProjection()

    @State private var columnVisibility = NavigationSplitViewVisibility.automatic

    var body: some View {
        projection.refresh(items: library.items,
                           libraryVersion: library.version,
                           events: events,
                           app: app,
                           ratings: ratings)

        return NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .task { await library.requestAccess() }
        .fullScreenCover(isPresented: $app.isLoupePresented) {
            TouchLoupe(items: projection.visible)
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List {
            Section("Library") {
                row(.allPhotos) {
                    Label("All Photos", systemImage: "photo.on.rectangle.angled")
                        .badge(library.items.count)
                }
                row(.favorites) {
                    Label("Favourites", systemImage: "heart")
                        .badge(favoriteCount)
                }
            }

            Section("Events") {
                if events.isEmpty {
                    Text("No events yet")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(events.sorted { $0.startDate > $1.startDate }) { event in
                        row(.event(event.persistentModelID)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(event.name)
                                Text(subtitle(for: event))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Light Table")
    }

    /// Selection is driven by buttons rather than `List(selection:)`, which on
    /// iOS only applies in edit mode.
    private func row<Content: View>(_ selection: LibrarySelection,
                                    @ViewBuilder content: () -> Content) -> some View {
        Button {
            app.selection = selection
            app.selectedIDs = []
        } label: {
            HStack {
                content()
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(app.selection == selection
                           ? Color.accentColor.opacity(0.18) : Color.clear)
    }

    /// Counted here rather than cached: this list is short, it is rebuilt only
    /// when the sidebar is on screen, and there is no drag through a grid
    /// behind it as there is on the Mac.
    private var favoriteCount: Int {
        library.items.count(where: \.isFavorite)
    }

    private func subtitle(for event: LightTableEvent) -> String {
        let start = event.startDate.formatted(.dateTime.day().month(.abbreviated).year())
        let end = event.endDate.formatted(.dateTime.day().month(.abbreviated).year())
        let range = start == end ? start : "\(start) – \(end)"
        guard event.isExplicit else { return range }
        let count = event.pinnedAssetIDs.count
        return "\(count) photo\(count == 1 ? "" : "s") · \(range)"
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        Group {
            switch library.authState {
            case .undetermined:
                ProgressView("Waiting for photo library access…")
            case .denied:
                ContentUnavailableView {
                    Label("No access to your photos", systemImage: "lock.fill")
                } description: {
                    Text("Grant access in Settings ▸ Privacy & Security ▸ Photos.")
                } actions: {
                    Button("Open Settings") { Platform.openPhotoPrivacySettings() }
                }
            case .authorized, .limited:
                if library.isLoading && library.items.isEmpty {
                    ProgressView("Loading library…")
                } else {
                    TouchGrid(items: projection.visible,
                              sections: projection.sections,
                              stackSizes: projection.stackSizes,
                              openFamilies: projection.openFamilies)
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .alert("Rebuild from Photos albums?",
               isPresented: Binding(get: { pendingImport != nil },
                                    set: { if !$0 { pendingImport = nil } })) {
            Button("Cancel", role: .cancel) { pendingImport = nil }
            Button("Rebuild") {
                if let pendingImport { ratings.applyImport(pendingImport) }
                pendingImport = nil
            }
        } message: {
            Text(pendingImport.map { found in
                found.isEmpty
                    ? "No LightTable albums were found in Photos."
                    : "Found \(found.summary). This adds them to what's already here — nothing is removed."
            } ?? "")
        }
        .overlay(alignment: .bottomLeading) { BuildStamp() }
    }

    private var title: String {
        switch app.selection {
        case .allPhotos: return "All Photos"
        case .favorites: return "Favourites"
        case .event(let id): return events.first { $0.persistentModelID == id }?.name ?? "Event"
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            TallyChips(tally: projection.tally)
        }

        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker("Sort", selection: Binding(
                    get: { app.sortOrder },
                    set: { app.sortOverride = $0 }
                )) {
                    ForEach(PhotoSortOrder.allCases) { order in
                        Label(order.label, systemImage: order.symbolName).tag(order)
                    }
                }

                Divider()

                Menu("Colour Label") {
                    ForEach(ColorLabel.allCases) { color in
                        Toggle(isOn: Binding(
                            get: { app.colorFilter.contains(color) },
                            set: { _ in app.toggleColorFilter(color) }
                        )) {
                            Label(color.label, systemImage: "circle.fill")
                        }
                    }
                    Button("Clear Colour Filter") { app.colorFilter = [] }
                        .disabled(app.colorFilter.isEmpty)
                }

                Divider()

                // The way an iPad catches up with a Mac. Events and verdicts
                // are mirrored into Photos albums, iCloud Photos carries those
                // between devices by itself, and this reads them back — which
                // is the whole of syncing, without anything of ours in the
                // middle to go wrong.
                Toggle("Sync Picks to Photos Albums", isOn: $syncer.isEnabled)

                Button("Rebuild from Photos Albums…", systemImage: "arrow.triangle.2.circlepath") {
                    pendingImport = ratings.readImportFromPhotos()
                }
            } label: {
                Label("View", systemImage: "ellipsis.circle")
            }
        }
    }
}
#endif
