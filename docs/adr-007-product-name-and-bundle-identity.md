# ADR 007 — The app is called LightTable

- **Date:** 2026-08-11
- **Status:** Accepted

## Context

Ad Hoc distribution needs an explicit registered App ID; the wildcard team
provisioning profile the iOS build rides today cannot export one. The bundle
identifier has to change ([ota ADR 001](../../ota/docs/adr-001-ota-distribution.md),
and the [amendment to ADR 003](adr-003-single-multiplatform-target.md#amendment-2026-08-11)).

Changing it after the first over-the-air release would orphan the installed app
and its store, so this is the last cheap moment to also settle what the app is
called — and it currently answers to three names at once:

| Where | Name |
|---|---|
| Product, scheme, repository | `PhotoLightTable` |
| Bundle identifier | `PhotosLightTable` (not reverse-DNS) |
| Test bundle | `PhotosLightTableTests` |
| Model and view types | `LightTableEvent`, `LightTableView` |
| Info.plist keys | `LTBuildLabel`, `LTBuildCommit` |
| Strings shown to the user | "No LightTable albums were found in Photos." |
| **Albums in the Photos library** | **`LightTable ▸ Picked`, `LightTable ▸ Rejected`** |

## Decision

The app is **LightTable**. Bundle identifier `net.dev2.lighttable`, tests
`net.dev2.lighttable.tests`, matching `net.dev2.healthsync`.

This is less a rename than dropping two spellings that were never used
internally. Every type, every Info.plist key and every string the user reads
already says LightTable. The `Photo` prefix survives only on the product name,
the repository, the app file and one `NSLog`.

The tie-breaker is [ADR 004](adr-004-photos-albums-as-durable-record.md). The
durable record is the LightTable folder in Photos — it outlives the app's own
store and is visible on every device, in Photos.app, whether or not this app is
installed. That folder is the app's most permanent public surface, and it has
been called LightTable since the beginning. The product should agree with it.

`PhotosLightTable` is rejected on two counts: it leans on the name of Apple's
first-party app, and it would still not match the albums — it fixes the
inconsistency by adding a fourth spelling.

The album names do not change. That is the point of choosing this one.

## Consequences

- **The bundle identifier change discards local state.** `UserDefaults.standard`
  is keyed by bundle identifier, and the SwiftData store lives under
  `Application Support/<bundle-id>/`. Both start empty under the new identity.
- **ADR 004 is what makes that survivable, and this is its first real test.**
  Picks, rejects and events rebuild from the LightTable folder in Photos through
  the ordinary adoption path — the same code a fresh install runs, not a
  migration written for this.
- **Colour labels are lost, and cannot be recovered.** ADR 001 and ADR 004 both
  record that they have no album to be rebuilt from; this is the asymmetry those
  ADRs accepted, arriving. At version 0.1 the practical loss is small, but it is
  real and irreversible, so the rename should be done deliberately — after
  checking whether any labels are worth a one-off export first.
- `AlbumSyncer`'s stored album `localIdentifier`s reset and re-resolve by name on
  first run. Harmless, and already the code path for a fresh install.
- The `PhotoLightTable` → `LightTable` rename reaches the repository directory
  and its remote, `PhotoLightTable.xcodeproj`, the scheme, the target, the
  source folder, `PhotoLightTableApp.swift`, one `NSLog` string, and the README,
  CHANGELOG and docs. It does not reach any type name.
- This must land **before** the first over-the-air release, not after.
