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
                              stackSizes: projection.stackSizes)
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .overlay(alignment: .bottomLeading) { BuildStamp() }
    }

    private var title: String {
        switch app.selection {
        case .allPhotos: return "All Photos"
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
            } label: {
                Label("View", systemImage: "ellipsis.circle")
            }
        }
    }
}
#endif
