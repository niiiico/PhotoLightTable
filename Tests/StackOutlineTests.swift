import CoreGraphics
import Foundation
import Testing

@testable import LightTable

/// A cell on a 100-wide grid with 10 of spacing, at column `x`, row `y`.
private func cell(_ x: Int, _ y: Int) -> CGRect {
    CGRect(x: CGFloat(x) * 110, y: CGFloat(y) * 110, width: 100, height: 100)
}

@Suite("Outlining a family across the grid")
struct StackOutlineTests {
    @Test("A family on one row is one rectangle enclosing all of it")
    func singleRow() {
        let segments = StackOutline.segments(for: [cell(0, 0), cell(1, 0), cell(2, 0)])

        #expect(segments.count == 1)
        #expect(segments[0] == CGRect(x: 0, y: 0, width: 320, height: 100))
    }

    @Test("A family that wraps is one rectangle per row, not one big box")
    func wrapping() {
        // A single union rectangle would swallow every unrelated photo on the
        // rows between, which is the whole reason this splits by row.
        let segments = StackOutline.segments(for: [cell(2, 0), cell(3, 0), cell(0, 1)])

        #expect(segments.count == 2)
        #expect(segments[0] == CGRect(x: 220, y: 0, width: 210, height: 100))
        #expect(segments[1] == CGRect(x: 0, y: 110, width: 100, height: 100))
    }

    @Test("Rows come out top to bottom whatever order they went in")
    func rowsAreOrdered() {
        let segments = StackOutline.segments(for: [cell(0, 2), cell(0, 0), cell(0, 1)])

        #expect(segments.map(\.minY) == [0, 110, 220])
    }

    @Test("A single photo gives its own frame")
    func single() {
        #expect(StackOutline.segments(for: [cell(1, 1)]) == [cell(1, 1)])
    }

    @Test("Nothing showing means nothing drawn")
    func empty() {
        #expect(StackOutline.segments(for: []).isEmpty)
    }

    @Test("Cells a hair out of alignment still count as one row")
    func rowTolerance() {
        // Laid-out frames are floating point and rarely exactly equal; grouping
        // on strict equality would split a row into slivers.
        let nudged = CGRect(x: 110, y: 0.4, width: 100, height: 100)
        let segments = StackOutline.segments(for: [cell(0, 0), nudged])

        #expect(segments.count == 1)
    }

    @Test("A family spanning three rows keeps the middle row whole")
    func threeRows() {
        let frames = [cell(3, 0),
                      cell(0, 1), cell(1, 1), cell(2, 1), cell(3, 1),
                      cell(0, 2)]
        let segments = StackOutline.segments(for: frames)

        #expect(segments.count == 3)
        #expect(segments[1] == CGRect(x: 0, y: 110, width: 430, height: 100))
    }
}
