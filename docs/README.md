# Architecture Decision Records

Decisions that shaped the app and would be expensive to revisit — why the data
sits where it does, why edits take the form they take. Written after the fact,
from the commit history and the conversations that produced them, so the dates
are the dates of the decision rather than of the writing.

Routine choices are not here; the code comments carry those, and the
[README](../README.md) carries the product behaviour.

| | Decision | Date |
| --- | --- | --- |
| [001](adr-001-ratings-outside-photos.md) | Picks, rejects and colour labels live outside Photos | 2026-07-28 |
| [002](adr-002-events-as-app-concept.md) | Events are a concept this app owns | 2026-07-28 |
| [003](adr-003-single-multiplatform-target.md) | One target for Mac, iPhone and iPad | 2026-07-28 |
| [004](adr-004-photos-albums-as-durable-record.md) | The Photos albums are the durable record; rebuild rather than reconcile | 2026-07-30 |
| [005](adr-005-edits-as-recipes.md) | Edits are recipes round-tripped through Photos, committed once per session | 2026-08-02 |
| [006](adr-006-variants-not-exports.md) | A variant is a real photo from the original pixels, not an export | 2026-08-04 |
| [007](adr-007-product-name-and-bundle-identity.md) | The app is called LightTable | 2026-08-11 |
| [008](adr-008-shipping-updates.md) | Shipping updates: Sparkle on the Mac, a prompt on iOS, and no sandbox | 2026-08-11 |

## Notes

Investigations that have not produced a decision yet, kept because the findings
were expensive to obtain.

| | Subject | Date |
| --- | --- | --- |
| [reflection-removal](reflection-removal.md) | Removing window reflections from sky — method, measurements, and the six bugs found getting there | 2026-08-10 |

## The thread running through them

001, 004, 005 and 006 are the same commitment applied to four different
problems: **the library is the source of truth, and nothing this app does may
destroy what is in it.** No photo is deleted, no edit is flattened, no original
is quietly modified. Where PhotoKit cannot hold what the app needs, the app
holds it and mirrors what it can — and where the two disagree, the library wins.

Two of these were established by reading the Photos framework headers in the
macOS 26.5 SDK rather than by assumption, after a design built on creating smart
albums programmatically turned out to rest on an API that does not exist. That
SDK is an `.Internal.sdk`, so SPI is visible alongside public API; the
annotation is what matters, not whether the symbol is there.

007 and 008 come from outside that thread — they are about getting builds onto
devices rather than about the library — but 007 leans on 004 all the same. The
rename discards the app's local store, and the only reason that is affordable is
that the Photos albums can rebuild it.

The distribution decision itself lives with the service, in
[ota ADR 001](../../ota/docs/adr-001-ota-distribution.md), because it covers
every app built here rather than this one.
