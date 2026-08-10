# Removing window reflections from sky — findings

- **Date:** 2026-08-09 / 2026-08-10
- **Status:** Working prototype, outside the app. No decision taken on shipping it.
- **Code:** [`tools/reflection/`](../tools/reflection/README.md)
- **Test photo:** `IMG_6112.DNG` — an Air France A220 taking off, shot through an
  airport terminal window, with the terminal's glazing reflected across the sky.

Written so the work can be picked up cold. The results are good — the veil is
largely gone and both aircraft survive intact — but every parameter was tuned
against a single photograph, so nothing here is known to generalise yet.

## The problem, and why this case is tractable

A window sums two images: the scene through the glass, and the scene behind the
camera. One photo, two unknowns per pixel — under-determined, with no correct
answer available in general, only a plausible one.

Two things make *this* class of photo solvable.

**A reflection only ever adds light.**

```
observed = sky + reflection,   reflection >= 0
```

So the true sky is the **lower envelope** of what was recorded, not its average.
This is the load-bearing insight. Blurring the sky to model it fails, because
the blur is dragged upward by the very thing being removed.

**Sky is smooth.** Over sky you know what the clean layer should look like — a
low-frequency gradient — so any sharp structure there is reflection by
definition. Fit a smooth surface to the *low side* of the data and what does not
fit is the reflection. Over foliage or buildings none of this holds.

## Method

1. Decode the RAW with `CIRAWFilter`, highlight recovery on, into
   `extendedLinearSRGB`. **All arithmetic in linear light** — a reflection is a
   sum of photons, so subtracting it is only correct on linear values. Doing it
   on gamma-encoded data gives grey mush.
2. Build a sky mask from the capture's `semanticSegmentationSkyMatte`
   (see the caveats below — this is where most of the difficulty lives).
3. Fit a 2D polynomial (degree 3, 10 coefficients) per channel to the masked
   region, by iteratively reweighted least squares that **downweights positive
   residuals**: a sample brighter than the model is evidence of contamination, a
   darker one is evidence about the sky. Robust scale is taken from the negative
   residuals only, since those are the ones the reflection cannot explain.
4. `reflection = max(0, observed - model)`, per channel — the reflected
   structure has its own colour cast.
5. Subtract, capped (below), weighted by the mask.

The whole thing is **scale-invariant** except at mask edges: the model is
low-frequency, so fitting on a 1600px decode gives essentially the same
coefficients as on the full 4032px one. That is what makes an interactive tool
at preview resolution feasible and honest.

## What the frameworks provide

Verified against the MacOSX27.0 SDK headers, not from memory:

- **No reflection removal anywhere in Core Image.** The only matches for
  "reflection" are in the kaleidoscope filter. No dehaze filter either.
- **No inpainting, healing or clean-up filter.** Grepped for inpaint, heal,
  cleanup, retouch — nothing. Photos.app's own Clean Up is not public API.
- **Vision has no sky segmentation.** Nearest are
  `VNGenerateForegroundInstanceMaskRequest` and `VNDetectHorizonRequest`.
- **`CIRAWFilter.linearSpaceFilter`** — "An optional CIFilter to be applied to
  the RAW image while it is in linear space." This is the correct insertion
  point for the real feature. The prototype instead renders to a linear colour
  space and works on pixels directly, which is easier to inspect.
- **`CIRAWFilter.semanticSegmentationSkyMatte`** — present only if the capture
  embedded it ("auxiliary images that may be present in the file"). Core Image
  does not compute it on demand.
- **Multi-frame separation is reachable in principle**:
  `PHAssetResourceTypePairedVideo` / `FullSizePairedVideo` expose a Live Photo's
  frames, and parallax separates reflection from scene far better than any
  single-image method. Not applicable to this photo — it is a plain RAW — but it
  is the stronger technique if the source is a Live Photo.

## Measured facts about IMG_6112

| | |
| --- | --- |
| Native size | 4032 × 3024 |
| Orientation | **3** (rotated 180 — shot upside down) |
| Sky matte | present, 2016 × 1512 (half resolution) |
| Highlight recovery | supported |
| Neutral | 4467 K, tint 33.5 |

**The sky matte is a soft confidence map, not a mask.** It peaks at 0.843 and
never reaches 1.0. 83.6% of it is above 0.01, 45.8% above 0.10, but only **4.5%
above 0.5**. Thresholding it naively finds almost no sky.

Worse, its confidence is **lowest exactly where the reflection is strongest** —
the reflection is what confuses the segmenter. Any scheme that trusts the matte
more where it is more confident does the opposite of what is wanted.

**Excess over the fitted sky model**, across the masked region, as a fraction of
the model:

| p50 | p90 | p99 | p99.9 | max |
| --- | --- | --- | --- | --- |
| +0.00 | +0.05 | +0.25 | +0.43 | +2.06 |

Half the sky sits exactly on the model, which says the fit is good. The veil
lives between +0.05 and +0.43. The maximum, +2.06, is the aeroplane's sunlit
white wing — three times the sky's brightness. **Reflection and solid objects
separate by roughly 5×**, which is what makes a brightness cap work.

