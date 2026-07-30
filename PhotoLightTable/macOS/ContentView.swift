#if os(macOS)
import SwiftData
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var library: PhotoLibraryService
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var ratings: RatingStore
    @EnvironmentObject private var syncer: AlbumSyncer
    @Environment(\.modelContext) private var context

    @Query private var events: [LightTableEvent]

    @State private var editorMode: EventEditor.Mode?
    @State private var showsShortcuts = false
    @State private var pendingImport: PhotosImport?
    @StateObject private var projection = LibraryProjection()

    var body: some View {
        // Recomputed only when something it actually depends on moves — notably
        // not the selection, which changes on every step of a drag.
        projection.refresh(items: library.items,
                           libraryVersion: library.version,
                           events: events,
                           app: app,
                           ratings: ratings)

        return NavigationSplitView {
            SidebarView(events: events,
                        allItems: library.items,
                        editingEvent: Binding(
                            get: { nil },
                            set: { if let event = $0 { editorMode = .edit(event) } }
                        ),
                        onNewEvent: startNewEvent,
                        onSyncSettingChanged: scheduleEventAlbumSync)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            Group {
                switch library.authState {
                case .undetermined:
                    ProgressView("Waiting for photo library access…")
                case .denied:
                    accessDenied
                case .authorized, .limited:
                    if library.isLoading && library.items.isEmpty {
                        ProgressView("Loading library…")
                    } else {
                        LightTableView(items: visibleItems,
                                       sections: projection.sections,
                                       events: events,
                                       onNewEvent: { editorMode = .create(seedIDs: $0) })
                    }
                }
            }
            .frame(minWidth: 640, minHeight: 480)
            .toolbar { toolbarContent }
            .navigationTitle(title)
            .navigationSubtitle(subtitle)
        }
        .sheet(item: $editorMode) { mode in
            EventEditor(mode: mode, items: library.items) { event in
                app.selection = .event(event.persistentModelID)
                scheduleEventAlbumSync()
            }
        }
        // An overlay rather than a sheet, so the loupe covers the sidebar too and
        // fills the whole window.
        .overlay {
            if app.isLoupePresented {
                LoupeView(items: visibleItems)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.12), value: app.isLoupePresented)
        // The loupe covers the whole window, so the toolbar behind it is only
        // clutter around an image being judged.
        .toolbar(app.isLoupePresented ? .hidden : .visible, for: .windowToolbar)
        .sheet(isPresented: $showsShortcuts) { ShortcutsHelp() }
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
        .onReceive(NotificationCenter.default.publisher(for: .rebuildFromPhotos)) { _ in
            pendingImport = ratings.readImportFromPhotos()
        }
        .task {
            await library.requestAccess()
            // Reconcile once at startup. Without this, sync only ever runs off
            // an edit, so anything that drifted while the app was closed — or a
            // previous bad write — stays wrong until you happen to rate a photo.
            ratings.scheduleSync()
        }
        // Event albums depend on both ratings and membership, so rebuild the
        // plans whenever either could have moved. The syncer debounces.
        .onChange(of: ratings.revision) { _, _ in scheduleEventAlbumSync() }
        .onChange(of: library.items.count) { _, _ in scheduleEventAlbumSync() }
        .onChange(of: events.count) { _, _ in scheduleEventAlbumSync() }
    }

    // MARK: - Data

    /// Everything in the current sidebar selection, before any filter — this is
    /// what the tally describes.
    private var scopedItems: [PhotoItem] { projection.scoped }

    private var visibleItems: [PhotoItem] { projection.visible }

    private var title: String {
        switch app.selection {
        case .allPhotos:
            return "All Photos"
        case .event(let id):
            return events.first { $0.persistentModelID == id }?.name ?? "Event"
        }
    }

    private var sortBinding: Binding<PhotoSortOrder> {
        Binding(get: { app.sortOrder }, set: { app.sortOverride = $0 })
    }

    /// The tally bar already carries the scope's total, so the subtitle only
    /// earns its place when a filter makes the visible count differ.
    private var subtitle: String {
        guard app.hasActiveFilter else { return "" }
        return "Showing \(visibleItems.count) of \(scopedItems.count)"
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // Kept as one item so the group can't be split apart or reordered when
        // the toolbar overflows.
        ToolbarItem(placement: .navigation) {
            let tally = projection.tally
            HStack(spacing: 10) {
                Text("\(tally.total) photo\(tally.total == 1 ? "" : "s")")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize()
                    .help(tally.total > 0
                          ? "\(Int(tally.progress * 100))% reviewed"
                          : "Nothing in this selection")

                colourFilter

                Divider().frame(height: 14)

                TallyChips(tally: tally)
            }
            .fixedSize()
        }

        ToolbarItem {
            Menu {
                Picker("Sort", selection: sortBinding) {
                    ForEach(PhotoSortOrder.allCases) { order in
                        Label(order.label, systemImage: order.symbolName).tag(order)
                    }
                }
                .pickerStyle(.inline)

                if app.sortOverride != nil {
                    Divider()
                    Button("Use Default for This View") { app.sortOverride = nil }
                }
            } label: {
                Label("Sort", systemImage: app.sortOrder.symbolName)
            }
            .help(app.sortOrder == .oldestFirst
                  ? "Oldest first — the default inside an event"
                  : "Newest first — the default for the whole library")
        }

        ToolbarItem {
            Slider(value: $app.thumbnailSize, in: 90...360) {
                Text("Size")
            }
            .frame(width: 120)
            .help("Thumbnail size")
        }

        ToolbarItem {
            syncStatus
        }

        ToolbarItem {
            Button {
                showsShortcuts = true
            } label: {
                Label("Shortcuts", systemImage: "keyboard")
            }
            .help("Keyboard shortcuts")
        }
    }

    /// Shows the active labels as dots rather than a generic icon, so the
    /// current colour filter is readable without opening the menu.
    private var colourFilter: some View {
        Menu {
            ForEach(ColorLabel.allCases) { color in
                Toggle(isOn: Binding(
                    get: { app.colorFilter.contains(color) },
                    set: { _ in app.toggleColorFilter(color) }
                )) {
                    Label(color.label, systemImage: "circle.fill")
                }
            }
            Divider()
            Button("Clear Colour Filter") { app.colorFilter = [] }
                .disabled(app.colorFilter.isEmpty)
        } label: {
            if app.colorFilter.isEmpty {
                Label("Colours", systemImage: "circle.grid.2x2")
            } else {
                HStack(spacing: 2) {
                    ForEach(ColorLabel.allCases.filter { app.colorFilter.contains($0) }) { color in
                        Circle()
                            .fill(color.color)
                            .frame(width: 9, height: 9)
                    }
                }
            }
        }
        .help(app.colorFilter.isEmpty
              ? "Filter by colour label"
              : "Showing \(app.colorFilter.count) colour label\(app.colorFilter.count == 1 ? "" : "s")")
    }

    @ViewBuilder
    private var syncStatus: some View {
        switch syncer.status {
        case .idle:
            Button {
                ratings.syncNow()
            } label: {
                Label("Sync to Photos", systemImage: "arrow.triangle.2.circlepath")
            }
            .help("Update the LightTable albums in Photos now")
        case .pending, .syncing:
            ProgressView()
                .controlSize(.small)
                .help("Updating albums in Photos…")
        case .failed(let message):
            Button {
                ratings.syncNow()
            } label: {
                Label("Sync failed", systemImage: "exclamationmark.triangle.fill")
            }
            .tint(.orange)
            .help(message)
        }
    }

    // MARK: - Actions

    private func scheduleEventAlbumSync() {
        ratings.scheduleSync()
    }

    private func startNewEvent() {
        // Seed from whatever is selected — the editor grows that outward to the
        // group it belongs to. With nothing selected there's nothing to grow
        // from, so the editor falls back to plain date pickers.
        editorMode = .create(seedIDs: app.targetIDs())
    }

    private var accessDenied: some View {
        ContentUnavailableView {
            Label("No access to your photo library", systemImage: "lock.fill")
        } description: {
            Text("Grant access in System Settings ▸ Privacy & Security ▸ Photos, then reopen the app.")
        } actions: {
            Button("Open Privacy Settings") {
                Platform.openPhotoPrivacySettings()
            }
        }
    }
}

