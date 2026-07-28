# Photo Light Table

A macOS light table for culling photos out of the system Photos library.
Keyboard-driven pick/reject and colour labels, browsing by date or by
user-defined events, with picks and rejects mirrored back into real Photos albums.

Requires macOS 15+. Build with `xcodebuild -scheme PhotoLightTable build`, or open
`PhotoLightTable.xcodeproj` in Xcode and run.

## Keyboard

| Key | Action |
| --- | --- |
| `P` | Pick (again to clear) |
| `X` | Reject (again to clear) |
| `U` | Clear rating |
| `6` `7` `8` `9` `0` | Red / Yellow / Green / Blue / Purple label |
| `R` | Select related photos (again to widen) |
| arrows | Move between photos |
| ⇧ + arrows | Extend selection |
| Space / Return | Open or close the loupe |
| ⌘A | Select all |
| Esc | Clear selection |

`P` and `X` advance to the next photo automatically when a single photo is
focused, so culling is a rhythm rather than press-then-arrow.

## Why the architecture looks like this

Three PhotoKit constraints shaped the whole design. They were verified against
the Photos framework headers in the macOS 26.5 SDK, not assumed.

**PhotoKit can barely write.** An app can toggle `isFavorite`, edit creation
date and location, create and populate albums, and request deletion. It cannot
write keywords, titles, captions, or star ratings — those exist in the Photos
database with no public write API. So there is nowhere in Photos to record
"rejected" or "colour label". Those live in this app's SwiftData store, keyed by
`PHAsset.localIdentifier`.

**Smart albums cannot be created programmatically.** The only two creation
requests in the framework are
`PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle:)`
(a regular album) and
`PHCollectionListChangeRequest.creationRequestForCollectionList(withTitle:)`
(a folder). `PHAssetCollectionTypeSmartAlbum` is fetch-only. Smart albums can
only be made by hand in Photos.app via File ▸ New Smart Album. This is why the
per-event filtering lives in this app's sidebar instead of being materialised as
one smart album per event.

**Moments are gone.** iPhoto Events became Moments, and in the current SDK
`PHAssetCollectionTypeMoment` is marked SPI on macOS and deprecated elsewhere.
The Days/Months/Years grouping Photos shows is backed by `PhotosHighlight`
collections, also SPI. Neither is usable in a shippable app. So the plain date
view groups by calendar day from `creationDate`, and *events* are a first-class
concept this app owns: a name over a date range, with pinned and excluded assets
for the stragglers.

### Finding related photos

Events are defined by hand, but you rarely want to hunt for the boundaries.
`EventSuggester` splits photos into runs of temporally adjacent shots, starting a
new run when consecutive photos are further apart than a threshold. Four
granularities are offered rather than one guessed value, because the right answer
depends entirely on what was shot:

| | Gap | For |
| --- | --- | --- |
| Session | 2h | a ceremony, a golden hour |
| Outing | 8h | a day out, a single shoot |
| Day | 20h | breaks overnight |
| Trip | 48h | whole holidays, tolerating quiet days |

Location is a secondary splitter: photos more than 60km apart start a new group
even when they're close in time, so a flight or a long drive breaks the run. It
is only consulted when both photos have a GPS fix.

Press `R` in the grid to grow the selection to the focused photo's group;
pressing it again widens one step (session → outing → day → trip), so you can
feel out the right boundary visually. The context menu offers the granularities
directly. Creating an event from a selection opens the editor already grown to
the matching group, with a live count and date range as you change granularity.

"Limit the event to exactly these photos" then writes the difference into the
event's `excludedAssetIDs` — anything inside the date range that isn't in the
group — and pins group members that fall outside the range. That's what keeps two
unrelated shoots in the same week from bleeding into each other.

### Event albums in Photos

Everything the app creates lives under one top-level `LightTable` folder, so it
stays clear of your own albums:

```
📁 LightTable
   ├── LightTable — Picked      every pick, across all events
   ├── LightTable — Rejected
   └── 📁 Geneve
        ├── Geneve              all photos in the event
        └── Geneve — Picked     the picks
```

Off by default, per event — turn it on in the event editor or from the sidebar's
right-click menu. Synced events show a folder badge in the sidebar.

### Adoption is deliberately narrow

