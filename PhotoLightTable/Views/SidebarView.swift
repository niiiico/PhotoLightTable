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

    var body: some View {
        List(selection: $app.selection) {
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
                    .help("New event from the current selection or date range")
                }
            }

        }
        .listStyle(.sidebar)
    }

    private var sortedEvents: [LightTableEvent] {
        events.sorted { $0.startDate > $1.startDate }
    }

    private func eventRow(_ event: LightTableEvent) -> some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(event.name)
                Text(dateRangeText(event))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if event.isSyncedToPhotos {
                Image(systemName: "folder.badge.gearshape")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Mirrored to a folder of albums in Photos")
            }
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

    private func dateRangeText(_ event: LightTableEvent) -> String {
        let start = event.startDate.formatted(.dateTime.day().month(.abbreviated).year())
        let end = event.endDate.formatted(.dateTime.day().month(.abbreviated).year())
        let range = start == end ? start : "\(start) – \(end)"

        // A fixed-membership event's range is only a label, so lead with the
        // count that actually determines what's inside.
        guard event.isExplicit else { return range }
        let count = event.pinnedAssetIDs.count
        return "\(count) photo\(count == 1 ? "" : "s") · \(range)"
    }

}
