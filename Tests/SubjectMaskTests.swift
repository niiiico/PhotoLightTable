import CoreGraphics
import CoreImage
import Foundation
import Testing

@testable import LightTable

/// A grey square with a white disc in the middle, as a stand-in for a stored
/// selection. Small enough to write inline, real enough to encode and decode.
private func region(side: Int = 64, discRadius: CGFloat = 20) -> MaskRegion {
    let context = CGContext(data: nil, width: side, height: side,
                            bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceGray(),
                            bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    context.setFillColor(gray: 0, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: side, height: side))
    context.setFillColor(gray: 1, alpha: 1)
    let centre = CGFloat(side) / 2
    context.fillEllipse(in: CGRect(x: centre - discRadius, y: centre - discRadius,
                                   width: discRadius * 2, height: discRadius * 2))

    let image = CIImage(cgImage: context.makeImage()!)
    let data = CIContext().pngRepresentation(of: image, format: .L8,
                                             colorSpace: CGColorSpaceCreateDeviceGray())!
    return MaskRegion(png: data)
}

@Suite("Storing a subject selection")
struct SubjectMaskTests {
    @Test("A region survives the round trip through a recipe")
    func roundTrip() {
        var mask = EditMask()
        mask.kind = .brush
        mask.region = region()

        var recipe = PhotoEditRecipe()
        recipe.masks = [mask]

        let data = try! JSONEncoder().encode(recipe)
        let decoded = try! JSONDecoder().decode(PhotoEditRecipe.self, from: data)

        #expect(decoded.masks.first?.region == mask.region)
        #expect(decoded.masks.first?.region?.decoded() != nil)
    }

    @Test("A stored selection is small enough to live in the recipe")
    func staysSmall() {
        // It rides in PHAdjustmentData, which is in the Photos database — a
        // mask that has to be stored has to be worth its space.
        let recipe = { () -> PhotoEditRecipe in
            var mask = EditMask()
            mask.kind = .brush
            mask.region = region(side: 512, discRadius: 160)
            var recipe = PhotoEditRecipe()
            recipe.masks = [mask]
            return recipe
        }()

        let encoded = try! JSONEncoder().encode(recipe)
        #expect(encoded.count < 32_768, "recipe grew to \(encoded.count) bytes")
    }

    @Test("A recipe written before regions existed still opens")
    func olderRecipesStillOpen() {
        let json = #"{"masks":[{"kind":"brush","strokes":[]}],"tone":{"exposure":0.5}}"#
        let recipe = try! JSONDecoder().decode(PhotoEditRecipe.self, from: Data(json.utf8))

        #expect(recipe.masks.count == 1)
        #expect(recipe.masks[0].region == nil)
        #expect(recipe.tone.exposure == 0.5)
    }

    @Test("A malformed region does not take the rest of the mask with it")
    func badRegionIsSurvivable() {
        // The same leniency every other part of a recipe has: losing the
        // selection is bad, losing the strokes and the tone alongside it is
        // worse.
        let json = #"""
        {"masks":[{"kind":"brush","region":"not a region","softness":0.4}]}
        """#
        let recipe = try! JSONDecoder().decode(PhotoEditRecipe.self, from: Data(json.utf8))

        #expect(recipe.masks.count == 1)
        #expect(recipe.masks[0].region == nil)
        #expect(recipe.masks[0].softness == 0.4)
    }

    @Test("A mask holding only a selection is not empty")
    func regionCountsAsContent() {
        // `isEmpty` decides whether a mask is rendered at all. A subject
        // selection with nothing painted over it is the ordinary case, and
        // treating it as empty would make the whole feature do nothing.
        var mask = EditMask()
        mask.kind = .brush
        mask.region = region()

        #expect(!mask.isEmpty)

        // A brush with nothing in it at all. A default mask is a gradient, and
        // a gradient is never empty — it always describes something.
        var bare = EditMask()
        bare.kind = .brush
        #expect(bare.isEmpty)
    }

    @Test("The selection is what gets rendered, in the right place")
    func rendersWhereTheSelectionIs() {
        var mask = EditMask()
        mask.kind = .brush
        mask.softness = 0
        mask.region = region(side: 64, discRadius: 16)

        let extent = CGRect(x: 0, y: 0, width: 200, height: 200)
        let rendered = mask.maskImage(for: extent)
        #expect(rendered != nil)

        let context = CIContext()
        func gray(at point: CGPoint) -> UInt8 {
            var pixel = [UInt8](repeating: 0, count: 4)
            context.render(rendered!, toBitmap: &pixel, rowBytes: 4,
                           bounds: CGRect(x: point.x, y: point.y, width: 1, height: 1),
                           format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
            return pixel[0]
        }

        #expect(gray(at: CGPoint(x: 100, y: 100)) > 200, "the middle should be selected")
        #expect(gray(at: CGPoint(x: 5, y: 5)) < 55, "the corner should not be")
    }

    @Test("Inverting a selection selects everything else")
    func inverted() {
        var mask = EditMask()
        mask.kind = .brush
        mask.softness = 0
        mask.region = region(side: 64, discRadius: 16)
        mask.isInverted = true

        let extent = CGRect(x: 0, y: 0, width: 200, height: 200)
        let context = CIContext()
        func gray(at point: CGPoint) -> UInt8 {
            var pixel = [UInt8](repeating: 0, count: 4)
            context.render(mask.maskImage(for: extent)!, toBitmap: &pixel, rowBytes: 4,
                           bounds: CGRect(x: point.x, y: point.y, width: 1, height: 1),
                           format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
            return pixel[0]
        }

        #expect(gray(at: CGPoint(x: 100, y: 100)) < 55, "the subject should now be out")
        #expect(gray(at: CGPoint(x: 5, y: 5)) > 200, "and the background in")
    }

    @Test("An erase stroke takes a bite out of the selection")
    func strokesEditTheSelection() {
        // The point of storing it as part of a brush mask: what the model chose
        // is a starting point, not the last word.
        var mask = EditMask()
        mask.kind = .brush
        mask.softness = 0
        mask.region = region(side: 64, discRadius: 24)

        var erase = BrushStroke()
        erase.isErase = true
        erase.radius = 0.12
        erase.points = [EditPoint(x: 0.5, y: 0.5)]
        mask.strokes = [erase]

        let extent = CGRect(x: 0, y: 0, width: 200, height: 200)
        var pixel = [UInt8](repeating: 0, count: 4)
        CIContext().render(mask.maskImage(for: extent)!, toBitmap: &pixel, rowBytes: 4,
                           bounds: CGRect(x: 100, y: 100, width: 1, height: 1),
                           format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())

        #expect(pixel[0] < 55, "the erased middle should be out of the mask")
    }
}
