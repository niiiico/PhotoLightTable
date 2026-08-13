import SwiftUI

/// Frames of the cells currently laid out, in the grid's own coordinate space.
///
/// Shared by drag selection, which needs to know what the pointer is over, and
/// by the stack outline, which needs to know where a family sits on screen.
/// `LazyVGrid` only materialises visible cells, so this stays small however
/// large the library is.
struct CellFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

enum StackOutline {
    /// One rectangle per row the family occupies.
    ///
    /// A family is drawn around rather than each of its photos being framed
    /// individually — the point is that they are *one* frame seen several ways,
    /// and a border per cell says the opposite. But a run of cells wraps, so a
    /// single union rectangle would swallow unrelated photos on the rows
    /// between. Splitting by row gives the same shape a text selection has: a
    /// partial row, whole rows, a partial row.
    ///
    /// Rows are found by grouping on `minY` rather than by asking the grid,
    /// which does not report what it laid out where.
    static func segments(for frames: [CGRect], rowTolerance: CGFloat = 1) -> [CGRect] {
        guard !frames.isEmpty else { return [] }

        let sorted = frames.sorted { lhs, rhs in
            lhs.minY == rhs.minY ? lhs.minX < rhs.minX : lhs.minY < rhs.minY
        }

        var rows: [[CGRect]] = []
        for frame in sorted {
            if let last = rows.last?.first, abs(last.minY - frame.minY) <= rowTolerance {
                rows[rows.count - 1].append(frame)
            } else {
                rows.append([frame])
            }
        }

        return rows.map { row in
            row.dropFirst().reduce(row[0]) { $0.union($1) }
        }
    }
}

/// Draws a light outline around each opened family.
///
/// Sits in the grid's spacing gutter rather than over the photographs: the
/// outline says these belong together, and covering the pictures to say it
/// would defeat the point of a light table.
struct StackOutlineOverlay: View {
    /// Member ids per opened family, in the order they are laid out.
    let families: [[String]]
    let cellFrames: [String: CGRect]
    /// How far outside the cells the outline sits. Must stay inside half the
    /// grid's spacing or neighbouring outlines touch.
    var inset: CGFloat = 4

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(families.enumerated()), id: \.offset) { _, family in
                ForEach(Array(segments(of: family).enumerated()), id: \.offset) { _, rect in
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(.white.opacity(0.55), lineWidth: 1.5)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                }
            }
        }
        // Never in the way of a click, a drag, or a drop.
        .allowsHitTesting(false)
    }

    private func segments(of family: [String]) -> [CGRect] {
        // Only what is on screen: a family scrolled half out of view is drawn
        // around the part that is showing rather than not at all.
        let frames = family.compactMap { cellFrames[$0] }
        return StackOutline.segments(for: frames).map { $0.insetBy(dx: -inset, dy: -inset) }
    }
}
