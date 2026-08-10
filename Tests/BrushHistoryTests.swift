import Foundation
import Testing

@testable import PhotoLightTable

private func stroke(_ x: Double) -> BrushStroke {
    var stroke = BrushStroke()
    stroke.points = [EditPoint(x: x, y: x)]
    return stroke
}

@Suite("Taking brush strokes back")
struct BrushHistoryTests {
    private let mask = UUID()

    @Test("Undo removes the last stroke and offers it back")
    func undoRemovesLast() {
        var history = BrushHistory()
        var strokes = [stroke(0.1), stroke(0.2)]
        let last = strokes[1].id

        #expect(history.undo(&strokes, on: mask))
        #expect(strokes.map(\.id) == [strokes[0].id])
        #expect(history.canRedo(mask))

        #expect(history.redo(&strokes, on: mask))
        #expect(strokes.count == 2)
        #expect(strokes[1].id == last)
    }

    @Test("Strokes come back in the order they were taken")
    func lastInFirstOut() {
        var history = BrushHistory()
        var strokes = [stroke(0.1), stroke(0.2), stroke(0.3)]
        let ids = strokes.map(\.id)

        history.undo(&strokes, on: mask)
        history.undo(&strokes, on: mask)
        #expect(strokes.map(\.id) == [ids[0]])

        history.redo(&strokes, on: mask)
        #expect(strokes.map(\.id) == [ids[0], ids[1]])
        history.redo(&strokes, on: mask)
        #expect(strokes.map(\.id) == ids)
    }

    @Test("Undoing nothing reports that it did nothing")
    func undoOnEmpty() {
        var history = BrushHistory()
        var strokes: [BrushStroke] = []

        #expect(!history.undo(&strokes, on: mask))
        #expect(!history.canRedo(mask))
    }

    @Test("Redo with nothing taken back does nothing")
    func redoWithEmptyStack() {
        var history = BrushHistory()
        var strokes = [stroke(0.1)]

        #expect(!history.redo(&strokes, on: mask))
        #expect(strokes.count == 1)
    }

    @Test("Painting again makes the taken-back strokes unreachable")
    func newStrokeClearsRedo() {
        var history = BrushHistory()
        var strokes = [stroke(0.1)]

        history.undo(&strokes, on: mask)
        #expect(history.canRedo(mask))

        history.beganStroke(on: mask)
        #expect(!history.canRedo(mask))
    }

    @Test("Clearing is undoable, one stroke at a time")
    func clearIsRecoverable() {
        // The one action in the editor that used to be unrecoverable.
        var history = BrushHistory()
        var strokes = [stroke(0.1), stroke(0.2), stroke(0.3)]
        let ids = strokes.map(\.id)

        history.clear(&strokes, on: mask)
        #expect(strokes.isEmpty)
        #expect(history.canRedo(mask))

        history.redo(&strokes, on: mask)
        history.redo(&strokes, on: mask)
        history.redo(&strokes, on: mask)
        #expect(strokes.map(\.id) == ids)
        #expect(!history.canRedo(mask))
    }

    @Test("Each mask has its own history")
    func perMask() {
        var history = BrushHistory()
        let other = UUID()
        var mine = [stroke(0.1)]
        var theirs = [stroke(0.2)]

        history.undo(&mine, on: mask)

        #expect(history.canRedo(mask))
        #expect(!history.canRedo(other))
        #expect(!history.redo(&theirs, on: other))
        #expect(theirs.count == 1)
    }

    @Test("Forgetting a mask drops what it had taken back")
    func forget() {
        var history = BrushHistory()
        var strokes = [stroke(0.1)]

        history.undo(&strokes, on: mask)
        history.forget(mask)

        #expect(!history.canRedo(mask))
    }

    @Test("Past the limit, what survives is a real earlier state of the mask")
    func bounded() {
        var history = BrushHistory()
        let painted = (0..<(BrushHistory.limit + 10)).map { stroke(Double($0) / 100) }
        var strokes = painted

        while history.undo(&strokes, on: mask) {}
        #expect(strokes.isEmpty)

        var restored: [BrushStroke] = []
        while history.redo(&restored, on: mask) {}

        // A contiguous run from the beginning, in the order it was painted —
        // not the newest strokes with nothing underneath them, which is not a
        // state the mask was ever in.
        #expect(restored.count == BrushHistory.limit)
        #expect(restored.map(\.id) == painted.prefix(BrushHistory.limit).map(\.id))
    }
}