When no stored identifier exists yet, the syncer will adopt an existing
collection by name rather than create a duplicate. That search is scoped:

- **Event folders and albums** are only ever matched *inside* the LightTable
  folder. A library-wide match would let an event named "Geneve" adopt your own
  Geneve album and then prune every photo in it that isn't in the event —
  reconciliation removes as well as adds.
- **The two global albums** may adopt library-wide, since they carry distinctive
  names and may still be at the top level from before the folder existed.
  `ensure(_:isChildOf:)` then moves them in. Photos allows one parent per
  collection, so adding to a folder *is* a move.

The upshot: a folder you made by hand is never touched, and the app builds its
own alongside it.

These are regular albums, not smart albums, because no API creates smart albums
(see above). Functionally it makes no difference: the app reconciles membership
whenever ratings or event membership change, so the Picked album tracks your
culling the same way a smart album would.

Created folder and album identifiers are stored on the event
(`photosFolderID`, `photosAlbumID`, `photosPickedAlbumID`). That's what makes
renaming an event rename its folder in Photos instead of orphaning it and
creating a second one. If no identifier is stored yet, the syncer adopts an
existing folder or album of the same name rather than making a duplicate beside
it — so pointing an event at a folder you already made by hand works.

### Writes are debounced, not synchronous

Every album mutation is a `performChanges` transaction that fires change
notifications and queues an iCloud sync — roughly 10–100ms each. A light table
takes several judgements per second, so writing on each keypress would feel
sticky and would hammer iCloud.

`RatingStore` therefore writes to an in-memory dictionary first (the grid reads
ratings during layout without touching SwiftData), then to the SwiftData store,
and only arms a 2-second timer on `AlbumSyncer`. When the user pauses, the syncer
reconciles the difference into `LightTable — Picked` and `LightTable — Rejected`,
adding and removing only what changed so unrelated edits made in Photos survive.
Sync can be turned off entirely, or forced with ⌘⇧S.

## Events

An event holds photos one of two ways.

**Fixed membership** (`explicitMembership == true`) means the event contains
exactly `pinnedAssetIDs` and nothing else; the date range is only a label. This
is what you get from *New Event from Selection…* — the selection is taken
literally. Nothing imported later drifts in, and no exclusion list has to be
maintained.

**Date-range membership** resolves in this order:

1. in `pinnedAssetIDs` → in, whatever the date says
2. in `excludedAssetIDs` → out, whatever the date says
3. otherwise, in if the creation date falls inside the range

This is what you get when creating an event with nothing selected, or by turning
off "Fix the event to exactly these photos". Use it when the event should keep
absorbing photos as they arrive.

`LightTableEvent.contains(assetID:date:)` implements both, but filtering a whole
library goes through `AppModel.scope`, which lifts the pinned and excluded arrays
into sets first — otherwise each photo rescans them.

So there are three ways to add photos to an event:

- **Widen the range.** Right-click the event ▸ Edit and move the dates. Anything
  shot in the new span joins automatically.
- **Add explicitly.** Select photos anywhere (including under All Photos),
  right-click ▸ Add to Event ▸ *name*. This pins them, so they belong even
  though their date falls outside — the shot from the evening before the trip.
  The same menu offers *New Event from Selection…*, so it works before any
  events exist.
- **At creation.** Select one photo, press `R` to grow to the group, then create
  the event from that selection.

Removing works the same way: right-click ▸ Remove from *name* while browsing an
event. That both unpins and excludes, because a photo can be a member purely by
falling inside the range — unpinning alone wouldn't shift it.

## The tally

Everything describing the current scope — one event, or the whole library if none
is selected — lives in the toolbar. There is no status bar: two horizontal
strips of controls competed for the same attention.

The toolbar's leading group is a single `ToolbarItem`, so overflow can't split it
apart or reorder it:

```
120 photos   ●●   |   ⚑ 12   ✕ 5   ○ 103
   count   colours     picked rejected unrated
```

The count's tooltip gives "68% reviewed", meaning `(picked + rejected) / total`.
The colour control shows active labels as dots rather than a generic icon, so the
filter is readable without opening the menu.

Each of the three counts is a button that filters to it; clicking the active one
clears the filter. They are the *only* control for that filter — a segmented
picker used to duplicate them, which meant two controls over one piece of state.

