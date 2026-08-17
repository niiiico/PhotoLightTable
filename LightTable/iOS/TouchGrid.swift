#if !os(macOS)
import SwiftUI

/// The light table on touch.
///
/// Tapping opens the loupe rather than selecting: on a Mac a click is cheap and
/// selection is the common act, but here the photo is what you came to look at,
/// and a multi-selection is built deliberately through long-press instead.
struct TouchGrid: View {
    let items: [PhotoItem]
    let sections: [DaySection]
    /// How many photos each stack stands for, keyed by the one showing.
    let stackSizes: [String: Int]
    /// Members of each opened family, so the grid can draw one outline around
    /// each rather than framing every photo separately.
    let openFamilies: [[String]]

    @EnvironmentObject private var app: AppModel
    @Environment(\.surfaces) private var surfaces
    @EnvironmentObject private var ratings: RatingStore
    @ObservedObject private var loader = ThumbnailLoader.shared

    @State private var cellSize: CGFloat = 120
    @State private var isSelecting = false
    /// Where each visible cell was laid out, so an opened family can be drawn
    /// around. Collected the same way the Mac grid does it.
    @State private var cellFrames: [String: CGRect] = [:]

    private static let gridSpace = "touchGrid"

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 4, pinnedViews: [.sectionHeaders]) {
                ForEach(sections) { section in
                    Section {
                        ForEach(section.items) { item in
                            cell(for: item)
                        }
                    } header: {
                        header(section)
                    }
                }
            }
            .padding(4)
            .coordinateSpace(name: Self.gridSpace)
            .onPreferenceChange(CellFramesKey.self) { cellFrames = $0 }
            .overlay {
                StackOutlineOverlay(families: openFamilies,
                                    cellFrames: cellFrames,
                                    inset: 3)
            }
        }
        .overlay {
            if items.isEmpty { emptyState }
        }
        .safeAreaInset(edge: .bottom) {
            if isSelecting && !app.selectedIDs.isEmpty { verdictBar }
        }
        // Pinching the grid is how density is changed on touch; there is no
        // slider to reach for.
        .gesture(MagnifyGesture()
            .onChanged { value in
                cellSize = min(max(80, cellSize * (1 + (value.magnification - 1) * 0.06)), 240)
            })
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: cellSize), spacing: 4)]
    }

    private func cell(for item: PhotoItem) -> some View {
        ThumbnailCell(item: item,
                      size: cellSize,
                      surfaces: surfaces,
                      rating: ratings.rating(for: item.id),
                      isSelected: app.selectedIDs.contains(item.id),
                      isFocused: app.focusID == item.id,
                      showsSelectionBadge: isSelecting && app.selectedIDs.contains(item.id),
                      imageVersion: loader.version(of: item.id),
                      variantLabel: ratings.variantLabel(for: item.id),
                      stackCount: stackSizes[item.id] ?? 0,
                      isStackExpanded: app.expandedStacks.contains(item.id),
                      onToggleStack: { toggleStack(containing: item.id) },
                      showsAssetID: app.showsAssetIDs)
        .equatable()
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: CellFramesKey.self,
                    value: [item.id: geo.frame(in: .named(Self.gridSpace))])
            }
        )
        .onTapGesture {
            if isSelecting {
                toggle(item)
            } else {
                app.focusID = item.id
                app.isLoupePresented = true
            }
        }
        .onLongPressGesture(minimumDuration: 0.35) {
            // Long press starts a selection, which is the gesture people expect
            // for it on touch, and the only way to reach one here.
            if !isSelecting {
                isSelecting = true
                app.selectedIDs = []
            }
            toggle(item)
        }
    }

    /// Stacking back up is as reasonable a thing to ask of a variant as of the
    /// photo it came from, so the family is resolved rather than the tapped
    /// photo's own id being used.
    private func toggleStack(containing id: String) {
        let root = ratings.rootAsset(of: id)
        guard stackSizes[root] != nil else { return }
        let isClosing = app.expandedStacks.contains(root)
        app.toggleStack(root)
        guard isClosing else { return }

        // Closing takes the members off the table; anything focused or selected
        // inside the family would be pointing at a photo that is gone.
        let family = Set(ratings.family(of: root))
        if let focusID = app.focusID, family.contains(focusID) {
            app.focusID = root
        }
        if app.selectedIDs.contains(where: { family.contains($0) }) {
            app.selectedIDs.subtract(family)
            app.selectedIDs.insert(root)
        }
    }

    private func toggle(_ item: PhotoItem) {
        if app.selectedIDs.contains(item.id) {
            app.selectedIDs.remove(item.id)
        } else {
            app.selectedIDs.insert(item.id)
        }
        app.focusID = item.id
    }

    private func header(_ section: DaySection) -> some View {
        HStack {
            Text(section.title)
                .font(.subheadline.weight(.semibold))
            Text("\(section.items.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(.bar)
    }

    /// Verdicts for a selection, within thumb reach at the bottom rather than in
    /// the toolbar.
    private var verdictBar: some View {
        HStack(spacing: 18) {
            Text("\(app.selectedIDs.count)")
                .font(.headline.monospacedDigit())
                .foregroundStyle(.secondary)

            Spacer()

            Button { apply(.picked) } label: {
                Label("Pick", systemImage: Pick.picked.chipSymbolName)
            }
            .tint(Pick.picked.tint)

            Button { apply(.rejected) } label: {
                Label("Reject", systemImage: Pick.rejected.chipSymbolName)
            }
            .tint(Pick.rejected.tint)

            Button { ratings.clear(Array(app.selectedIDs)) } label: {
                Label("Clear", systemImage: Pick.unrated.chipSymbolName)
            }

            Spacer()

            Button("Done") {
                isSelecting = false
                app.selectedIDs = []
            }
        }
        .buttonStyle(.bordered)
        .labelStyle(.iconOnly)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func apply(_ pick: Pick) {
        ratings.setPick(pick, for: Array(app.selectedIDs))
    }

    private var emptyState: some View {
        ContentUnavailableView(
            app.hasActiveFilter ? "Nothing matches this filter" : "No photos here",
            systemImage: app.hasActiveFilter ? "line.3.horizontal.decrease.circle" : "photo.on.rectangle",
            description: Text(app.hasActiveFilter
                              ? "Try clearing the filter to see the rest of this selection."
                              : "Pick a different event in the sidebar."))
    }
}
#endif
