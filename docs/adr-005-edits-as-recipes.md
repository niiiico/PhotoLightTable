# ADR 005 — Edits are recipes round-tripped through Photos, committed once per session

- **Date:** 2026-08-02
- **Status:** Accepted

## Context

The app grew an editor: exposure first, then crop, a tonal stack, gradient and
brush masks, blur. Two questions had to be answered before any of it.

**What gets written back?** The easy answer is a rendered image — apply the
filters, hand Photos the pixels. It is also a dead end: the edit becomes
unopenable, unadjustable, and irreversible, which contradicts the founding
promise that this app does not destroy anything.

**When does it get written?** The first version put an Apply button between each
operation. Every change was a separate commit through PhotoKit, which meant a
crop and an exposure change were two edits to the same photo, each with its own
round trip, and the grid flickered between them.

## Decision

**An edit is a recipe**: a small `Codable` value holding the tonal adjustments,
the masks and the crop — no image data. It is encoded into `PHAdjustmentData`
and round-tripped through Photos, so the edit reopens here as live parameters,
appears immediately in Photos.app, and can be reverted to the original there.

**An edit is one session with a single save.** Entering the editor starts it;
leaving commits it, whether by closing or by moving to another photo. Moving
away commits rather than discards, and that rule holds for *every* control that
leaves a session — including choosing another version from the strip. No control
should be the one that silently throws work away.

Supporting choices that follow from the recipe being a value:

- **Crops are normalized**, not in pixels, because the same recipe must render
  identically against a display-size preview and a full-resolution commit. Core
  Image's origin is bottom-left, so the flip happens once, at application.
- **Masks carry the same `ToneAdjustments` as the whole image**, so a mask gets
  every adjustment — blur included — for nothing.
- **Decoding is lenient, field by field.** A recipe carries a `formatVersion`
  and each part falls back on its own. `decodeIfPresent` throws on a key that is
  present but malformed, so without this one unparseable mask discards the
  exposure and the crop as collateral — and a photo whose recipe fails to decode
  is indistinguishable from one that was never edited.
- **Masks are addressed by identity**, and identity survives the round trip.
  Regenerating ids on decode was the cause of a crash on save.

## Consequences

- Edits survive in both directions: Photos.app shows them and can revert them;
  this app reopens them as parameters.
- The recipe's shape is a compatibility surface. Changing it means extending the
  lenient decoder and the readable-version set, not just adding a field. This is
  the most fragile part of the app and the most heavily tested — see
  `Tests/RecipeDecodingTests.swift`.
- Rendering happens twice: at preview size while editing, at full size on
  commit. Any adjustment expressed in pixels rather than fractions will disagree
  between the two.
- Copy/paste of adjustments is nearly free, since a recipe is a value. It reads
  the source photo's *actual* adjustment data rather than this app's history, so
  it reflects what the photo carries now.
- Because the recipe is separable from the pixels it was made for, it can be
  applied to a *copy* of the original — which is what
  [ADR 006](adr-006-variants-not-exports.md) is built on.
