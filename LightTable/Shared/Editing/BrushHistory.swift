import Foundation

/// Strokes taken off a brush mask, so they can be put back.
///
/// Kept per mask and *outside* the recipe. Undoing a stroke is a move within an
/// editing session, not something to describe to Photos — the recipe should say
/// what the photo looks like, not how the painting went.
///
/// Held separately from `EditMask` for the same reason a redo stack is not part
/// of a document: reopening the photo later should give the strokes, not the
/// history of taking them back.
struct BrushHistory {
    /// Bounded so a long session cannot accumulate without limit. Fifty is far
    /// past the point where anyone is still reasoning about which stroke comes
    /// back next.
    static let limit = 50

    private var undone: [UUID: [BrushStroke]] = [:]

    func canRedo(_ maskID: UUID) -> Bool {
        !(undone[maskID]?.isEmpty ?? true)
    }

    /// A new stroke makes the taken-back ones unreachable, which is the usual
    /// rule: once you paint again, there is no coherent "forward" left.
    mutating func beganStroke(on maskID: UUID) {
        undone[maskID] = nil
    }

    /// Moves the most recent stroke off the mask and onto the stack.
    @discardableResult
    mutating func undo(_ strokes: inout [BrushStroke], on maskID: UUID) -> Bool {
        guard let stroke = strokes.popLast() else { return false }
        push(stroke, on: maskID)
        return true
    }

    /// Puts the most recently taken-back stroke back on the mask.
    @discardableResult
    mutating func redo(_ strokes: inout [BrushStroke], on maskID: UUID) -> Bool {
        guard var stack = undone[maskID], let stroke = stack.popLast() else { return false }
        undone[maskID] = stack.isEmpty ? nil : stack
        strokes.append(stroke)
        return true
    }

    /// Clearing is undoable too: every stroke goes on the stack, so redo brings
    /// them back one at a time. An accidental clear is otherwise the one action
    /// in the editor that cannot be taken back.
    mutating func clear(_ strokes: inout [BrushStroke], on maskID: UUID) {
        // Pushed newest first, so that popping them off puts the oldest back
        // first and rebuilds the original order. Order is not cosmetic: an
        // erase stroke composites out what was painted before it, so replaying
        // the strokes backwards produces a different mask.
        for stroke in strokes.reversed() {
            push(stroke, on: maskID)
        }
        strokes = []
    }

    /// The mask is gone, so its stack means nothing.
    mutating func forget(_ maskID: UUID) {
        undone[maskID] = nil
    }

    private mutating func push(_ stroke: BrushStroke, on maskID: UUID) {
        var stack = undone[maskID] ?? []
        stack.append(stroke)
        if stack.count > Self.limit {
            // Dropped from the front, which holds the strokes that would come
            // back *last* — the newest ones. What survives is therefore a
            // contiguous run from the start of the painting, so redoing
            // everything gives a real earlier state of the mask. Dropping from
            // the other end would keep late strokes with nothing underneath
            // them, which is not a state the mask was ever in.
            stack.removeFirst(stack.count - Self.limit)
        }
        undone[maskID] = stack
    }
}
