#if os(macOS)
import SwiftData
import SwiftUI

struct SidebarView: View {
    let events: [LightTableEvent]
    let allItems: [PhotoItem]
    @Binding var editingEvent: LightTableEvent?
    let onNewEvent: () -> Void
    let onSyncSettingChanged: () -> Void

    @EnvironmentObject private var app: AppModel
    @Environment(\.modelContext) private var context
    @Environment(\.surfaces) private var surfaces
    @StateObject private var counts = EventCountCache()
    /// Which folders are open, remembered: a tree that forgets is a tree you
    /// re-open every launch.
    @AppStorage(PreferenceKeys.openEventFolders) private var openFolders = ""

    private var expandedFolders: Binding<Set<String>> {
        Binding(
            get: { Set(openFolders.components(separatedBy: "\n").filter { !$0.isEmpty }) },
            set: { openFolders = $0.sorted().joined(separator: "\n") }
        )
    }

    var body: some View {
        // Counting is a pass over the library per event, and this body runs on
        // every selection change — including each step of a drag across the
        // grid. The cache makes all but the first of those free.
        counts.refresh(events: events, items: allItems)

        return List(selection: $app.selection) {
            Section("Library") {
                Label("All Photos", systemImage: "photo.on.rectangle.angled")
                    .badge(allItems.count)
                    .tag(LibrarySelection.allPhotos)
            }

            Section {
                if events.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("No events yet")
                            .font(.callout)
                        Text("Select some photos, then press + or right-click ▸ Add to Event.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                } else {
                    ForEach(EventTree.build(sortedEvents, name: \.name), id: \.path) { root in
                        // The top node is the sidebar section itself, so its own
                        // events and folders are laid out directly rather than
                        // inside a disclosure of nothing.
                        ForEach(root.items) { event in
                            eventRow(event)
                                .badge(counts.count(of: event))
                                .tag(LibrarySelection.event(event.persistentModelID))
                        }
                        ForEach(root.children, id: \.path) { folder in
                            EventFolderRow(folder: folder,
                                           counts: counts,
                                           expanded: expandedFolders,
                                           row: { event in AnyView(eventRow(event)) })
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Events")
                    Spacer()
                    Button(action: onNewEvent) {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    // Explicit, because the list's tint is now the grey of the
                    // selection bar and would leave this barely visible.
                    .foregroundStyle(.white.opacity(0.65))
                    .help("New event from the current selection or date range")
                }
            }

        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        // Cut from the same neutral as the table rather than the system's
        // sidebar material, which arrives bright and faintly blue and, next to
        // a table this dark, reads as the brightest thing in the window. Dark
        // is forced inside so the system's own label and selection colours
        // resolve against it, whatever the appearance preference says.
        .background(surfaces.rail)
        .environment(\.colorScheme, .dark)
    }

    private var sortedEvents: [LightTableEvent] {
        events.sorted { $0.startDate > $1.startDate }
    }

    private func eventRow(_ event: LightTableEvent) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                if counts.isHidden(event) {
                    Image(systemName: "eye.slash")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .help("Every photograph in this event is hidden in Photos")
                }
                Text(event.name.components(separatedBy: EventTree.separator).last ?? event.name)
            }
            Text(dateRangeText(event))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .contextMenu {
            Button("Edit…") { editingEvent = event }
            Toggle("Sync to Photos Albums", isOn: Binding(
                get: { event.isSyncedToPhotos },
                set: { newValue in
                    event.syncsToPhotos = newValue
                    try? context.save()
                    onSyncSettingChanged()
                }
            ))
            Button("Delete", role: .destructive) {
                if app.selection == .event(event.persistentModelID) {
                    app.selection = .allPhotos
                }
                context.delete(event)
                try? context.save()
            }
        }
    }

    /// The range only. A fixed-membership event used to lead with its count
    /// here, which is now the number at the end of the row like every other.
    private func dateRangeText(_ event: LightTableEvent) -> String {
        let start = event.startDate.formatted(.dateTime.day().month(.abbreviated).year())
        let end = event.endDate.formatted(.dateTime.day().month(.abbreviated).year())
        return start == end ? start : "\(start) – \(end)"
    }
}

/// A folder of events, and whatever sits under it.
///
/// Recursive, because the tree is: a Lightroom catalogue nests sets three deep
/// in places, and the row for an event at the bottom has to be the same row as
/// one at the top — same badge, same lock, same menu.
private struct EventFolderRow: View {
    let folder: EventTree.Node<LightTableEvent>
    @ObservedObject var counts: EventCountCache
    @Binding var expanded: Set<String>
    let row: (LightTableEvent) -> AnyView

    var body: some View {
        DisclosureGroup(isExpanded: isOpen) {
            ForEach(folder.items) { event in
                row(event)
                    .badge(counts.count(of: event))
                    .tag(LibrarySelection.event(event.persistentModelID))
            }
            ForEach(folder.children, id: \.path) { child in
                EventFolderRow(folder: child, counts: counts, expanded: $expanded, row: row)
            }
        } label: {
            Label(folder.name, systemImage: "folder")
                .badge(photographs)
        }
    }

    private var isOpen: Binding<Bool> {
        Binding(
            get: { expanded.contains(folder.path) },
            set: { open in
                if open { expanded.insert(folder.path) } else { expanded.remove(folder.path) }
            }
        )
    }

    /// Everything underneath, so a closed folder still says how much is in it.
    private var photographs: Int {
        folder.items.reduce(0) { $0 + counts.count(of: $1) }
            + folder.children.reduce(0) { $0 + childCount($1) }
    }

    private func childCount(_ node: EventTree.Node<LightTableEvent>) -> Int {
        node.items.reduce(0) { $0 + counts.count(of: $1) }
            + node.children.reduce(0) { $0 + childCount($1) }
    }
}

/// How many photos each event holds.
///
/// Membership is a pass over the library, so this is cached against the two
/// things it depends on — the size of the library and the shape of the events.
/// Notably not the selection, which moves on every step of a drag through the
/// grid and would otherwise recount every event per frame.
@MainActor
final class EventCountCache: ObservableObject {
    private struct Key: Equatable {
        var itemCount: Int
        var eventsStamp: Int
    }

    private var key: Key?
    private var counts: [PersistentIdentifier: Int] = [:]
    private var hidden: Set<PersistentIdentifier> = []

    func refresh(events: [LightTableEvent], items: [PhotoItem]) {
        let newKey = Key(itemCount: items.count, eventsStamp: EventMembership.stamp(of: events))
        guard newKey != key else { return }
        key = newKey

        let hiddenIDs = Set(items.filter(\.isHidden).map(\.id))
        counts = [:]
        hidden = []
        for event in events {
            let members = EventMembership.members(of: event, in: items)
            counts[event.persistentModelID] = members.count
            if EventPrivacy.isHidden(memberIDs: members.map(\.id), hiddenIDs: hiddenIDs) {
                hidden.insert(event.persistentModelID)
            }
        }
    }

    func count(of event: LightTableEvent) -> Int {
        counts[event.persistentModelID] ?? 0
    }

    /// An event every one of whose photographs Photos hides.
    func isHidden(_ event: LightTableEvent) -> Bool {
        hidden.contains(event.persistentModelID)
    }
}
#endif
