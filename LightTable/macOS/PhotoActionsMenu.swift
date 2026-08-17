#if os(macOS)
import SwiftUI

/// Everything you can do to a photograph, wherever the photograph is.
///
/// It began as the grid's context menu. The same commands are wanted on the
/// filmstrip and on the photograph in the loupe — a verdict, a colour, a copy of
/// the adjustments — and a second copy of them would drift from the first within
/// a week. What differs between the three is only which items make sense there,
/// which is what `Shows` says.
struct PhotoActionsMenu: View {
    /// A family this photo is part of, when the host is in a position to know
    /// how many of its members are showing. Only the grid is.
    struct Stack {
        let count: Int
        let isExpanded: Bool
        let toggle: () -> Void
    }

    struct Shows: OptionSet {
        let rawValue: Int

        static let openInLoupe = Shows(rawValue: 1 << 0)
        static let events = Shows(rawValue: 1 << 1)
        static let selectRelated = Shows(rawValue: 1 << 2)

        static let inGrid: Shows = [.openInLoupe, .events, .selectRelated]
        /// The filmstrip: the loupe is already open and this photograph is one
        /// click away in it, but everything else still applies to a photograph
        /// you are pointing at.
        static let inFilmStrip: Shows = [.events, .selectRelated]
        /// The photograph under the loupe. It is already open, and both of the
        /// others act on a grid selection there is no way to see from here.
        static let inLoupe: Shows = []
    }

    let item: PhotoItem
    /// What the commands apply to: the selection when this photo is in it, and
    /// just this photo otherwise.
    let targets: [String]
    /// The list "select related" works within.
    let items: [PhotoItem]
    /// Passed in rather than fetched.
    ///
    /// This menu is attached to every cell in the grid, and a `@Query` inside it
    /// is a SwiftData fetch per cell — set up and torn down as cells scroll,
    /// while the user is waiting for a click to register. The hosts all have the
    /// events already.
    var events: [LightTableEvent] = []
    var stack: Stack? = nil
    let shows: Shows
    var onNewEvent: ([String]) -> Void = { _ in }
    let onError: (String) -> Void

    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var ratings: RatingStore
    @EnvironmentObject private var library: PhotoLibraryService
    @EnvironmentObject private var clipboard: EditClipboard
    @Environment(\.modelContext) private var context

    var body: some View {
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

        if shows.contains(.events) {
            Divider()
            // Always present, even with no events yet — creating the first one
            // is the item people go looking for here.
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
        }

        if let stack {
            Divider()
            Button(stack.isExpanded
                   ? "Stack These \(stack.count) Versions  (S)"
                   : "Show All \(stack.count) Versions  (S)") {
                stack.toggle()
            }
        }

        Divider()
        Button("Duplicate") { duplicate(item) }
        Button("Split into Left and Right") { splitLeftRight(item) }
        // Offered only for photos this app made. An original is someone's
        // photograph; a variant is a copy of one, and its source is still here.
        if ratings.isVariant(item.id) {
            Button("Remove This Version…", role: .destructive) { remove(item) }
                .help(removalMessage(for: item))
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

        if shows.contains(.selectRelated) {
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
        }

        if shows.contains(.openInLoupe) {
            Divider()
            Button("Open in Loupe") {
                app.focusID = item.id
                app.isLoupePresented = true
            }
        }
    }

    // MARK: - Events

    private var sortedEvents: [LightTableEvent] {
        events.sorted { $0.startDate > $1.startDate }
    }

    /// The event currently being browsed, if the sidebar is on one.
    private var currentEvent: LightTableEvent? {
        guard case .event(let id) = app.selection else { return nil }
        return events.first { $0.persistentModelID == id }
    }

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

    // MARK: - Making and unmaking photos

    /// The photo as it stands, adjustments included.
    ///
    /// There is no editing session open behind a context menu, so the recipe is
    /// read back from the photo itself. Passing a neutral one instead built the
    /// copy from the original pixels and threw the photo's own edit away — a
    /// split of an edited photo came out looking nothing like what was on
    /// screen.
    private func currentRecipe(of item: PhotoItem) async -> PhotoEditRecipe {
        await PhotoEditSession.recipe(of: item.asset) ?? .neutral
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
                app.revealFamily(of: ratings.rootAsset(of: item.id))
            } catch {
                onError(error.localizedDescription)
            }
        }
    }

    private func splitLeftRight(_ item: PhotoItem) {
        Task {
            do {
                _ = try await PhotoVariants.splitLeftRight(item,
                                                           applying: currentRecipe(of: item),
                                                           context: context,
                                                           library: library)
                ratings.reloadVariants()
                app.revealFamily(of: ratings.rootAsset(of: item.id))
            } catch {
                onError(error.localizedDescription)
            }
        }
    }

    /// Removes a variant from the library.
    ///
    /// The only thing in this app that deletes, and deliberately narrow: it is
    /// offered for photos the app itself created, never for an original. See
    /// docs/adr-001, which this amends.
    private func remove(_ item: PhotoItem) {
        Task {
            do {
                try await PhotoVariants.remove(item, context: context, ratings: ratings)
                // No scope should try to return to a photograph that has left
                // the library.
                app.forgetRemembered(item.id)
                await library.reload()
            } catch {
                onError(error.localizedDescription)
            }
        }
    }

    /// Said in the menu rather than in a dialog of our own.
    ///
    /// macOS asks for confirmation itself before deleting anything from the
    /// library, and it cannot be waived. Asking first as well meant two dialogs
    /// for one decision — the second of which is the one that actually decides.
    /// This is the part the system prompt does not say, so it goes where it can
    /// be read before committing to anything.
    private func removalMessage(for item: PhotoItem) -> String {
        let name = ratings.variantLabel(for: item.id) ?? "This version"
        return """
        “\(name)” goes to Recently Deleted in Photos, where it can be brought \
        back for 30 days. The photo it was made from is not touched.
        """
    }

    // MARK: - Adjustments

    private func photoItems(for ids: [String]) -> [PhotoItem] {
        let wanted = Set(ids)
        return items.filter { wanted.contains($0.id) }
    }

    private func pasteTitle(_ targets: [String], includingCrop: Bool) -> String {
        let noun = targets.count == 1 ? "Photo" : "\(targets.count) Photos"
        return includingCrop ? "Paste Adjustments and Crop to \(noun)"
                             : "Paste Adjustments to \(noun)"
    }
}
#endif
