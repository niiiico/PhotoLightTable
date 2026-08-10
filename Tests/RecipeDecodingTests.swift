import Foundation
import Testing

@testable import PhotoLightTable

/// The recipe is the only thing that survives a round trip through Photos, and
/// a recipe that fails to decode is indistinguishable from a photo that was
/// never edited. These tests pin the leniency down: a recipe written by an
/// older build has to keep opening as parameters, and one bad part must not
/// take the rest with it.
private func decode(_ json: String) throws -> PhotoEditRecipe {
    try JSONDecoder().decode(PhotoEditRecipe.self, from: Data(json.utf8))
}

@Suite("Recipe decoding is lenient")
struct RecipeDecodingTests {
    @Test("An empty object decodes to the neutral recipe")
    func emptyObject() throws {
        let recipe = try decode("{}")

        #expect(recipe.isNeutral)
        #expect(recipe.crop == .full)
        #expect(recipe.masks.isEmpty)
    }

    @Test("The old flat shape decodes into `tone`")
    func flatShapeMigrates() throws {
        // Tonal values used to sit at the top level, before masks needed the
        // same set. Edits made then must still open as parameters.
        let recipe = try decode(#"{"exposure": 0.75, "contrast": -0.25}"#)

        #expect(recipe.tone.exposure == 0.75)
        #expect(recipe.tone.contrast == -0.25)
        #expect(recipe.crop == .full)
    }

    @Test("A malformed mask does not take the tone and crop with it")
    func badMaskIsSurvivable() throws {
        // The failure this guards against: `decodeIfPresent` throws on a key
        // that is present but malformed, so one unparseable mask used to
        // discard the exposure and the crop as collateral.
        let json = #"""
        {
          "tone": {"exposure": 1.5},
          "crop": {"x": 0.1, "y": 0.1, "width": 0.5, "height": 0.5},
          "masks": "not an array at all"
        }
        """#
        let recipe = try decode(json)

        #expect(recipe.tone.exposure == 1.5)
        #expect(recipe.crop.width == 0.5)
        #expect(recipe.masks.isEmpty)
    }

    @Test("A malformed crop falls back to the full frame")
    func badCropIsSurvivable() throws {
        let recipe = try decode(#"{"tone": {"exposure": 0.5}, "crop": 42}"#)

        #expect(recipe.tone.exposure == 0.5)
        #expect(recipe.crop == .full)
    }

    @Test("A mask written before brushes existed decodes with defaults")
    func maskWithoutBrushKeys() throws {
        // No `strokes`, no `softness` — synthesised decoding would reject this.
        let json = #"""
        {"masks": [{"kind": "linear", "isEnabled": true, "isInverted": false}]}
        """#
        let recipe = try decode(json)

        #expect(recipe.masks.count == 1)
        let mask = try #require(recipe.masks.first)
        #expect(mask.kind == .linear)
        #expect(mask.strokes.isEmpty)
        #expect(mask.softness == EditMask.defaultSoftness)
    }

    @Test("A mask missing every optional key still decodes")
    func emptyMask() throws {
        let recipe = try decode(#"{"masks": [{}]}"#)

        #expect(recipe.masks.count == 1)
        #expect(recipe.masks[0].kind == .linear)
        #expect(recipe.masks[0].isEnabled)
    }

    @Test("A partial crop fills its missing sides from the full frame")
    func partialCrop() throws {
        let recipe = try decode(#"{"crop": {"width": 0.5}}"#)

        #expect(recipe.crop.x == 0)
        #expect(recipe.crop.y == 0)
        #expect(recipe.crop.width == 0.5)
        #expect(recipe.crop.height == 1)
    }

    @Test("A brush stroke missing its radius takes the default")
    func partialStroke() throws {
        let json = #"""
        {"masks": [{"kind": "brush", "strokes": [{"points": [{"x": 0.2, "y": 0.3}]}]}]}
        """#
        let recipe = try decode(json)

        let stroke = try #require(recipe.masks.first?.strokes.first)
        #expect(stroke.radius == BrushStroke.defaultRadius)
        #expect(stroke.points == [EditPoint(x: 0.2, y: 0.3)])
        #expect(stroke.isErase == false)
    }
}

@Suite("Recipe round trip")
struct RecipeRoundTripTests {
    @Test("A full recipe survives encode and decode unchanged")
    func roundTrip() throws {
        var recipe = PhotoEditRecipe()
        recipe.tone.exposure = 1.25
        recipe.tone.saturation = -1
        recipe.tone.whitePoint = WhitePoint(red: 0.9, green: 1.0, blue: 1.1)
        recipe.crop = CropRect(x: 0.1, y: 0.2, width: 0.6, height: 0.5)

        var mask = EditMask()
        mask.kind = .radial
        mask.tone.blur = 0.4
        mask.isInverted = true
        recipe.masks = [mask]

        let data = try JSONEncoder().encode(recipe)
        let decoded = try JSONDecoder().decode(PhotoEditRecipe.self, from: data)

        #expect(decoded == recipe)
    }

    @Test("Mask identity survives the round trip")
    func maskIdentityPreserved() throws {
        // Masks are addressed by identity; regenerating ids on decode was the
        // cause of a crash on save.
        var recipe = PhotoEditRecipe()
        recipe.masks = [EditMask(), EditMask()]
        let ids = recipe.masks.map(\.id)

        let data = try JSONEncoder().encode(recipe)
        let decoded = try JSONDecoder().decode(PhotoEditRecipe.self, from: data)

        #expect(decoded.masks.map(\.id) == ids)
    }
}

@Suite("Crop geometry")
struct CropRectTests {
    @Test("The full frame is recognised as full")
    func fullIsFull() {
        #expect(CropRect.full.isFull)
        #expect(!CropRect(x: 0, y: 0, width: 0.5, height: 1).isFull)
    }

    @Test("A crop wider than the frame is clamped to it")
    func oversizeClamped() {
        let crop = CropRect(x: 0, y: 0, width: 2, height: 3).normalized()

        #expect(crop.width == 1)
        #expect(crop.height == 1)
    }

    @Test("A crop is never smaller than a usable sliver")
    func minimumSize() {
        let crop = CropRect(x: 0.5, y: 0.5, width: 0, height: -1).normalized()

        #expect(crop.width == 0.02)
        #expect(crop.height == 0.02)
    }

    @Test("A crop pushed off the edge is pulled back inside")
    func offEdgePulledBack() {
        let crop = CropRect(x: 0.9, y: 0.9, width: 0.5, height: 0.5).normalized()

        #expect(crop.x == 0.5)
        #expect(crop.y == 0.5)
        #expect(crop.x + crop.width <= 1)
        #expect(crop.y + crop.height <= 1)
    }

    @Test("Negative origins are pulled back to zero")
    func negativeOrigin() {
        let crop = CropRect(x: -0.3, y: -0.2, width: 0.4, height: 0.4).normalized()

        #expect(crop.x == 0)
        #expect(crop.y == 0)
    }
}

@Suite("Variant labels")
struct VariantLabelTests {
    @Test("A desaturated treatment is named B&W")
    func blackAndWhite() {
        var recipe = PhotoEditRecipe()
        recipe.tone.saturation = -1

        #expect(recipe.suggestedVariantLabel == "B&W")
    }

    @Test("Warmth and coolness are told apart")
    func temperature() {
        var warm = PhotoEditRecipe()
        warm.tone.warmth = 0.5
        var cool = PhotoEditRecipe()
        cool.tone.warmth = -0.5

        #expect(warm.suggestedVariantLabel == "Warm")
        #expect(cool.suggestedVariantLabel == "Cool")
    }

    @Test("A crop with no tonal change is named for the crop")
    func cropOnly() {
        var recipe = PhotoEditRecipe()
        recipe.crop = CropRect(x: 0, y: 0, width: 0.5, height: 0.5)

        #expect(recipe.suggestedVariantLabel == "Crop")
    }

    @Test("Something unremarkable still gets a name rather than none")
    func fallback() {
        #expect(PhotoEditRecipe().suggestedVariantLabel == "Variant")
    }
}

@Suite("Adjustment definitions")
struct AdjustmentTests {
    @Test("Every adjustment is neutral at zero")
    func neutralAtZero() {
        var tone = ToneAdjustments()
        for adjustment in Adjustment.allCases {
            tone[adjustment] = 0
        }

        #expect(tone.isNeutral)
    }

    @Test("Setting any single adjustment leaves neutral")
    func anyAdjustmentCounts() {
        for adjustment in Adjustment.allCases {
            var tone = ToneAdjustments()
            tone[adjustment] = 0.5

            #expect(!tone.isNeutral, "\(adjustment.label) did not register")
        }
    }

    @Test("Zero sits inside every range")
    func zeroInRange() {
        for adjustment in Adjustment.allCases {
            #expect(adjustment.range.contains(0), "\(adjustment.label) excludes neutral")
        }
    }

    @Test("Noise reduction is the only unipolar adjustment")
    func noiseReductionIsUnipolar() {
        // There is no negative amount of noise to remove.
        #expect(Adjustment.noiseReduction.isUnipolar)
        #expect(Adjustment.noiseReduction.range.lowerBound == 0)
        for adjustment in Adjustment.allCases where adjustment != .noiseReduction {
            #expect(!adjustment.isUnipolar, "\(adjustment.label) is unexpectedly unipolar")
        }
    }

    @Test("Exposure is the only adjustment measured in stops")
    func exposureFormatting() {
        #expect(Adjustment.exposure.formatted(1.5) == "+1.50 EV")
        #expect(Adjustment.contrast.formatted(0.5) == "+50")
        #expect(Adjustment.noiseReduction.formatted(0.5) == "50")
    }

    @Test("A neutral tone summarises as no adjustments")
    func neutralSummary() {
        #expect(PhotoEditRecipe().summary == "No adjustments")
    }

    @Test("The summary counts only masks that carry something")
    func summaryCountsActiveMasks() {
        var recipe = PhotoEditRecipe()
        var carrying = EditMask()
        carrying.tone.exposure = 0.5
        let empty = EditMask()
        var disabled = EditMask()
        disabled.tone.exposure = 0.5
        disabled.isEnabled = false
        recipe.masks = [carrying, empty, disabled]

        #expect(recipe.summary == "1 mask")
    }
}