extension EventEditor.Mode: Identifiable {
    var id: String {
        switch self {
        case .create(let seedIDs): return "create-\(seedIDs.count)-\(seedIDs.first ?? "none")"
        case .edit(let event): return "edit-\(event.persistentModelID.hashValue)"
        }
    }
}

struct ShortcutsHelp: View {
    @Environment(\.dismiss) private var dismiss

    private let rows: [(String, String)] = [
        ("P", "Pick (press again to clear)"),
        ("X", "Reject (press again to clear)"),
        ("U", "Clear rating"),
        ("6 7 8 9 0", "Red / Yellow / Green / Blue / Purple label"),
        ("R", "Select related photos (again to widen)"),
        ("Z", "Loupe: zoom to 250% / fit"),
        ("+ −", "Loupe: zoom in / out"),
        ("← → ↑ ↓", "Move between photos"),
        ("⇧ + arrows", "Extend selection"),
        ("Drag", "Select a run of photos"),
        ("⌘ + click / drag", "Add to the selection"),
        ("Space / Return", "Open or close the loupe"),
        ("⌘A", "Select all"),
        ("Esc", "Clear selection"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Keyboard Shortcuts")
                .font(.title2.weight(.semibold))

            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                ForEach(rows, id: \.0) { key, description in
                    GridRow {
                        Text(key)
                            .font(.system(.body, design: .monospaced).weight(.semibold))
                        Text(description)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}
#endif
