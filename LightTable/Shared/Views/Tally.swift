import SwiftUI

/// Counts for whatever the sidebar has selected — one event, or the whole
/// library. Always computed before filtering, so the numbers describe the scope
/// rather than describing the filter you just applied.
struct ScopeTally {
    var total = 0
    var picked = 0
    var rejected = 0
    var unrated = 0

    init() {}

    /// Counted from the verdicts rather than from the photographs.
    ///
    /// The store holds a row only for a photograph that has been judged — a few
    /// hundred in a library of ninety thousand — so this walks hundreds where
    /// asking after every photograph in the scope walked all of them, once per
    /// keystroke while culling. `scopedIDs` is built with the rest of the
    /// projection, and only when the scope itself changes.
    ///
    /// Asked photograph by photograph rather than given a set, so the scope
    /// that is the whole library can answer from the index the library already
    /// keeps instead of having a set of every identifier built for it.
    ///
    /// It has to be asked something. A verdict outlives the photograph it was
    /// passed on — rejecting a hundred frames and then deleting them in Photos
    /// leaves a hundred rows behind — and counting those would have the chips
    /// describing a library that no longer exists.
    init(total: Int, verdicts: [String: RatingValue], isInScope: (String) -> Bool) {
        self.total = total
        for (id, value) in verdicts where isInScope(id) {
            switch value.pick {
            case .picked: picked += 1
            case .rejected: rejected += 1
            case .unrated: break
            }
        }
        // Everything not spoken for. A verdict that was set and then cleared
        // leaves a row behind, so unrated cannot be counted directly.
        unrated = max(0, total - picked - rejected)
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
