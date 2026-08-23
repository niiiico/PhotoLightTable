#if os(macOS)
import SwiftData
import SwiftUI

/// What an import would do, laid out so it can be read and argued with.
///
/// This replaced an alert whose message had grown to four sentences of counts:
/// "52 collections, 6,306 photographs found, 40 already exist and would gain
/// 118, 678 are in an event but no longer in its collection". Every number in
/// it was true and none of them said *which*, so the only honest thing to do
/// with it was press Cancel.
///
/// Four groups, because there are four different things an import does, and a
/// row for each with a box in front of it: nothing here happens because
/// something else was wanted.
struct LightroomImportSheet: View {
    let proposal: LightroomImport.Proposal
    let onApply: (LightroomImport.Proposal, LightroomImport.Mode) -> Void

    @Environment(\.dismiss) private var dismiss

    /// Chosen by collection id. New and updated events start ticked, because
    /// that is what asking for an import means.
    @State private var chosen: Set<Int64> = []
    /// Events whose collection has gone. Unticked: removing something is never
    /// the default.
    @State private var removing: Set<PersistentIdentifier> = []
    /// Whether an update also takes out what the collection no longer lists.
    @State private var replacesMembership = false
    @State private var hasPrepared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    group("New events",
                          note: "Collections with no event here yet.",
                          plans: proposal.fresh.filter { $0.adopts == nil })
                    group("Recognised after renaming here",
                          note: "Moved or renamed in LightTable; matched by the photographs they hold, not by name.",
                          plans: proposal.plans.filter { $0.adopts != nil })
                    group("Already imported",
                          note: "Events that stand for a collection and would take what it has gained.",
                          plans: proposal.updates.filter { $0.adopts == nil })
                    vanishedGroup
                    emptyGroup
                }
                .padding(20)
            }

            Divider()
            footer
        }
        .frame(width: 640, height: 560)
        .onAppear {
            guard !hasPrepared else { return }
            hasPrepared = true
            chosen = Set(proposal.plans.filter { !$0.addsNothing }.map(\.id))
        }
    }

    // MARK: - Pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Import Lightroom collections")
                .font(.headline)
            Text(proposal.summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
    }

    @ViewBuilder
    private func group(_ title: String, note: String, plans: [LightroomImport.Plan]) -> some View {
        if !plans.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle(title, count: plans.count) {
                    let ids = Set(plans.map(\.id))
                    if ids.isSubset(of: chosen) { chosen.subtract(ids) } else { chosen.formUnion(ids) }
                }
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // Rows that would change nothing sink to the bottom of their
                // group and go quiet. They are still there — a collection that
                // has stopped gaining is a fact worth being able to see — but
                // they should not be the first thing read, and they start
                // unticked because ticking them buys nothing.
                ForEach(plans.sorted { !$0.addsNothing && $1.addsNothing }) { plan in
                    Toggle(isOn: binding(for: plan.id)) {
                        HStack(spacing: 8) {
                            Text(plan.name)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 12)
                            Text(detail(for: plan))
                                .font(.caption.monospacedDigit())
                                .fixedSize()
                        }
                        .foregroundStyle(plan.addsNothing ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                    }
                    .toggleStyle(.checkbox)
                }
            }
        }
    }

    @ViewBuilder
    private var vanishedGroup: some View {
        if !proposal.vanished.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle("Collections no longer in the catalogue",
                             count: proposal.vanished.count) {
                    let ids = Set(proposal.vanished.map(\.persistentModelID))
                    if ids.isSubset(of: removing) { removing.subtract(ids) } else { removing.formUnion(ids) }
                }
                Text("Events that came from this catalogue and have no collection in it any more. Ticking one deletes the event; no photograph is touched.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(proposal.vanished) { event in
                    Toggle(isOn: Binding(
                        get: { removing.contains(event.persistentModelID) },
                        set: { on in
                            if on { removing.insert(event.persistentModelID) }
                            else { removing.remove(event.persistentModelID) }
                        }
                    )) {
                        HStack(spacing: 8) {
                            Text(event.name).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 12)
                            Text("\(event.pinnedAssetIDs.count) photographs")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .fixedSize()
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }
        }
    }

    /// Collections that cannot be imported yet, and how much of each is
    /// waiting. Listed rather than left out: "why is this one not here?" is a
    /// question the sheet should answer without anyone having to ask it.
    @ViewBuilder
    private var emptyGroup: some View {
        if !proposal.empty.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("Nothing in the library yet").font(.system(size: 13, weight: .semibold))
                    Text("\(proposal.empty.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                Text("Their photographs are not in Photos, so there is nothing to make an event from. Import them and run this again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(proposal.empty) { collection in
                    HStack(spacing: 8) {
                        Text(collection.name).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 12)
                        Text("\(collection.photographs) missing")
                            .font(.caption.monospacedDigit())
                            .fixedSize()
                    }
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 21)
                }
            }
        }
    }

    private func sectionTitle(_ title: String, count: Int, toggleAll: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 13, weight: .semibold))
            Text("\(count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
            Button("All / None", action: toggleAll)
                .buttonStyle(.link)
                .font(.caption)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            if proposal.stale > 0 {
                Toggle(isOn: $replacesMembership) {
                    Text("Also remove photographs the collections no longer list (\(proposal.stale))")
                }
                .toggleStyle(.checkbox)
                .help("Off, an import only adds. On, the chosen events end up holding exactly what their collection does.")
            }

            HStack {
                Text(plan)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Import") {
                    onApply(filtered, replacesMembership ? .replace : .merge)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(chosen.isEmpty && removing.isEmpty)
            }
        }
        .padding(20)
    }

    // MARK: - What was chosen

    /// The proposal narrowed to what is ticked, so nothing downstream has to
    /// know about the choosing.
    private var filtered: LightroomImport.Proposal {
        var narrowed = proposal
        narrowed.plans = proposal.plans.filter { chosen.contains($0.id) }
        narrowed.vanished = proposal.vanished.filter { removing.contains($0.persistentModelID) }
        return narrowed
    }

    private var plan: String {
        let new = filtered.plans.filter { !$0.isUpdate }.count
        let updated = filtered.plans.filter(\.isUpdate).count
        var parts: [String] = []
        if new > 0 { parts.append("create \(new)") }
        if updated > 0 { parts.append("update \(updated)") }
        if !filtered.vanished.isEmpty { parts.append("delete \(filtered.vanished.count)") }
        return parts.isEmpty ? "Nothing chosen" : parts.joined(separator: ", ").capitalizedFirst
    }

    private func binding(for id: Int64) -> Binding<Bool> {
        Binding(
            get: { chosen.contains(id) },
            set: { on in if on { chosen.insert(id) } else { chosen.remove(id) } }
        )
    }

    private func detail(for plan: LightroomImport.Plan) -> String {
        var parts: [String] = []
        if plan.isUpdate {
            parts.append(plan.newMembers == 0 ? "nothing new" : "+\(plan.newMembers)")
            if plan.staleMembers > 0 { parts.append("−\(plan.staleMembers)") }
        } else {
            parts.append("\(plan.assetIDs.count) photographs")
        }
        if plan.missing > 0 { parts.append("\(plan.missing) missing") }
        return parts.joined(separator: " · ")
    }
}

private extension String {
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
#endif
