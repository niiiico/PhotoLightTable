#if os(macOS)
import AppKit
import SwiftData
import SwiftUI

/// The light table proper: a day-sectioned grid with keyboard-driven culling.
struct LightTableView: View {
    let items: [PhotoItem]
    let events: [LightTableEvent]
    /// Opens the event editor seeded with the given photos.
    let onNewEvent: ([String]) -> Void

    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var ratings: RatingStore
    @Environment(\.modelContext) private var context
    @FocusState private var isGridFocused: Bool

    /// Frames of the cells currently laid out, used to find what the pointer is
    /// over while dragging. LazyVGrid only materialises visible cells, so this
    /// stays small however large the library is.
    @State private var cellFrames: [String: CGRect] = [:]
    @State private var dragAnchorID: String?
    /// The selection as it stood when the current drag began, kept so a
    /// Command-drag can add to it without swallowing it.
    @State private var dragBaseSelection: Set<String>?

    private let spacing: CGFloat = 10
    private static let gridSpace = "lightTableGrid"

    var body: some View {
        GeometryReader { geo in
            let columns = columnCount(for: geo.size.width)
            ScrollViewReader { proxy in
                ScrollView {
                    ZStack(alignment: .top) {
                        // Sits behind the grid and swallows clicks that miss a
                        // cell, so clicking empty space clears the selection.
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { clearSelection() }

                        LazyVGrid(columns: gridItems(count: columns),
                                  spacing: spacing,
                                  pinnedViews: [.sectionHeaders]) {
                            ForEach(sections) { section in
                                Section {
                                    ForEach(section.items) { item in
                                        cell(for: item)
                                    }
                                } header: {
                                    sectionHeader(section)
                                }
                            }
                        }
                        .padding(spacing)
                    }
                    .coordinateSpace(name: Self.gridSpace)
                    .onPreferenceChange(CellFramesKey.self) { cellFrames = $0 }
                    .gesture(dragSelectGesture)
                }
                .background {
                    // Covers the area below the last row, which the ZStack above
                    // does not extend into.
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { clearSelection() }
                }
                .onChange(of: app.focusID) { _, newValue in
                    guard let newValue else { return }
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(newValue, anchor: .center)
                    }
                }
            }
            .onAppear { app.columnCount = columns }
            .onChange(of: columns) { _, newValue in app.columnCount = newValue }
        }
        .focusable()
        .focused($isGridFocused)
        .focusEffectDisabled()
        .onAppear { isGridFocused = true }
        .onTapGesture { isGridFocused = true }
        .onKeyPress(action: handleKey)
        .overlay {
            if items.isEmpty { emptyState }
        }
    }

    // MARK: - Pieces

    private var sections: [DaySection] {
        PhotoLibraryService.groupByDay(items, oldestFirst: app.sortOrder == .oldestFirst)
    }

    private var sortedEvents: [LightTableEvent] {
        events.sorted { $0.startDate > $1.startDate }
    }

    /// The event currently being browsed, if the sidebar is on one.
    private var currentEvent: LightTableEvent? {
        guard case .event(let id) = app.selection else { return nil }
        return events.first { $0.persistentModelID == id }
    }

    /// Click a photo and slide across neighbours to select the run, the way
    /// Photos does. Hold Command to add that run to what's already selected.
    /// A minimum distance keeps ordinary clicks working.
    private var dragSelectGesture: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named(Self.gridSpace))
            .onChanged { value in
                isGridFocused = true

                if dragAnchorID == nil {
                    dragAnchorID = item(at: value.startLocation)
                    // SwiftUI's drag value carries no modifier flags, so the
                    // keyboard is read directly — and only at the start, so
                    // pressing Command mid-drag doesn't change the rules
                    // underneath the gesture.
                    dragBaseSelection = NSEvent.modifierFlags.contains(.command)
                        ? app.selectedIDs : nil
                }

                guard let anchor = dragAnchorID,
                      let target = item(at: value.location) else { return }
                app.selectRange(from: anchor, to: target, in: items,
                                addingTo: dragBaseSelection)
            }
            .onEnded { _ in
                dragAnchorID = nil
                dragBaseSelection = nil
            }
    }

    /// SwiftUI taps don't report modifier flags, so read them from AppKit.
    private static func currentModifiers() -> EventModifiers {
        let flags = NSEvent.modifierFlags
        var modifiers: EventModifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        return modifiers
    }

    private func item(at point: CGPoint) -> String? {
        cellFrames.first { $0.value.contains(point) }?.key
    }

    private func clearSelection() {
        app.selectedIDs = []
        isGridFocused = true
    }

    // MARK: - Event membership

    /// Pins photos into an event regardless of their date, and lifts any
    /// previous exclusion so re-adding a removed photo works.
    private func add(_ ids: [String], to event: LightTableEvent) {
        guard !ids.isEmpty else { return }
        var pinned = Set(event.pinnedAssetIDs)
        pinned.formUnion(ids)
        event.pinnedAssetIDs = Array(pinned)
        event.excludedAssetIDs.removeAll { ids.contains($0) }
        try? context.save()
    }

    /// Excludes photos from an event. Needed as well as unpinning, because a
    /// photo can also be a member purely by falling inside the date range.
    private func remove(_ ids: [String], from event: LightTableEvent) {
        guard !ids.isEmpty else { return }
        event.pinnedAssetIDs.removeAll { ids.contains($0) }
        var excluded = Set(event.excludedAssetIDs)
        excluded.formUnion(ids)
        event.excludedAssetIDs = Array(excluded)
        try? context.save()
    }

    private func gridItems(count: Int) -> [GridItem] {
        Array(repeating: GridItem(.fixed(app.thumbnailSize), spacing: spacing), count: count)
    }

    private func columnCount(for width: CGFloat) -> Int {
        let usable = width - spacing * 2
        return max(1, Int((usable + spacing) / (app.thumbnailSize + spacing)))
    }

    private func cell(for item: PhotoItem) -> some View {
        ThumbnailCell(item: item,
                      size: app.thumbnailSize,
                      rating: ratings.rating(for: item.id),
                      isSelected: app.selectedIDs.contains(item.id),
                      isFocused: app.focusID == item.id,
                      showsSelectionBadge: app.selectedIDs.count > 1
                          && app.selectedIDs.contains(item.id))
            .id(item.id)
            .background(
                GeometryReader { geo in
                    Color.clear.preference(
                        key: CellFramesKey.self,
                        value: [item.id: geo.frame(in: .named(Self.gridSpace))])
                }
            )
            .onTapGesture(count: 2) {
                app.focusID = item.id
                app.selectedIDs = [item.id]
                app.isLoupePresented = true
            }
            // One tap handler that reads the keyboard itself. Separate
            // modifier-qualified TapGestures also fire the unqualified one, so a
            // Command-click toggled the photo and was then immediately replaced
            // by a plain click on the same photo.
            .onTapGesture {
                app.click(item, in: items, modifiers: Self.currentModifiers())
                isGridFocused = true
            }
            .contextMenu { contextMenu(for: item) }
    }

    @ViewBuilder
    private func contextMenu(for item: PhotoItem) -> some View {
        let targets = app.selectedIDs.contains(item.id) ? app.targetIDs() : [item.id]
        // Shortcuts are spelled into the titles rather than attached with
        // .keyboardShortcut: these keys are already handled by onKeyPress, and a
        // menu-registered equivalent could fire the same toggle twice, which
        // would silently cancel itself out.
        Button("Pick  (P)") { ratings.setPick(.picked, for: targets) }
        Button("Reject  (X)") { ratings.setPick(.rejected, for: targets) }
        Button("Clear Rating  (U)") { ratings.clear(targets) }
        Divider()
        ForEach(ColorLabel.allCases) { color in
            Button("\(color.label)  (\(color.shortcutKey))") { ratings.setColor(color, for: targets) }
        }
        Button("No Colour") { ratings.setColor(nil, for: targets) }
        Divider()
        // Always present, even with no events yet — creating the first one is
        // the item people go looking for here.
        Menu("Add to Event") {
            Button("New Event from Selection…") { onNewEvent(targets) }
            if !events.isEmpty {
                Divider()
                ForEach(sortedEvents) { event in
                    Button(event.name) { add(targets, to: event) }
                }
            }
        }
        if let current = currentEvent {
            Button("Remove from “\(current.name)”") { remove(targets, from: current) }
        }
        Divider()
        Menu("Select Related") {
            ForEach(ClusterGranularity.allCases) { option in
                Button(option.label) {
                    app.focusID = item.id
                    if !app.selectedIDs.contains(item.id) { app.selectedIDs = [item.id] }
                    app.relatedGranularity = option
                    app.selectRelated(in: items)
                }
            }
        }
        Divider()
        Button("Open in Loupe") {
            app.focusID = item.id
            app.isLoupePresented = true
        }
    }

    private func sectionHeader(_ section: DaySection) -> some View {
        HStack {
            Text(section.title)
                .font(.headline)
            Text("\(section.items.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
            Spacer()
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .background(.regularMaterial)
    }

    private var emptyState: some View {
        ContentUnavailableView(
            app.hasActiveFilter ? "Nothing matches this filter" : "No photos here",
            systemImage: app.hasActiveFilter ? "line.3.horizontal.decrease.circle" : "photo.on.rectangle",
            description: Text(app.hasActiveFilter
                              ? "Try clearing the filter to see the rest of this selection."
                              : "Pick a different date range or event in the sidebar.")
        )
    }

    // MARK: - Keyboard

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        let extend = press.modifiers.contains(.shift)

        switch press.key {
        case .leftArrow:
            app.move(by: -1, in: items, extendSelection: extend); return .handled
        case .rightArrow:
            app.move(by: 1, in: items, extendSelection: extend); return .handled
        case .upArrow:
            app.move(by: -app.columnCount, in: items, extendSelection: extend); return .handled
        case .downArrow:
            app.move(by: app.columnCount, in: items, extendSelection: extend); return .handled
        case .space, .return:
            if app.focusID != nil { app.isLoupePresented = true }
            return .handled
        case .escape:
            app.selectedIDs = []
            return .handled
        default:
            break
        }

        guard let character = press.characters.lowercased().first else { return .ignored }

        if press.modifiers.contains(.command) {
            if character == "a" { app.selectAll(items); return .handled }
            return .ignored
        }

        let targets = app.targetIDs()
        guard !targets.isEmpty else { return .ignored }

        switch character {
        case "p":
            ratings.setPick(.picked, for: targets)
            advanceAfterVerdict()
            return .handled
        case "x":
            ratings.setPick(.rejected, for: targets)
            advanceAfterVerdict()
            return .handled
        case "u":
            ratings.clear(targets)
            return .handled
        case "r":
            app.selectRelated(in: items)
            return .handled
        default:
            if let color = ColorLabel.forShortcutKey(character) {
                ratings.setColor(color, for: targets)
                return .handled
            }
            return .ignored
        }
    }

    /// After a verdict on a single photo, step forward so culling is a rhythm
    /// rather than press-then-arrow. Multi-selection stays put.
    private func advanceAfterVerdict() {
        guard app.selectedIDs.count <= 1 else { return }
        app.move(by: 1, in: items, extendSelection: false)
    }
}

/// Collects cell frames so a drag can tell which photo it is over.
struct CellFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}
#endif
