#if os(macOS)
import SwiftData
import SwiftUI

/// Create or rename an event.
///
/// Creating from a selection takes that selection literally. Growing it out to
/// the surrounding session or trip is offered, but never assumed — the user
/// picked those photos on purpose.
struct EventEditor: View {
    enum Mode {
        case create(seedIDs: [String])
        case edit(LightTableEvent)
    }

    /// Which photos the event will contain.
    enum Scope: String, CaseIterable, Identifiable {
        /// Exactly the photos that were selected.
        case selected
        /// The selection grown out to the surrounding group.
        case related

        var id: String { rawValue }
    }

    let mode: Mode
    let items: [PhotoItem]
    let onDone: (LightTableEvent) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @State private var name: String = ""
    @State private var start: Date = .now
    @State private var end: Date = .now
    @State private var scope: Scope = .selected
    @State private var granularity: ClusterGranularity = .day
    /// Only meaningful for `.related`: pin the group, or just keep the dates.
    @State private var limitToGroup = true
    @State private var syncsToPhotos = false
    @State private var didLoad = false

    private var seedIDs: [String] {
        if case .create(let ids) = mode { return ids }
        return []
    }

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    /// The photos this event will contain, given the current controls.
    private var members: [PhotoItem] {
        switch scope {
        case .selected:
            let seeds = Set(seedIDs)
            return items.filter { seeds.contains($0.id) }
        case .related:
            return EventSuggester.related(to: seedIDs, in: items, granularity: granularity)
        }
    }

    private var hasSeeds: Bool { !seedIDs.isEmpty }

    /// Whether membership is a fixed list rather than a date range. With nothing
    /// selected there is no list to fix, so the event tracks its dates instead.
    private var storesExplicitMembership: Bool {
        hasSeeds && (scope == .selected || limitToGroup)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isEditing ? "Edit Event" : "New Event")
                .font(.title2.weight(.semibold))

            Form {
                TextField("Name", text: $name, prompt: Text("Corsica"))

                if !isEditing && hasSeeds {
                    membershipSection
                }

                Section {
                    Toggle("Mirror to a folder of albums in Photos", isOn: $syncsToPhotos)
                } footer: {
                    if syncsToPhotos {
                        Text("Creates a “\(name.isEmpty ? "Event" : name)” folder in Photos holding an album of everything in the event and a “— Picked” album, both kept up to date as you cull.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    DatePicker("Starts", selection: $start, displayedComponents: .date)
                    DatePicker("Ends", selection: $end, in: start..., displayedComponents: .date)
                } footer: {
                    if !isEditing && storesExplicitMembership {
                        Text("These dates label the event; membership stays fixed to the \(members.count) photo\(members.count == 1 ? "" : "s") above.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isEditing ? "Save" : "Create") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty
                              || (hasSeeds && members.isEmpty))
            }
        }
        .padding(20)
        .frame(width: 470)
        .onAppear(perform: load)
        .onChange(of: scope) { _, _ in applySuggestion() }
        .onChange(of: granularity) { _, _ in applySuggestion() }
    }

    @ViewBuilder
    private var membershipSection: some View {
        Section {
            Picker("Include", selection: $scope) {
                Text("Only the \(seedIDs.count) selected").tag(Scope.selected)
                Text("Related group").tag(Scope.related)
            }
            .pickerStyle(.segmented)

            if scope == .related {
                Picker("Group by", selection: $granularity) {
                    ForEach(ClusterGranularity.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)

                Toggle("Fix the event to exactly these photos", isOn: $limitToGroup)
                    .help("Off means the event tracks its date range, so photos imported later can join it.")
            }

            LabeledContent("Result") {
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary)
                        .font(.body.weight(.medium))
                    if scope == .related {
                        Text(granularity.help)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Photos")
        }
    }

    private var summary: String {
        let group = members
        guard !group.isEmpty else { return "No photos" }
        let noun = group.count == 1 ? "photo" : "photos"
        guard let range = EventSuggester.dateRange(of: group) else {
            return "\(group.count) \(noun)"
        }
        let from = range.start.formatted(.dateTime.day().month(.abbreviated))
        let to = range.end.formatted(.dateTime.day().month(.abbreviated).year())
        return from == to
            ? "\(group.count) \(noun) · \(to)"
            : "\(group.count) \(noun) · \(from) – \(to)"
    }

    // MARK: - State

    private func load() {
        guard !didLoad else { return }
        didLoad = true

        switch mode {
        case .create:
            applySuggestion()
        case .edit(let event):
            name = event.name
            start = event.startDate
            end = event.endDate
            syncsToPhotos = event.isSyncedToPhotos
        }
    }

    /// Derives the labelling date range from whatever is currently included.
    /// With no seeds there is nothing to derive from, so the user's dates stand.
    private func applySuggestion() {
        guard hasSeeds else { return }
        if let range = EventSuggester.dateRange(of: members) {
            start = range.start
            end = range.end
        } else {
            start = .now
            end = .now
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let event: LightTableEvent

        switch mode {
        case .edit(let existing):
            existing.name = trimmed
            existing.startDate = start
            existing.endDate = end
            existing.syncsToPhotos = syncsToPhotos
            event = existing

        case .create:
            let group = members
            let created = LightTableEvent(name: trimmed, startDate: start, endDate: end)
            created.syncsToPhotos = syncsToPhotos
            if storesExplicitMembership {
                // A fixed list, so nothing imported later drifts into the event
                // and no exclusion list has to be maintained.
                created.explicitMembership = true
                created.pinnedAssetIDs = group.map(\.id)
            }
            context.insert(created)
            event = created
        }

        try? context.save()
        onDone(event)
        dismiss()
    }
}
#endif
