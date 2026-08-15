import CoreGraphics
import Foundation
import Testing

@testable import LightTable

/// Does a `size` rectangle, centred and axis-aligned, fit inside a `width` by
/// `height` rectangle rotated about its centre by `radians`?
///
/// Checked by rotating the candidate's corners *back* and asking whether they
/// land inside the original — the same question from the other end, and one
/// that does not reuse the formula being tested.
private func fitsInside(_ size: CGSize,
                        width: CGFloat,
                        height: CGFloat,
                        radians: CGFloat,
                        slack: CGFloat = 0.001) -> Bool {
    let corners = [CGPoint(x: -size.width / 2, y: -size.height / 2),
                   CGPoint(x: size.width / 2, y: -size.height / 2),
                   CGPoint(x: size.width / 2, y: size.height / 2),
                   CGPoint(x: -size.width / 2, y: size.height / 2)]

    let unrotate = CGAffineTransform(rotationAngle: -radians)
    return corners.allSatisfy { corner in
        let p = corner.applying(unrotate)
        return abs(p.x) <= width / 2 + slack && abs(p.y) <= height / 2 + slack
    }
}

@Suite("Fitting a straightened photo back into its frame")
struct StraightenTests {
    @Test("No tilt takes nothing away")
    func zeroAngle() {
        let size = PhotoEditRecipe.largestInteriorSize(width: 3000, height: 2000, radians: 0)

        #expect(size.width == 3000)
        #expect(size.height == 2000)
    }

    @Test("The result actually fits inside the rotated photo")
    func itFits() {
        // The property that matters: anything larger would put transparent
        // wedges into the picture.
        for degrees in stride(from: 0.5, through: 15, by: 0.5) {
            let radians = CGFloat(degrees) * .pi / 180
            let size = PhotoEditRecipe.largestInteriorSize(width: 3000, height: 2000,
                                                           radians: radians)
            #expect(fitsInside(size, width: 3000, height: 2000, radians: radians),
                    "\(degrees)° produced \(size), which overflows")
        }
    }

    @Test("It fits for tall photos too")
    func itFitsPortrait() {
        for degrees in stride(from: 0.5, through: 15, by: 0.5) {
            let radians = CGFloat(degrees) * .pi / 180
            let size = PhotoEditRecipe.largestInteriorSize(width: 2000, height: 3000,
                                                           radians: radians)
            #expect(fitsInside(size, width: 2000, height: 3000, radians: radians),
                    "\(degrees)° produced \(size), which overflows")
        }
    }

    @Test("The photo keeps its proportions")
    func aspectIsPreserved() {
        // A straighten that quietly turned a 3:2 into something else would be a
        // crop nobody asked for.
        let original = 3000.0 / 2000
        for degrees in stride(from: 1.0, through: 15, by: 1) {
            let size = PhotoEditRecipe.largestInteriorSize(width: 3000, height: 2000,
                                                           radians: CGFloat(degrees) * .pi / 180)
            #expect(abs(size.width / size.height - original) < 0.001,
                    "\(degrees)° changed the shape")
        }
    }

    @Test("Tilting further costs more of the frame")
    func largerAngleTakesMore() {
        var previous = CGFloat.greatestFiniteMagnitude
        for degrees in stride(from: 0.0, through: 15, by: 1) {
            let size = PhotoEditRecipe.largestInteriorSize(width: 3000, height: 2000,
                                                           radians: CGFloat(degrees) * .pi / 180)
            #expect(size.width < previous)
            previous = size.width
        }
    }

    @Test("Tilting either way costs the same")
    func symmetric() {
        let left = PhotoEditRecipe.largestInteriorSize(width: 3000, height: 2000,
                                                       radians: -7 * .pi / 180)
        let right = PhotoEditRecipe.largestInteriorSize(width: 3000, height: 2000,
                                                        radians: 7 * .pi / 180)

        #expect(abs(left.width - right.width) < 0.001)
        #expect(abs(left.height - right.height) < 0.001)
    }

    @Test("A square photo is handled, where the general solution degenerates")
    func square() {
        // width == height makes the usual formula divide by something that
        // goes to zero at 45°; the short-side branch has to catch it.
        for degrees in stride(from: 1.0, through: 15, by: 1) {
            let radians = CGFloat(degrees) * .pi / 180
            let size = PhotoEditRecipe.largestInteriorSize(width: 2000, height: 2000,
                                                           radians: radians)
            #expect(size.width > 0)
            #expect(fitsInside(size, width: 2000, height: 2000, radians: radians))
        }
    }

    @Test("It takes back as much as it can, not merely something that fits")
    func isNotOverlyCautious() {
        // A formula returning half the frame would pass "it fits" happily. At
        // 5° on a 3:2 photo there should still be most of the picture left.
        let size = PhotoEditRecipe.largestInteriorSize(width: 3000, height: 2000,
                                                       radians: 5 * .pi / 180)

        #expect(size.width > 3000 * 0.85)
    }

    @Test("A degenerate frame does not crash or return nonsense")
    func zeroSized() {
        #expect(PhotoEditRecipe.largestInteriorSize(width: 0, height: 0, radians: 0.1) == .zero)
    }

    @Test("Straighten survives a round trip, and defaults to none when absent")
    func recipeCarriesIt() {
        var recipe = PhotoEditRecipe()
        recipe.straighten = -3.5

        let data = try! JSONEncoder().encode(recipe)
        let decoded = try! JSONDecoder().decode(PhotoEditRecipe.self, from: data)
        #expect(decoded.straighten == -3.5)

        // A recipe written before straighten existed opens level, not tilted.
        let old = try! JSONDecoder().decode(PhotoEditRecipe.self,
                                            from: Data(#"{"tone":{"exposure":1}}"#.utf8))
        #expect(old.straighten == 0)
        #expect(old.tone.exposure == 1)
    }
}
