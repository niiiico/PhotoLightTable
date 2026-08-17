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
    @StateObject private var counts = EventCountCache()

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
                    ForEach(sortedEvents) { event in
                        eventRow(event)
                            .badge(counts.count(of: event))
                            .tag(LibrarySelection.event(event.persistentModelID))
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
        .background(Surfaces.rail)
        .tint(Surfaces.selection)
        .environment(\.colorScheme, .dark)
    }

    private var sortedEvents: [LightTableEvent] {
        events.sorted { $0.startDate > $1.startDate }
    }

    private func eventRow(_ event: LightTableEvent) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(event.name)
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

    func refresh(events: [LightTableEvent], items: [PhotoItem]) {
        let newKey = Key(itemCount: items.count, eventsStamp: EventMembership.stamp(of: events))
        guard newKey != key else { return }
        key = newKey
        counts = Dictionary(uniqueKeysWithValues: events.map {
            ($0.persistentModelID, EventMembership.members(of: $0, in: items).count)
        })
    }

    func count(of event: LightTableEvent) -> Int {
        counts[event.persistentModelID] ?? 0
    }
}
#endif
