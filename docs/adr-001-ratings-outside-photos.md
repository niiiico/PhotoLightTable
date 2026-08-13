# ADR 001 — Picks, rejects and colour labels live outside Photos

- **Date:** 2026-07-28
- **Status:** Accepted

## Context

The app's core act is rating a photo: pick it, reject it, or put a colour on it.
The obvious home for that is the Photos library itself, so the verdicts travel
with the photos and survive this app.

They cannot go there. Checked against the Photos framework headers in the macOS
26.5 SDK rather than assumed, an app can toggle `isFavorite`, edit creation date
and location, create and populate albums, and request deletion. It cannot write
keywords, titles, captions or star ratings — those exist in the Photos database
with no public write API. There is no field in Photos that means "rejected", and
none that means "green".

`isFavorite` is the single writable flag, and it is already the user's own
favourite marker. Overloading it would destroy information the user cares about.

## Decision

Verdicts live in this app's SwiftData store, keyed by `PHAsset.localIdentifier`,
and are **mirrored outward** into ordinary Photos albums — `LightTable ▸ Picked`
and `LightTable ▸ Rejected` — which is the one form of writing PhotoKit does
allow.

Rows are only created for rated assets, so the store stays proportional to work
done rather than to library size.

Album writes are debounced (~2s) rather than synchronous. A verdict is a
keypress and culling is a rhythm; a `PHPhotoLibrary.performChanges` per keypress
would stall the UI and hammer iCloud sync.

## Consequences

- The app owns state that Photos cannot represent, so the store is not optional
  — losing it loses the rejects and the labels, not merely a cache. This is what
  makes [ADR 004](adr-004-photos-albums-as-durable-record.md) necessary.
- `localIdentifier` is the join key between the two worlds, so anything that
  invalidates it (a library rebuild, a migration) orphans ratings.
- Picks and rejects are visible and usable outside this app, in Photos on any
  device, because they are real albums. Colour labels are not — they have no
  album, and remain internal.
- Nothing is deleted. A reject is a mark and a membership; emptying the Rejected
  album stays a deliberate act in Photos.

## Amendment, 2026-08-13 — one narrow exception

"Nothing is deleted" now has a single exception: **a variant may be removed from
the library, from the grid's context menu.** An original never can.

The rule was about photographs. A photograph is evidence of a moment that
happened once, and no convenience justifies an app destroying one. A variant is
not that — it is a copy this app made a minute ago
([ADR 006](adr-006-variants-not-exports.md)), the photo it came from is still
there, and the pixels it was built from are not lost with it. Making one is
cheap, so the ability to unmake one is part of the same feature; without it a
misjudged Duplicate is permanent.

The narrowness is the point, and it is enforced rather than merely intended:
removal is offered only where `RatingStore.isVariant` holds, and
`PhotoVariants.remove` refuses anything else even if called directly. What makes
a photo removable is that this app has a record saying it created it.

Two further safeguards, neither of which is the app's own doing:

- PhotoKit's `deleteAssets` moves an asset to **Recently Deleted**, so it can be
  brought back in Photos for thirty days. Nothing here erases anything.
- macOS puts its own confirmation in front of the deletion, on top of the app's.

The bookkeeping is ordered so a refused or cancelled deletion leaves nothing
behind: the variant record is dropped only *after* the asset is gone. A variant
made from the removed one is re-pointed at its grandparent rather than orphaned,
since what defines a family is the shared pixels, not the intermediate step.
