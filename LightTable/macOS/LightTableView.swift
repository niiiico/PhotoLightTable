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
    /// The rail's scale, prepared with the sections it is drawn from.
    let timeline: TimelineData
    let events: [LightTableEvent]
    /// Opens the event editor seeded with the given photos.
    let onNewEvent: ([String]) -> Void

    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var ratings: RatingStore
    @EnvironmentObject private var library: PhotoLibraryService
    /// Observed so a changed asset's version reaches the cell that shows it.
    @ObservedObject private var loader = ThumbnailLoader.shared
    @Environment(\.modelContext) private var context
    @Environment(\.surfaces) private var surfaces
    @EnvironmentObject private var clipboard: EditClipboard
    @FocusState private var isGridFocused: Bool

    /// Frames of the cells currently laid out, used to find what the pointer is
    /// over while dragging. LazyVGrid only materialises visible cells, so this
    /// stays small however large the library is.
    @State private var cellFrames = CellFrames()
    @State private var dragAnchorID: String?
    /// The selection as it stood when the current drag began, kept so a
    /// Command-drag combines against a fixed base rather than compounding.
    @State private var dragBaseSelection: Set<String> = []
    @State private var dragCombine: AppModel.SelectionCombine = .replace
    @State private var dragLastTargetID: String?
    /// The variant awaiting confirmation before it is removed from the library.
    /// Anything that went wrong making or removing a photo.
    @State private var actionError: String?

    /// Where the grid is scrolled to. Held rather than observed — see
    /// `ScrollPosition`.
    @State private var scrollPosition = ScrollPosition()
    @AppStorage(PreferenceKeys.thumbnailFillMode) private var fillModeRaw = ThumbnailFillMode.fill.rawValue

    private let spacing: CGFloat = 10
    private static let gridSpace = "lightTableGrid"
    private static let scrollSpace = "lightTableScroll"

    var body: some View {
        Debug.time("grid body") { gridBody }
    }

    private var gridBody: some View {
        GeometryReader { geo in
            let railWidth = showsRail ? TimelineRail.width : 0
            let columns = columnCount(for: geo.size.width - railWidth)
            ScrollViewReader { proxy in
                HStack(spacing: 0) {
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
                    .onPreferenceChange(CellFramesKey.self) { cellFrames.byID = $0 }
                    .overlay {
                        StackOutlineOverlay(families: openFamilies,
                                            frames: cellFrames,
                                            inset: spacing / 2 - 1)
                    }
                    .gesture(dragSelectGesture)
                    // Read from inside the scrolled content: its distance above
                    // the top of the scroll view is how far down we are.
                    .background {
                        GeometryReader { content in
                            Color.clear.preference(
                                key: ScrollFractionKey.self,
                                value: fraction(of: content, viewport: geo.size.height))
                        }
                    }
                }
                .coordinateSpace(name: Self.scrollSpace)
                .onPreferenceChange(ScrollFractionKey.self) { fraction in
                    scrollPosition.fraction = fraction
                    primeThumbnails(around: fraction)
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
                    guard app.revealsFocus else {
                        app.revealsFocus = true
                        return
                    }
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(newValue, anchor: .center)
                    }
                }

                if showsRail {
                    TimelineRail(ticks: timeline.ticks,
                                 position: scrollPosition,
                                 previewFor: { preview(atFraction: $0) },
                                 revealsHidden: app.revealsHiddenPhotos,
                                 onLand: { land(at: $0, proxy: proxy) })
                }
                }
            }
            .onAppear {
                app.columnCount = columns
                primeThumbnails(around: scrollPosition.fraction, force: true)
            }
            .onChange(of: columns) { _, newValue in app.columnCount = newValue }
            // A different set of photographs, or a different size of them: what
            // was decoded ahead is about the old ones.
            .onChange(of: items.count) { _, _ in
                primeThumbnails(around: scrollPosition.fraction, force: true)
            }
            .onChange(of: app.thumbnailSize) { _, _ in
                primeThumbnails(around: scrollPosition.fraction, force: true)
            }
        }
        // Neutral, and the same in either appearance: what the photographs are
        // judged against should not move when the system decides it is evening.
        .background(surfaces.table)
        .focusable()
        .focused($isGridFocused)
        .focusEffectDisabled()
        .onAppear { isGridFocused = true }
        .onTapGesture { isGridFocused = true }
        // The loupe is an overlay, so the grid is never torn down and never
        // appears again to reclaim the keyboard. Without this, closing the
        // loupe leaves the focused cell plainly visible and every key dead
        // until something is clicked — which reads as the focus being wrong
        // rather than absent.
        .onChange(of: app.isLoupePresented) { _, isPresented in
            if !isPresented { isGridFocused = true }
        }
        .onKeyPress(action: handleKey)
        .overlay {
            if items.isEmpty { emptyState }
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

    /// The stack behind the menu's "show all versions" item, when this photo
    /// is in one that is showing. Only the grid has this: it is the projection
    /// that knows how many members of a family survived the filter.
    private func stackInfo(for item: PhotoItem) -> PhotoActionsMenu.Stack? {
        guard let root = stackRoot(of: item.id), let count = stackSizes[root] else { return nil }
        return PhotoActionsMenu.Stack(count: count,
                                      isExpanded: app.expandedStacks.contains(root),
                                      toggle: { toggleStack(containing: item.id) })
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

    /// How many clicks this one is part of. AppKit counts them; SwiftUI only
    /// offers to wait for them.
    private static func currentClickCount() -> Int {
        NSApp.currentEvent?.clickCount ?? 1
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
        cellFrames.id(at: point)
    }

    private func clearSelection() {
        app.selectedIDs = []
        isGridFocused = true
    }

    private func gridItems(count: Int) -> [GridItem] {
        Array(repeating: GridItem(.fixed(app.thumbnailSize), spacing: spacing), count: count)
    }

    /// A scale is only worth its width once there is something to scan. A
    /// handful of days is a scroll, not a journey.
    private var showsRail: Bool { sections.count >= 6 }

    /// The day a fraction of the way down, and the frame that opens it.
    private func preview(atFraction fraction: Double) -> (day: Date, item: PhotoItem)? {
        guard let index = TimelineIndex.index(atFraction: fraction, in: timeline.counts),
              index < sections.count,
              let first = sections[index].items.first else { return nil }
        return (sections[index].id, first)
    }

    /// Where the scrubber was let go. Setting the focus leaves the keyboard
    /// where you landed — and has the scope remember it.
    private func land(at fraction: Double, proxy: ScrollViewProxy) {
        guard let target = preview(atFraction: fraction)?.item else { return }
        proxy.scrollTo(target.id, anchor: .center)
        app.focusID = target.id
        app.selectedIDs = [target.id]
    }

    /// Tells PhotoKit which photographs are about to be needed.
    ///
    /// Nothing was calling this, so every cell decoded from cold at the moment
    /// it appeared — which is exactly when there is least time for it. A window
    /// either side of the viewport is handed to the caching manager instead,
    /// and re-handed only once the view has moved a quarter of a window, since
    /// starting and stopping caching is itself work.
    private func primeThumbnails(around fraction: Double, force: Bool = false) {
        guard !items.isEmpty else { return }
        let centre = Int(fraction * Double(items.count - 1))
        // Eight rows either side: enough to stay ahead of a flick, not so much
        // that a large thumbnail size fills memory with photographs nobody is
        // going to reach.
        let window = max(40, app.columnCount * 8)
        if !force, let last = scrollPosition.lastPrimedCentre,
           abs(last - centre) < window / 4 { return }
        scrollPosition.lastPrimedCentre = centre

        let lower = max(0, centre - window)
        let upper = min(items.count, centre + window)
        guard lower < upper else { return }
        // Hidden photographs are left out of the window: decoding one ahead of
        // time is still decoding it, and nothing is ever going to draw it.
        ThumbnailLoader.shared.updateCaching(
            visible: items[lower..<upper].filter { app.revealsHiddenPhotos || !$0.isHidden },
            size: CGSize(width: app.thumbnailSize, height: app.thumbnailSize),
            mode: ThumbnailFillMode(rawValue: fillModeRaw) ?? .fill)
    }

    /// How far down the content is scrolled, 0 to 1.
    private func fraction(of content: GeometryProxy, viewport: CGFloat) -> Double {
        let offset = -content.frame(in: .named(Self.scrollSpace)).minY
        let scrollable = max(1, content.size.height - viewport)
        return min(max(offset / scrollable, 0), 1)
    }

    private func columnCount(for width: CGFloat) -> Int {
        let usable = width - spacing * 2
        return max(1, Int((usable + spacing) / (app.thumbnailSize + spacing)))
    }

    private func cell(for item: PhotoItem) -> some View {
        ThumbnailCell(item: item,
                      size: app.thumbnailSize,
                      surfaces: surfaces,
                      rating: ratings.rating(for: item.id),
                      revealsHidden: app.revealsHiddenPhotos,
                      isSelected: app.selectedIDs.contains(item.id),
                      isFocused: app.focusID == item.id,
                      showsSelectionBadge: app.selectedIDs.count > 1
                          && app.selectedIDs.contains(item.id),
                      imageVersion: loader.version(of: item.id),
                      variantLabel: ratings.variantLabel(for: item.id),
                      stackCount: stackSizes[item.id] ?? 0,
                      isStackExpanded: app.expandedStacks.contains(item.id),
                      onToggleStack: { toggleStack(containing: item.id) },
                      showsAssetID: app.showsAssetIDs)
            .equatable()
            .id(item.id)
            .background(
                GeometryReader { geo in
                    Color.clear.preference(
                        key: CellFramesKey.self,
                        value: [item.id: geo.frame(in: .named(Self.gridSpace))])
                }
            )
            // One tap handler, which reads the mouse and the keyboard itself.
            //
            // Two reasons, and the second is the one that was being felt. A
            // separate modifier-qualified TapGesture also fires the unqualified
            // one, so a Command-click toggled the photo and was then
            // immediately replaced by a plain click on it. And a `count: 2`
            // gesture beside a `count: 1` one makes every single click wait out
            // the double-click interval before anything happens — half a second
            // of nothing, on every click in the grid, which is what "clicking
            // feels sluggish" was. AppKit has already counted the clicks by the
            // time this runs, so nothing has to be waited for.
            .onTapGesture {
                isGridFocused = true
                if Self.currentClickCount() > 1 {
                    app.focusID = item.id
                    app.selectedIDs = [item.id]
                    app.isLoupePresented = true
                } else {
                    app.click(item, in: items, modifiers: Self.currentModifiers())
                }
            }
            .contextMenu {
                PhotoActionsMenu(item: item,
                                 targets: app.selectedIDs.contains(item.id)
                                     ? app.targetIDs() : [item.id],
                                 items: items,
                                 events: events,
                                 stack: stackInfo(for: item),
                                 shows: .inGrid,
                                 onNewEvent: onNewEvent,
                                 onError: { actionError = $0 })
            }
    }

    /// A quiet rule between one day and the next.
    ///
    /// It was a bar of system material, which is bright and slightly blue and,
    /// against a table this dark, read as the loudest thing on screen — a row of
    /// headlines with the photographs underneath them. Cut from the table's own
    /// grey instead, and set in the same weight as everything else, it separates
    /// the days without asking to be read first.
    private func sectionHeader(_ section: DaySection) -> some View {
        HStack(spacing: 8) {
            Text(section.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
            Text("\(section.items.count)")
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.4))
            Spacer()
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 6)
        .background(surfaces.header)
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
