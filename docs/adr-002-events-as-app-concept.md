# ADR 002 — Events are a concept this app owns

- **Date:** 2026-07-28
- **Status:** Accepted

## Context

Culling is organised around *an event* — "Corsica, 3–14 August" — not around a
scroll through everything. Three ways to get that from Photos were considered,
and two are unavailable.

**Smart albums cannot be created programmatically.** The only two creation
requests in the framework are
`PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle:)`
(a regular album) and
`PHCollectionListChangeRequest.creationRequestForCollectionList(withTitle:)`
(a folder). `PHAssetCollectionTypeSmartAlbum` is fetch-only. So "one smart album
per event, combining event ∩ picked" — the first design proposed — is not
buildable; those can only be made by hand in Photos.app.

**Moments are gone.** iPhoto Events became Moments, and in the current SDK
`PHAssetCollectionTypeMoment` is SPI on macOS and deprecated elsewhere. The
Days/Months/Years grouping Photos shows is backed by `PhotosHighlight`
collections, also SPI. The local SDK is an `.Internal.sdk`, so these symbols are
visible — but SPI is unusable in a shippable app, and the annotation is what
matters, not the symbol's existence.

There was also a product question underneath the technical one: should the app
cluster the library into events automatically on first run? No. An event is a
real-world thing a person names, and a machine guessing at the boundaries of
someone's holiday produces confident nonsense.

## Decision

An event is a first-class object in this app: a **name over a date range**, with
pinned and excluded assets for the stragglers that the range gets wrong. Events
start empty and are created by hand.

Clustering exists, but only as **assistance on request**: `EventSuggester`
splits photos into runs of temporally adjacent shots at four granularities
(session 2h, outing 8h, day 20h, trip 48h), with location as a secondary
splitter beyond 60km. Pressing `R` grows the selection to the focused photo's
group; pressing it again widens one step.

Four granularities are offered rather than one tuned value because the right
answer depends entirely on what was shot — a reception is one *outing*, a
fortnight away is one *trip*.

## Consequences

- Event filtering happens in this app's sidebar, and cannot be materialised as
  smart albums the way the first design assumed.
- Because events are ours, they need mirroring into Photos to be durable —
  a folder per event, which is what [ADR 004](adr-004-photos-albums-as-durable-record.md)
  builds on.
- Grouping by day in the plain date view is computed from `creationDate`, not
  read from Photos, so it will not always agree with what Photos.app shows.
- The suggester is advisory. It never writes an event; it only proposes a
  selection, which the user accepts by creating one.
