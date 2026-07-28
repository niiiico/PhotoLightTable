import SwiftUI

/// Counts for whatever the sidebar has selected — one event, or the whole
/// library. Always computed before filtering, so the numbers describe the scope
/// rather than describing the filter you just applied.
struct ScopeTally {
    var total = 0
    var picked = 0
    var rejected = 0
    var unrated = 0

    @MainActor
    init(items: [PhotoItem], ratings: RatingStore) {
        total = items.count
        for item in items {
            switch ratings.rating(for: item.id).pick {
            case .picked: picked += 1
            case .rejected: rejected += 1
            case .unrated: unrated += 1
            }
        }
    }

    var progress: Double {
        guard total > 0 else { return 0 }
        return Double(picked + rejected) / Double(total)
    }
}

/// Picked / rejected / unrated counts, each one a filter button. Sized for the
/// toolbar. Seeing "12 picked" and wanting to look at those twelve is the same
/// thought, so the count and the control are the same thing.
struct TallyChips: View {
    let tally: ScopeTally

    @EnvironmentObject private var app: AppModel

    var body: some View {
        HStack(spacing: 6) {
            chip(.picked, count: tally.picked, filter: .picked)
            chip(.rejected, count: tally.rejected, filter: .rejected)
            chip(.unrated, count: tally.unrated, filter: .unrated)
        }
    }

    private func chip(_ pick: Pick, count: Int, filter: PickFilter) -> some View {
        let isActive = app.pickFilter == filter
        return Button {
            // Clicking the active chip clears the filter, so this is a toggle
            // rather than a one-way trip.
            app.pickFilter = isActive ? .all : filter
        } label: {
            HStack(spacing: 5) {
                Image(systemName: pick.chipSymbolName)
                    .font(.system(size: 13, weight: .bold))
                Text("\(count)")
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    // Toolbar items are compressed before they are clipped, and
                    // a squeezed Text vanishes entirely — this is what stops the
                    // counts disappearing and leaving bare icons.
                    .fixedSize()
            }
            .foregroundStyle(isActive ? Color.white : pick.tint)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(isActive ? pick.tint : pick.tint.opacity(0.12), in: Capsule())
            .overlay {
                Capsule().strokeBorder(pick.tint.opacity(isActive ? 0 : 0.45), lineWidth: 1.5)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(isActive ? "Showing \(pick.label.lowercased()) only — click to clear"
                       : "Show \(pick.label.lowercased()) only")
    }
}
