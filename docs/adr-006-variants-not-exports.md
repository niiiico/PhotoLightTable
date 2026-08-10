# ADR 006 — A variant is a real photo from the original pixels, not an export

- **Date:** 2026-08-04
- **Status:** Accepted

## Context

A frame often wants more than one treatment: a black-and-white beside the
colour, a tight crop beside the full frame. Photos has no concept for this — a
duplicate is an unrelated asset.

The user's framing was the design: *"duplicate is kind of git tag operation and
we show the list in edit mode"*. A variant is a **named label on one shared
pixel source**, not a new photograph that happens to look similar.

The obvious implementation — render the treatment and add the result as a new
asset — produces a flattened file. It cannot be re-cropped, re-adjusted, or
reverted. It is the same dead end [ADR 005](adr-005-edits-as-recipes.md)
rejected, arrived at from a different direction.

## Decision

A variant is created by taking the **original pixels** — via
`PhotoEditSession.loadInput`, which yields the untouched original rather than
the current render — adding them as a new asset, and then applying the recipe to
it **as an ordinary edit**.

That costs one extra step and buys everything: the variant is non-destructive
like any other edit, reverts to the original in Photos, and reopens here with
its adjustments live.

Three rules follow:

1. **The source is left as the session found it.** Saving a treatment alongside
   used to leave it applied to the original too, so the next save — or simply
   arrowing to the next photo, which commits — quietly changed the original.
   Leaving the original alone is the entire point of the feature.
2. **Photos sharing a pixel source are a family.** A variant copies its source's
   creation date and location so it sorts into the same day; the grid then emits
   a source with its variants following it, and the editor shows the family as a
   row of named versions. The parent link is followed **to the end, not one
   step**, so a variant of a variant belongs to the family that shares the
   pixels.
3. **Splitting uses the same path.** Left/right halves are two variants, each a
   real photo from the original pixels with a crop applied — so both stay
   re-croppable and revertible. Two scanned pages on one frame become two pages
   without losing the sheet they came from. The halves divide whatever is
   *currently framed*, so splitting after a crop divides what is visible.

## Consequences

- A variant costs a full copy of the original in the library. This is the price
  of it being a real, independently editable photo, and it is why variants are
  an explicit act rather than something the app does on the user's behalf.
- The family relationship lives in this app's store, not in Photos. Photos will
  show the variants as unrelated assets, and the relationship is lost if the
  store is lost — unlike picks and rejects, it has no album to be rebuilt from
  ([ADR 004](adr-004-photos-albums-as-durable-record.md)).
- A variant whose source is filtered out stays where it fell in the grid. Hiding
  it because its parent is hidden would be a second, invisible filter.
- Variant names are suggested from the recipe — "B&W", "Muted", "Warm", "Crop" —
  so a duplicate arrives described rather than as "Copy".