Counts are computed **before** filtering. Computing them after would make them
describe the filter rather than the work: filter to Picked and you'd see
"12 picked, 0 rejected, 0 unrated", which answers nothing.

The window title names the scope, so nothing repeats it. Its subtitle appears
only when a filter is active — "Showing 12 of 120", the one count nothing else
carries.

Counts are computed **before** filtering. Computing them after would make them
describe the filter rather than the work: filter to Picked and you'd see
"12 picked, 0 rejected, 0 unrated", which answers nothing.

Each count is a button that filters to it, and clicking the active one clears the
filter — seeing "12 picked" and wanting to look at those twelve is the same
thought.

## Sorting

Order follows the scope, because the two read differently: an event is a story
and runs **oldest first**, the whole library is a feed and runs **newest first**.
The toolbar's sort menu overrides it, and the override is dropped when you switch
scope — so a manual choice on one event doesn't leak into the next.

`AppModel.sort` is a reverse, not a re-sort. `PhotoLibraryService` fetches sorted
by creation date descending and both `scope` and `filter` preserve order, so the
input is always newest-first already. Keeping that invariant makes ordering O(n)
per redraw rather than O(n log n), which is the difference between a smooth and a
stuttering thumbnail-size slider on a large library. If a future change ever
reorders items upstream, this has to become a real sort.

## Preferences

⌘, opens Settings.

**Appearance.** Thumbnails can be **square crop** (even grid, edges of the frame
lost) or **whole frame** (letterboxed on black, ragged grid, but you judge the
real composition). The fill mode is part of the thumbnail cache key, so switching
re-renders rather than serving stale crops.

**Loupe.** Which EXIF fields the info bar shows. Defaults are date, camera, lens,
focal length, aperture, shutter and ISO; also available are exposure
compensation, pixel dimensions, megapixels, file name and file size.

Values are formatted the way they're printed on a lens barrel — "ƒ/2.8",
"1/250 s", "35 mm (52 mm eq.)" — rather than labelled, because a row of captions
would crowd out the photo. Hovering a value names the field. A field the photo
doesn't carry is skipped rather than shown empty, so enabling everything costs
nothing on files without EXIF.

Metadata comes from the original file via `CGImageSource`, which parses headers
lazily and never decodes pixels. Results are cached per asset. The 35mm
equivalent is only appended when it actually differs from the true focal length.

## Current scope

Non-destructive: nothing is ever deleted from the library. Rejects are marked and
collected into the Rejected album; emptying it is a manual decision in Photos.

Rows are only created for rated assets, so the store stays proportional to work
done rather than to library size.

## Layout

One app target with several destinations — macOS 15+, iOS/iPadOS 18+ — rather
than separate targets sharing a framework. A single target keeps the project file
simple, and platform differences are small enough to express in source.

```
PhotoLightTable/
  PhotoLightTableApp.swift   picks the root view per platform
  Shared/
    Platform.swift           PlatformImage, screen scale, settings URL
    Models/                  Rating, PersistentModels, RatingStore, EventMembership
    Photos/                  PhotoLibraryService, ThumbnailLoader, AlbumSyncer,
                             EventSuggester, PhotoMetadata
    Views/                   AppModel, ThumbnailCell, Tally, FlowLayout, Preferences
  macOS/                     ContentView, SidebarView, LightTableView, LoupeView,
                             EventEditor, SettingsView, entitlements
  iOS/                       TouchRootView
```

Everything under `Shared/` compiles for both platforms and contains no AppKit or
UIKit types directly — `PlatformImage` and the `Platform` helpers absorb the
difference. `macOS/` is wrapped in `#if os(macOS)`: those views assume a pointer,
a hardware keyboard and a menu bar, so the touch UI is a separate design rather
than a reflow of them.

Preference *values* (`ThumbnailFillMode`, `PreferenceKey`, `LoupeFields`) are
shared; only the Settings *UI* is macOS-specific, since iOS has no `Settings`
scene.

The Xcode project uses synchronized file groups (Xcode 16+), so new files under
`PhotoLightTable/` are picked up without editing `project.pbxproj`.

Build either platform:

```
xcodebuild -scheme PhotoLightTable -destination 'platform=macOS' build
xcodebuild -scheme PhotoLightTable -destination 'platform=iOS Simulator,name=iPad (A16)' build
```
