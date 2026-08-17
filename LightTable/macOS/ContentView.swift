#if os(macOS)
import SwiftData
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var library: PhotoLibraryService
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var ratings: RatingStore
    @EnvironmentObject private var syncer: AlbumSyncer
    @EnvironmentObject private var clipboard: EditClipboard
    @Environment(\.modelContext) private var context
    @Environment(\.surfaces) private var surfaces

    @Query private var events: [LightTableEvent]

    @State private var editorMode: EventEditor.Mode?
    @State private var showsShortcuts = false
    @State private var pendingImport: PhotosImport?
    @State private var pendingVariantRebuild: VariantRebuilder.Proposal?
    @State private var isGoingToDate = false
    @State private var targetDate = Date()
    @StateObject private var projection = LibraryProjection()
    /// Held here rather than left to the split view, so the loupe can fold the
    /// album list away while the window toolbar — and with it the system's own
    /// sidebar control — is hidden.
    @State private var columns = NavigationSplitViewVisibility.all

    var body: some View {
        // Recomputed only when something it actually depends on moves — notably
        // not the selection, which changes on every step of a drag.
        Debug.time("projection") {
            projection.refresh(items: library.items,
                               libraryVersion: library.version,
                               events: events,
                               app: app,
                               ratings: ratings)
        }

        return Debug.time("window body") { window }
    }

    private var window: some View {
        NavigationSplitView(columnVisibility: $columns) {
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
                                       stackSizes: projection.stackSizes,
                                       openFamilies: projection.openFamilies,
                                       timeline: projection.timeline,
                                       events: events,
                                       onNewEvent: { editorMode = .create(seedIDs: $0) })
                    }
                }
            }
            .frame(minWidth: 640, minHeight: 480)
            // Bottom left, under the grid's own content — deliberately quiet,
            // and not in the way of anything.
            .overlay(alignment: .bottomLeading) { BuildStamp() }
            // Over the detail column only, so the album list stays where it is
            // while you review: which album you are working through is part of
            // knowing what you are looking at, and it used to disappear the
            // moment the loupe opened. It can still be folded away from inside.
            .overlay {
                if app.isLoupePresented {
                    LoupeView(items: visibleItems, events: events, columns: $columns)
                        .transition(.opacity)
                }
            }
            .toolbar { toolbarContent }
            // The window's content is a fixed dark grey whatever the appearance
            // preference says, and the title bar is translucent over it: in the
            // light appearance that left the album's name as near-black text on
            // a bar tinted by the dark table under it, and each toolbar item on
            // a bright slab. The bar is told to draw dark instead, so its title
            // and its controls resolve against what they are actually on.
            .toolbarBackground(surfaces.rail, for: .windowToolbar)
            .toolbarColorScheme(.dark, for: .windowToolbar)
            // The window keeps its name — it is what Mission Control and the
            // Window menu show — but the bar draws ours instead of the system's.
            .toolbar(removing: .title)
            .navigationTitle(title)
            .navigationSubtitle(subtitle)
        }
        .sheet(item: $editorMode) { mode in
            EventEditor(mode: mode, items: library.items) { event in
                app.selection = .event(event.persistentModelID)
                scheduleEventAlbumSync()
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
        .onReceive(NotificationCenter.default.publisher(for: .goToDate)) { _ in
            // Seeded with the day you are looking at, so the picker opens where
            // you are and a jump is a nudge rather than a date entered twice.
            targetDate = focusedDate ?? projection.sections.first?.id ?? Date()
            isGoingToDate = true
        }
        .sheet(isPresented: $isGoingToDate) {
            GoToDateSheet(date: $targetDate,
                          bounds: projection.dateBounds,
                          onGo: { goToDate() })
        }
        .onReceive(NotificationCenter.default.publisher(for: .rebuildVariants)) { _ in
            pendingVariantRebuild = VariantRebuilder.proposal(for: library.items, ratings: ratings)
        }
        .alert("Find lost versions",
               isPresented: Binding(get: { pendingVariantRebuild != nil },
                                    set: { if !$0 { pendingVariantRebuild = nil } }),
               presenting: pendingVariantRebuild) { proposal in
            if proposal.isEmpty {
                Button("OK", role: .cancel) { pendingVariantRebuild = nil }
            } else {
                Button("Restore") {
                    VariantRebuilder.apply(proposal, context: context, ratings: ratings)
                    pendingVariantRebuild = nil
                }
                Button("Cancel", role: .cancel) { pendingVariantRebuild = nil }
            }
        } message: { proposal in
            Text(proposal.isEmpty
                 ? "No photos in the library look like copies of each other."
                 : """
                   Found \(proposal.summary) that share a source. Restoring \
                   stacks them together; no photo is changed or removed, and \
                   families already recorded are left alone.
                   """)
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
        // Leaving an album and coming back should land where you left it —
        // notably after making an event, which moves you to the new event and
        // used to drop you at the newest photograph on the way back.
        .onChange(of: app.selection) { _, _ in app.restoreFocusForScope() }
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

    /// The day of the photograph the keyboard is on.
    private var focusedDate: Date? {
        guard let focusID = app.focusID else { return nil }
        return visibleItems.first { $0.id == focusID }?.creationDate
    }

    /// Lands the grid on the chosen day, or the nearest one that has anything
    /// in it. Focus rather than a scroll: the grid already follows the focus,
    /// and arrowing on from where you land is the point of arriving there.
    private func goToDate() {
        isGoingToDate = false
        guard let index = DayJump.index(for: targetDate, in: projection.sections.map(\.id)),
              let landing = projection.sections[index].items.first else { return }
        app.focusID = landing.id
        app.selectedIDs = [landing.id]
    }

    // MARK: - Toolbar

    /// A toolbar item with the system's slab taken off it and the dark scheme
    /// put on.
    ///
    /// The slab is bright — brighter still once the light appearance lifts
    /// everything under it — and each of these items already carries its own
    /// shape: a menu, a slider, a run of chips. On the leading group it was
    /// also clipping the first digits of the photo count with its rounded
    /// corner. The scheme is forced because the bar is told to draw dark and
    /// custom item content would otherwise resolve `.secondary` and friends
    /// against the appearance preference instead — grey on grey.
    @ToolbarContentBuilder
    private func bareItem<Content: View>(placement: ToolbarItemPlacement = .automatic,
                                         @ViewBuilder content: () -> Content) -> some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: placement) {
                content().environment(\.colorScheme, .dark)
            }
            .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: placement) {
                content().environment(\.colorScheme, .dark)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // Kept as one item so the group can't be split apart or reordered when
        // the toolbar overflows.
        bareItem(placement: .navigation) { tallyBar }

        // The tools belong at the trailing edge. They used to be pushed there
        // by the system's title item sitting between them and the leading
        // group; with the title drawn by us that gap went, and they slid left.
        if #available(macOS 26.0, *) {
            ToolbarSpacer(.flexible)
        }

        bareItem {
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

        bareItem {
            Slider(value: $app.thumbnailSize, in: 90...360) {
                Text("Size")
            }
            .frame(width: 120)
            .help("Thumbnail size")
        }

        bareItem {
            if let progress = clipboard.progressDescription {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(progress)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            } else if let message = clipboard.errorMessage {
                Button {
                    clipboard.errorMessage = nil
                } label: {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .labelStyle(.iconOnly)
                }
                .tint(.orange)
                .help(message)
            }
        }

        bareItem {
            syncStatus
        }

        bareItem {
            Button {
                showsShortcuts = true
            } label: {
                Label("Shortcuts", systemImage: "keyboard")
            }
            .help("Keyboard shortcuts")
        }
    }

    /// Which album, how much is in it, and the chips that filter it.
    ///
    /// The name is drawn here rather than left to the window's title, which is
    /// laid down in a colour chosen for the appearance preference — near-black
    /// over a bar that is deliberately dark, and no amount of telling the bar
    /// its own scheme moved it far enough to read.
    private var tallyBar: some View {
        let tally = projection.tally
        return HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .fixedSize()
                .help(subtitle)

            Text("\(tally.total) photo\(tally.total == 1 ? "" : "s")")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.55))
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

    private func syncFailureButton(_ message: String) -> some View {
        Button {
            ratings.syncNow()
        } label: {
            Label("Sync failed", systemImage: "exclamationmark.triangle.fill")
        }
        .tint(.orange)
        .help("\(message) — click to try again")
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
            // A queued pass resets `status` to .pending, so a failure would
            // otherwise vanish before it was ever seen.
            if let message = syncer.lastError {
                syncFailureButton(message)
            } else {
                Button {
                    ratings.syncNow()
                } label: {
                    Label("Sync to Photos", systemImage: "arrow.triangle.2.circlepath")
                }
                .help("Update the LightTable albums in Photos now")
            }
        case .pending, .syncing:
            ProgressView()
                .controlSize(.small)
                .help("Updating albums in Photos…")
        case .failed(let message):
            syncFailureButton(message)
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
        ("E", "Loupe: adjust the photo"),
        ("C", "Loupe: crop (while adjusting)"),
        ("\\", "Loupe: compare before and after"),
        ("Z", "Loupe: zoom to 250% / fit"),
        ("+ −", "Loupe: zoom in / out"),
        ("← → ↑ ↓", "Move between photos"),
        ("⇧ + arrows", "Extend selection"),
        ("Drag", "Select a run of photos"),
        ("⌘ + click / drag", "Add to or remove from the selection"),
        ("Space / Return", "Open or close the loupe"),
        ("⌘A", "Select all"),
        ("⌘G", "Go to a date"),
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
