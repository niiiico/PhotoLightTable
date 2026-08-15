#if os(macOS)
import AppKit
import SwiftData
import SwiftUI

/// The light table proper: a day-sectioned grid with keyboard-driven culling.
struct LightTableView: View {
    let items: [PhotoItem]
    let sections: [DaySection]
    /// How many photos each stack stands for, keyed by the one showing.
    let stackSizes: [String: Int]
    /// Members of each opened family, so the grid can draw one outline around
    /// each rather than framing every photo separately.
    let openFamilies: [[String]]
    let events: [LightTableEvent]
    /// Opens the event editor seeded with the given photos.
    let onNewEvent: ([String]) -> Void

    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var ratings: RatingStore
    @EnvironmentObject private var library: PhotoLibraryService
    /// Observed so a changed asset's version reaches the cell that shows it.
    @ObservedObject private var loader = ThumbnailLoader.shared
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var clipboard: EditClipboard
    @FocusState private var isGridFocused: Bool

    /// Frames of the cells currently laid out, used to find what the pointer is
    /// over while dragging. LazyVGrid only materialises visible cells, so this
    /// stays small however large the library is.
    @State private var cellFrames: [String: CGRect] = [:]
    @State private var dragAnchorID: String?
    /// The selection as it stood when the current drag began, kept so a
    /// Command-drag combines against a fixed base rather than compounding.
    @State private var dragBaseSelection: Set<String> = []
    @State private var dragCombine: AppModel.SelectionCombine = .replace
    @State private var dragLastTargetID: String?
    /// The variant awaiting confirmation before it is removed from the library.
    @State private var pendingRemoval: PhotoItem?
    /// Anything that went wrong making or removing a photo.
    @State private var actionError: String?

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
                    .overlay {
                        StackOutlineOverlay(families: openFamilies,
                                            cellFrames: cellFrames,
                                            inset: spacing / 2 - 1)
                    }
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
        .alert("Remove this version?",
               isPresented: Binding(get: { pendingRemoval != nil },
                                    set: { if !$0 { pendingRemoval = nil } }),
               presenting: pendingRemoval) { item in
            Button("Remove", role: .destructive) { remove(item) }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: { item in
            Text(removalMessage(for: item))
        }
        .alert("That didn't work",
               isPresented: Binding(get: { actionError != nil },
                                    set: { if !$0 { actionError = nil } }),
               presenting: actionError) { _ in
            Button("OK", role: .cancel) { actionError = nil }
        } message: { message in
            Text(message)
        }
    }

    // MARK: - Pieces

    private var sortedEvents: [LightTableEvent] {
        events.sorted { $0.startDate > $1.startDate }
    }

    /// The event currently being browsed, if the sidebar is on one.
    private var currentEvent: LightTableEvent? {
        guard case .event(let id) = app.selection else { return nil }
        return events.first { $0.persistentModelID == id }
    }

