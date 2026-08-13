# LightTable

A light table for culling and editing photos in the system Photos library, on
Mac, iPhone and iPad. Keyboard-driven pick/reject and colour labels, browsing by
date or by user-defined events, with picks and rejects mirrored back into real
Photos albums — and a non-destructive editor whose adjustments round-trip
through Photos as parameters rather than as flattened pixels.

No photograph is ever deleted, and nothing is ever flattened. Every edit stays
revertible, in this app and in Photos.app. The one thing the app will remove is
a *version* it made itself, behind a confirmation — never an original.

Requires macOS 15+ or iOS/iPadOS 18+. Open `LightTable.xcodeproj` in Xcode
and run, or build from the command line — see [Layout](#layout) for the
per-platform invocations.

## Keyboard

| Key | Action |
| --- | --- |
| `P` | Pick (again to clear) |
| `X` | Reject (again to clear) |
| `U` | Clear rating |
| `6` `7` `8` `9` `0` | Red / Yellow / Green / Blue / Purple label |
| `R` | Select related photos (again to widen) |
| `S` | Open or stack the focused photo's versions |
| arrows | Move between photos |
| ⇧ + arrows | Extend selection |
| Space / Return | Open or close the loupe |
| ⌘A | Select all |
| Esc | Clear selection |

`P` and `X` advance to the next photo automatically when a single photo is
focused, so culling is a rhythm rather than press-then-arrow.

### In the loupe

| Key | Action |
| --- | --- |
| `E` | Enter the editor; again to commit and leave |
| `C` | Crop, while editing |
| `\` | Before/after comparison, while editing |
| `Z` | Take back the last brush stroke (⇧`Z` puts it back) |
| Esc | Unwind one layer: eyedropper → crop → editor (discarding) → close |

While editing, the digits and the verdict keys belong to the panel's controls
rather than to rating, so `6`–`0` don't fire underneath the editor.

The decisions that shaped all this are recorded as
[ADRs](docs/README.md), and the day-by-day history is in
[CHANGELOG.md](CHANGELOG.md).

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

### Capture badges

A thumbnail carries a small chip saying what it was shot as — a camera or phone
glyph, and RAW or HEIF. Nothing is drawn for a plain JPEG: a badge on every
photo is a badge on none of them.

Read from `PHAssetResource`, which is local metadata Photos already holds, so no
file is opened and no pixels are decoded while scrolling. EXIF would name the
body precisely but means reading from each file, and the answer is only a badge.

The device is therefore a guess from the format. A camera raw is conclusive — no
phone writes a CR2 — and HEIF is Apple's capture format. DNG is the ambiguous
one, since Apple ProRAW writes DNG too, so the filename decides it; anything
still unclear gets no badge rather than a wrong one.

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

## Editing

Adjustments are **one edit session with a single save**, not an Apply between
each operation. You enter the editor, change exposure, drop a gradient, crop,
and it commits once — when you leave, or when you move to another photo. Moving
away commits rather than discards, and that rule holds for every control that
leaves a session, including choosing another version from the strip. Nothing
should be the one button that throws work away.

What is stored is a **recipe**, not a rendered image: a small `Codable` value
holding the tone, the masks and the crop. It is encoded into `PHAdjustmentData`
and round-tripped through Photos, so the edit reopens here as live parameters,
shows up immediately in Photos.app, and can be reverted to the original there.
This is the same non-destructive promise the culling side makes.

| | |
| --- | --- |
| Tone | exposure, contrast, black point, saturation, vibrance, highlights, shadows, warmth, tint, definition, noise reduction |
| Spatial | blur (negative sharpens, positive blurs) |
| Masks | linear gradient, radial gradient, brush |
| Frame | crop, white-balance eyedropper |

Every adjustment is neutral at zero and runs -1…1, apart from exposure in stops
and noise reduction which is unipolar — there is no negative amount of noise to
remove. The UI is generated from the `Adjustment` enum rather than repeating a
slider per parameter, so adding one is a case, not a view.

Masks carry the same `ToneAdjustments` as the whole image, which is why blur
works through a gradient for nothing. A mask's shape glows while you're changing
it, so you can see where it reaches before letting go.

For a brush, that glow follows **what is being judged**. It shows while the
brush is in hand — painting, changing size or softness, switching to erase,
taking a stroke back, or selecting the mask — and gets out of the way the moment
a tonal control is touched, because no exposure or warmth judgement can be made
through a red cast over the picture.

Strokes undo and redo one at a time, from the brush panel or with `Z` and ⇧`Z`.
Clearing goes on the same stack, so an accidental Clear comes back. Order is
preserved rather than reversed: an erase stroke composites out what was painted
before it, so replaying strokes backwards would give a different mask.

Crops are stored **normalized** rather than in pixels, because the same recipe
has to render identically against a display-size preview and a full-resolution
commit. Core Image's origin is bottom-left, so the flip happens once, at the
point of application.

### Recipes decode leniently

Every field of a recipe falls back on its own. A mask written before brushes
existed carries no `strokes` or `softness`; synthesised decoding requires every
key, and `decodeIfPresent` throws on a key that is present but malformed. So one
unparseable mask would take the exposure and the crop down with it — and a photo
whose recipe fails to decode is indistinguishable from one that was never
edited. Losing the masks is bad; losing everything as collateral is much worse.

The session carries a `formatVersion` and a set of readable ones, so old edits
keep opening as parameters after the shape of the recipe changes.

### Copy and paste

Right-click a photo in the grid to copy its adjustments, then paste onto a
selection. The recipe is read from the photo's **actual adjustment data** rather
than from this app's history, so it reflects what the photo currently carries
even if it was reverted or re-edited elsewhere.

### History

Every commit is recorded, so you can revert to any earlier state rather than
undoing one step at a time.

## Variants

A treatment can be saved as **a new photo alongside the original** — a B&W next
to the colour, a tight crop next to the full frame.

The duplicate is built from the **original pixels with the recipe applied as an
ordinary edit**, not written out as a flattened render. That costs one extra
step and buys everything: the variant is non-destructive like any other edit,
reverts to the original in Photos, and reopens here with its adjustments intact.
A flattened export would be a dead end.

Saving alongside also **puts the original back** to how the session found it.
Without that the treatment stayed applied to the source, so the next save — or
simply arrowing to the next photo, which commits — quietly changed the original
too. Leaving the original alone is the entire point of the feature.

### Families

Photos made from the same pixels are kept together. A variant copies its
source's creation date and location so it sorts into the same day. The parent
link is followed **to the end rather than one step**, so a variant of a variant
belongs to the family that shares the pixels rather than to whichever photo it
happened to be made from.

In the grid a family draws as a **stack**: one cell, with two cards peeking out
behind it and a count. A frame is one thing on the table, and its alternative
treatments are that same thing seen another way — spreading them side by side
made a good take look like a long one, and made the day's real shape harder to
read the more you worked.

The count is the control. Click it, press `S`, or use the context menu to open
the family out in place; the same again stacks it back. Nothing is hidden
permanently and nothing is deleted — a closed stack is a way of looking, not a
filter. Open stacks are remembered for the session only.

**Opened out, the family is drawn around** — one light outline enclosing the
whole run, source included, sitting in the grid's spacing gutter rather than
over the photographs. Not a border per cell: the point of a family is that these
are one frame seen several ways, and framing each photo separately says the
opposite.

A run of cells wraps, so the outline is one rectangle **per row** — the shape a
text selection has, a partial row then whole rows then a partial row. A single
enclosing rectangle would swallow every unrelated photo on the rows between.

The rows are recovered by grouping the laid-out cell frames on their `y`, since
the grid does not report what it put where. Those frames are already collected
for drag-selection, so the outline costs no extra measurement. Only cells that
are actually on screen have frames, so a family scrolled half out of view is
drawn around the part that is showing.

`S` acts on the focused cell alone rather than the selection, since opening
every stack in a wide selection would rearrange the grid under the cursor.

Verdicts still apply to what is *selected*, which for a closed stack is the one
photo standing for it. Rejecting a stack does not reject the versions inside it:
a hidden mass edit is worse than an extra keystroke.

A variant whose source is filtered out stays where it fell rather than vanishing
with it — hiding a photo because its parent is hidden would be a second,
invisible filter. Such an orphan is an ordinary cell, not a stack of one.

While editing, the family shows as a row of named versions with the open one
marked. Photos treats a duplicate as an unrelated asset, so without this the
relationship would only be a badge in the grid; it belongs in the editor because
that is where the question arises — what else exists of this frame, and is the
treatment I'm making already one of them.

Names are suggested from the recipe itself, so a duplicate arrives described —
"B&W", "Muted", "Warm", "Cool", "Punchy", "Crop" — rather than as "Copy".

**Duplicate** in the grid's context menu makes a plain copy, joined to the same
family so it stacks with its source. It carries no adjustment, because there is
no editing session open to take one from: it means "another one of these to work
on" rather than "save what I have done".

**Remove This Version…** takes one away again, behind a confirmation. Only ever
a version, never an original.

A copy carries **every resource** the source is made of, not just its main
image — so a duplicated Live Photo is still live, and a RAW beside a JPEG comes
with it. Only the source's own adjustment data is left behind, deliberately: a
variant starts from the original and gets its own recipe.

### Finding lost versions

The family relationship lives only in this app's store — Photos records nothing
about one asset being made from another, and there is no duplicate-detection
API. **Find Lost Versions…** in the menu puts it back if it is ever lost.

It works because a copy made here is the source's file copied verbatim, with
`creationDate` and `location` carried over. Two assets agreeing on the moment,
the filename and the dimensions are not similar photographs — they are the same
photograph twice. Direction comes from `addedDate`: the creation date is copied
and so cannot say which came first, but the date an asset entered the library is
its own.

It does not scan the library. The first pass buckets on creation date, which is
already in memory; only photos that collide with another are asked anything
further. A library of ten thousand photos where nothing was ever duplicated
reads no resources at all.

Families the store already knows about are left alone, since it holds the label
the user chose and this cannot recover that — recovered ones are simply called
"Version".

### Splitting

A photo can be split into left and right halves: two new photos from one, on the
same path as any other variant, each a real photo made from the original pixels
with a crop applied. Both can be re-cropped, adjusted or reverted afterwards; a
pair of flattened exports could do none of that. Two scanned pages on one frame
become two pages without losing the sheet they came from.

The halves divide **whatever is currently framed** rather than the whole file, so
splitting after a crop divides what is actually visible. It is reachable from
the editor on both platforms, where the session's adjustments carry into both
halves, and from the grid's context menu on the Mac, where there is no session
to take a recipe from and the photo is split as it stands.

## On iPhone and iPad

The touch app is **a separate design, not a reflow of the Mac one**. The Mac app
is driven by a hardware keyboard and a pointer; on a phone a verdict is a swipe
and the photo has to stay reachable with a thumb. The use case it was built for
is culling on the couch, sharing the same store over iCloud.

Events run down the side in a `NavigationSplitView`, the grid sits beside them,
and the loupe is a full-screen cover. Culling is a swipe.

The editor is shared: the overlays in `Shared/Editing/` — crop, masks, brush,
zoom, the versions strip — compile for both platforms, so the same code drives
the iPad editor and the Mac one.

Comparison is the exception. The Mac shows before and after side by side; on
touch you **hold the photo to see the original**, which needs no screen space and
no button.

## Reading the state back out of Photos

The LightTable albums are the durable record — they survive this app's store
being lost, moved, or set up fresh on another device. So the app can read the
folder back out of Photos and rebuild events, picks and rejects from it. That is
both the recovery path and how a new install adopts work already done.

This is deliberately a **rebuild from the library rather than a reconciliation
between two peers**. Photos is the real library; this app's store is a projection
of it plus the data PhotoKit cannot hold. Keeping two stores in step as equals
was modelling the relationship wrong, and every mechanism that did so added
state that could itself go stale.

## Current scope

Non-destructive, in both senses. Rejects are marked and collected into the
Rejected album, and emptying it is a manual decision in Photos.

The single exception is removing a **version** — a photo this app made from
another one. That is offered from the grid's context menu, behind a
confirmation, and never for an original. Making a duplicate is cheap, so being
able to unmake one belongs to the same feature; and the photo it was made from
is untouched. It goes to Recently Deleted in Photos, recoverable for thirty
days. See the amendment to [ADR 001](docs/adr-001-ratings-outside-photos.md). Nothing is ever flattened either: edits are stored as
parameters and can be reverted to the original, here or in Photos.app, however
many variants have been made from them.

Rows are only created for rated assets, so the store stays proportional to work
done rather than to library size.

## Layout

One app target with several destinations — macOS 15+, iOS/iPadOS 18+ — rather
than separate targets sharing a framework. A single target keeps the project file
simple, and platform differences are small enough to express in source.

```
LightTable/
  LightTableApp.swift   picks the root view per platform
  Shared/
    Platform.swift           PlatformImage, screen scale, settings URL
    Models/                  Rating, PersistentModels, RatingStore, EventMembership
    Photos/                  PhotoLibraryService, ThumbnailLoader, AlbumSyncer,
                             EventSuggester, PhotoMetadata, PhotoEditing,
                             PhotoVariants, EditClipboard, PhotosImport
    Editing/                 CropOverlay, MaskOverlay, BrushOverlay, LoupeZoom,
                             ComparisonView, WhitePointPicker, VersionsStrip,
                             CropBoundsIndicator
    Views/                   AppModel, LibraryProjection, ThumbnailCell, Tally,
                             FlowLayout, Preferences, BuildStamp
  macOS/                     ContentView, SidebarView, LightTableView, LoupeView,
                             EventEditor, SettingsView, DoubleClickCatcher,
                             entitlements
  iOS/                       TouchRootView, TouchGrid, TouchLoupe, TouchEditor
```

`Shared/Photos/PhotoEditing.swift` and `macOS/LoupeView.swift` are the two large
files (~1200 lines each): the first holds the whole recipe model and the render
and commit paths, the second the loupe and the Mac editor built around it.

`Shared/Editing/` is where the editor's overlays live, and it is the reason the
iPad got a real editor rather than a cut-down one — everything in it draws with
SwiftUI over a photo and works the same under a finger or a pointer.

Everything under `Shared/` compiles for both platforms and contains no AppKit or
UIKit types directly — `PlatformImage` and the `Platform` helpers absorb the
difference. `macOS/` is wrapped in `#if os(macOS)`: those views assume a pointer,
a hardware keyboard and a menu bar, so the touch UI is a separate design rather
than a reflow of them.

Preference *values* (`ThumbnailFillMode`, `PreferenceKey`, `LoupeFields`) are
shared; only the Settings *UI* is macOS-specific, since iOS has no `Settings`
scene.

The Xcode project uses synchronized file groups (Xcode 16+), so new files under
`LightTable/` are picked up without editing `project.pbxproj`.

Build either platform:

```
xcodebuild -scheme LightTable -destination 'platform=macOS' build
xcodebuild -scheme LightTable -destination 'platform=iOS Simulator,name=iPad (A16)' build
```
