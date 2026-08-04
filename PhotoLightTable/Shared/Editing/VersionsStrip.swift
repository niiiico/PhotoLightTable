import SwiftUI

/// Every photo made from the same pixels, and which one is open.
///
/// Photos treats a duplicate as an unrelated asset, so without this the
/// relationship is only visible as a badge in the grid. Shown while editing
/// because that is where the question arises: what else exists of this frame,
/// and is the treatment being made already there.
struct VersionsStrip: View {
    let family: [String]
    let currentID: String
    let label: (String) -> String?
    let onSelect: (String) -> Void

    var body: some View {
        if family.count > 1 {
            VStack(alignment: .leading, spacing: 6) {
                Text("Versions")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(family, id: \.self) { id in
                            chip(for: id)
                        }
                    }
                }
            }
        }
    }

    private func chip(for id: String) -> some View {
        let isCurrent = id == currentID
        // The first entry is the source; the rest carry the name they were
        // saved under.
        let name = label(id) ?? "Original"

        return Button {
            guard !isCurrent else { return }
            onSelect(id)
        } label: {
            Text(name)
                .font(.caption)
                .foregroundStyle(isCurrent ? Color.white : .primary)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(isCurrent ? Color.accentColor : Color.secondary.opacity(0.18),
                            in: Capsule())
        }
        .buttonStyle(.plain)
        .help(isCurrent ? "\(name) — open" : "Open \(name)")
    }
}