    /// Click a photo and slide across neighbours to select the run, the way
    /// Photos does. Hold Command to toggle that run against the selection —
    /// adding photos it doesn't hold and removing ones it does. A minimum
    /// distance keeps ordinary clicks working.
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
                    let isCommand = NSEvent.modifierFlags.contains(.command)
                    dragCombine = isCommand ? .toggle : .replace
                    dragBaseSelection = isCommand ? app.selectedIDs : []
                }

                guard let anchor = dragAnchorID,
                      let target = item(at: value.location) else { return }
                // The pointer moves far more often than it crosses into a new
                // cell; recomputing the range on every point would rebuild the
                // selection set — and re-render the grid — for no change.
                guard target != dragLastTargetID else { return }
                dragLastTargetID = target
                app.selectRange(from: anchor, to: target, in: items,
                                base: dragBaseSelection, combine: dragCombine)
            }
            .onEnded { _ in
                dragAnchorID = nil
                dragBaseSelection = []
                dragCombine = .replace
                dragLastTargetID = nil
            }
    }

    /// A plain copy: the same pixels under a new asset, joined to the family so
    /// it stacks with the photo it came from.
    ///
    /// Neutral rather than carrying an adjustment, since there is no session
    /// open here to take a recipe from — this is "another one of these to work
    /// on", not "save what I have done".
    private func duplicate(_ item: PhotoItem) {
        Task {
            do {
                _ = try await PhotoVariants.create(from: item,
                                                   applying: currentRecipe(of: item),
                                                   label: "Copy",
                                                   context: context,
                                                   library: library)
                ratings.reloadVariants()
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    private func removalMessage(for item: PhotoItem) -> String {
        let name = ratings.variantLabel(for: item.id) ?? "This version"
        return """
        “\(name)” goes to Recently Deleted in Photos, where it can be brought \
        back for 30 days. The photo it was made from is not touched.
        """
    }

    /// Removes a variant from the library.
    ///
    /// The only thing in this app that deletes, and deliberately narrow: it is
    /// offered for photos the app itself created, never for an original. See
    /// docs/adr-001, which this amends.
    private func remove(_ item: PhotoItem) {
        pendingRemoval = nil
        Task {
            do {
                try await PhotoVariants.remove(item, context: context, ratings: ratings)
                await library.reload()
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    /// The stack this photo belongs to, when it is in one that is showing.
    ///
    /// Resolved through the family rather than taken as the photo's own id: an
    /// opened stack puts its variants on the table beside their source, and
    /// stacking them back up is just as reasonable a thing to ask of a variant
    /// as of the photo it came from.
    private func stackRoot(of id: String) -> String? {
        let root = ratings.rootAsset(of: id)
        return stackSizes[root] == nil ? nil : root
    }

    private func toggleStack(containing id: String) {
        guard let root = stackRoot(of: id) else { return }
        let isClosing = app.expandedStacks.contains(root)
        app.toggleStack(root)
        guard isClosing else { return }

        // Closing takes every member but the source off the table, so anything
        // focused or selected inside the family would be left pointing at a
        // photo that is no longer there — the keyboard would move from nowhere
        // and a verdict would land on something invisible.
        let family = Set(ratings.family(of: root))
        if let focusID = app.focusID, family.contains(focusID) {
            app.focusID = root
        }
        if app.selectedIDs.contains(where: { family.contains($0) }) {
            app.selectedIDs.subtract(family)
            app.selectedIDs.insert(root)
        }
    }

    /// The photo as it stands, adjustments included.
    ///
    /// There is no editing session open in the grid, so the recipe is read back
    /// from the photo itself. Passing a neutral one instead built the copy from
    /// the original pixels and threw the photo's own edit away — a split of an
    /// edited photo came out looking nothing like what was on screen.
    private func currentRecipe(of item: PhotoItem) async -> PhotoEditRecipe {
        await PhotoEditSession.recipe(of: item.asset) ?? .neutral
    }

    /// Splitting from the grid uses the photo as it stands.
    private func splitLeftRight(_ item: PhotoItem) {
        Task {
            do {
                _ = try await PhotoVariants.splitLeftRight(item,
                                                           applying: currentRecipe(of: item),
                                                           context: context,
                                                           library: library)
                ratings.reloadVariants()
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    private func photoItems(for ids: [String]) -> [PhotoItem] {
        let wanted = Set(ids)
        return items.filter { wanted.contains($0.id) }
    }

    private func pasteTitle(_ targets: [String], includingCrop: Bool) -> String {
        let noun = targets.count == 1 ? "Photo" : "\(targets.count) Photos"
        return includingCrop ? "Paste Adjustments and Crop to \(noun)"
                             : "Paste Adjustments to \(noun)"
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
                          && app.selectedIDs.contains(item.id),
                      imageVersion: loader.version(of: item.id),
                      variantLabel: ratings.variantLabel(for: item.id),
                      stackCount: stackSizes[item.id] ?? 0,
                      isStackExpanded: app.expandedStacks.contains(item.id),
                      onToggleStack: { toggleStack(containing: item.id) })
            .equatable()
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
        // Folded away: six colours at the top level pushed everything below
        // them out of reach, and the keys are how a colour is actually
        // assigned — the menu is where you go to remember which key, not to
        // avoid using it.
        Menu("Colour") {
            ForEach(ColorLabel.allCases) { color in
                Button("\(color.label)  (\(color.shortcutKey))") { ratings.setColor(color, for: targets) }
            }
            Divider()
            Button("No Colour") { ratings.setColor(nil, for: targets) }
        }
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
        if let root = stackRoot(of: item.id), let count = stackSizes[root] {
            Divider()
            Button(app.expandedStacks.contains(root)
                   ? "Stack These \(count) Versions  (S)"
                   : "Show All \(count) Versions  (S)") {
                toggleStack(containing: item.id)
            }
        }
        Divider()
        Button("Duplicate") { duplicate(item) }
        Button("Split into Left and Right") { splitLeftRight(item) }
        // Offered only for photos this app made. An original is someone's
        // photograph; a variant is a copy of one, and its source is still here.
        if ratings.isVariant(item.id) {
            Button("Remove This Version…", role: .destructive) { pendingRemoval = item }
        }
        Divider()
        Button("Copy Adjustments") {
            Task { await clipboard.copy(from: item) }
        }
        if clipboard.hasContents {
            Button(pasteTitle(targets, includingCrop: false)) {
                Task { await clipboard.paste(to: photoItems(for: targets), includingCrop: false) }
            }
            Button(pasteTitle(targets, includingCrop: true)) {
                Task { await clipboard.paste(to: photoItems(for: targets), includingCrop: true) }
            }
            .help("Also applies the copied crop, which is rarely right across different compositions")
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
        case "s":
            // Only the focused cell: opening every stack in a wide selection
            // would rearrange the grid under the cursor.
            guard let focusID = app.focusID, stackRoot(of: focusID) != nil else { return .ignored }
            toggleStack(containing: focusID)
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
#endif