## Bugs found, and why each mattered

These cost the most time. All are fixed in the prototype.

1. **The matte is not oriented.** `outputImage` has the capture's orientation
   applied; the auxiliary mattes do not. With orientation 3 the mask sat 180°
   out — "not sky" over the sky. Fix: `matte.oriented(raw.orientation)`.
   *Why it hid:* a 180° rotation preserves the aspect ratio, so checking that
   matte and image agree on aspect passes happily. Nothing errors; the output is
   just quietly wrong.

2. **The same bug in the crop helper.** `CIImage(contentsOf:)` opens a DNG but
   does not apply its orientation, so a before/after comparison was of two
   regions 180° apart. Use `CIRAWFilter(imageURL:)?.outputImage` for RAW.
   *Twice in one session* — if this becomes a feature, assume every path that
   reads a DNG or a matte needs orientation applied deliberately.

3. **Attenuating the subtraction by matte confidence was backwards.** It removed
   least where the reflection was strongest. Fix: separate the two roles — a
   strict mask decides where to *measure* clean sky, a broad one decides where
   it is sky at all, and how much to remove is the model's job, not the mask's.

4. **The matte's confidence drifts across the frame**, high over the clean left
   and collapsing over the reflected right, so no single threshold means "sky"
   everywhere — the right third of the photo was left untouched. Fix: divide the
   matte by a heavily blurred copy of itself (σ = 200 px) and threshold that
   ratio. What matters is whether a pixel reads as sky *relative to its
   neighbourhood*.

5. **Skyline detection scanned from the wrong end.** Walking down from the sky
   finds the flying aeroplane first — a legitimate hole in the sky — and treats
   everything below it as ground, blanking columns through the middle of the
   frame. Fix: walk *up from the ground edge*. Ground is distinguished from an
   aeroplane by being anchored to the bottom edge.

6. **No brightness cap erased the aeroplane's wing.** The half-resolution matte
   does not cover thin structures, and a sunlit white wing is simply a bright
   thing above the sky model, so it was subtracted away entirely — leaving the
   winglet floating detached. Fix: cap removal at a multiple of the sky level
   (currently the p99.9 excess, +0.43). Peak removal fell from 0.537 to 0.210
   linear and the wing survived.

**Ruled out:** an early hypothesis that the matte was being distorted by colour
management on the way in (0.5 coverage linearizing to ~0.21). Rendering it with
`colorSpace: nil` produced byte-identical results. The low values are real.

## Where it got to

Reflection substantially removed across the whole frame; sky returned to an even
deep blue; both aircraft and the treeline intact. Residual: faint vertical
banding in the left-centre and a soft edge on the top-right panel.

Sampled sky coverage across the fixes, as a measure of how much of the frame the
mask reached: 4% → 25% → 47% → **64%**.

## What is left

**The residual banding is structural, not a tuning problem.** A global
polynomial cannot distinguish a broad flat reflection panel from sky, because
locally it *is* smooth, so the fit partly absorbs it. Raising the degree makes
it worse — the model then bends around the reflection.

The fix is to replace the global polynomial with a **locally adaptive lower
envelope**: a large-radius morphological opening, or a coarse grid of local
minima smoothly interpolated. That follows broad panels without following sharp
edges. This is the main outstanding piece of algorithm work.

Also missing, both small: noise added back after subtraction (corrected sky is
slightly too clean against the rest of the frame), and feathering at the
skyline.

## Open questions

- **The cap is a per-image percentile.** p99.9 assumes obstructions occupy well
  under 0.1% of the sky. True here — one small aeroplane — but a photo with a
  large bright object against sky would push the percentile up and let it be
  subtracted. A fixed multiple of the sky level would be more predictable.
  Needs two or three more photos to choose between them.
- **Does any of this generalise?** Every parameter was tuned against one
  photograph. The case expected to behave worst is a *sharp*, high-contrast
  reflection rather than this soft veil.
- **Non-iPhone RAW has no sky matte at all.** Every parameter above assumes one
  exists. The fallback is a hand-painted mask.

## The likely shape of the feature

Not decided, but the current thinking, for continuity:

- A tuning tool first — a `ReflectionLab` target, macOS only, self-contained:
  drop a RAW, sliders, live preview at reduced resolution, and a view toggle for
  result / mask / removed / before-after. Its purpose is to find out which
  parameters deserve to be user-facing; the expectation is that most become
  constants.
- The shipped control is probably **one slider**, "Reflection 0–100". Polynomial
  degree is not a photo edit, and exposing it makes the photographer do the
  algorithm's job — against the grain of the editor, where adjustments are
  neutral at zero and named the way a photographer would name them.
- **The brush is probably the real answer to the mask.** Every failure above was
  the segmentation being wrong. The editor already has brush masks; letting the
  user paint where the correction should and should not act is less code than
  chasing a better automatic mask, and it degrades gracefully to photos with no
  sky matte at all.
- It fits [ADR 005](adr-005-edits-as-recipes.md) cleanly: one parameter in the
  recipe, an expensive render, still revertible, still round-tripping through
  Photos as parameters.
