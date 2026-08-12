# Tests

Unit tests for the parts of the app that are decidable without a photo library.

```
xcodebuild test -scheme LightTable -destination 'platform=macOS'
```

Written with [Swift Testing](https://developer.apple.com/documentation/testing)
(`@Suite` / `@Test` / `#expect`), not XCTest.

## What is covered, and why these parts

Most of this app is a conversation with PhotoKit, and PhotoKit needs a real
library with real photos in it — there is no way to construct a `PHAsset` with a
chosen creation date, so anything reached only through one is out of scope here.
What is left is small but load-bearing, and it is where the bugs actually were.

**`RecipeDecodingTests.swift`** — the edit recipe is the only thing that
survives a round trip through Photos, and a recipe that fails to decode is
indistinguishable from a photo that was never edited. The tests pin down the
leniency that protects against that: the old flat shape still migrating into
`tone`, a malformed mask not taking the exposure and the crop down with it, and
masks written before brushes existed still opening. Two of these correspond to
bugs that were actually shipped and fixed — the crash from regenerated mask
identities, and the recipe lost wholesale to one unparseable part.

Also here: crop clamping, the variant naming rules, and the invariants the
adjustment UI is generated from — every adjustment neutral at zero, zero inside
every range, noise reduction the only unipolar one.

**`EventSuggesterTests.swift`** — the grouping rules behind `R` in the grid: the
gap ladder, that the gap is measured photo-to-photo rather than from the start
of a group, that a long jump in location splits a group the clock would have
kept, and that location is only consulted when both photos have a fix. Also
that `next` walks the ladder once and stops, since pressing `R` repeatedly
relies on it terminating.

## `TemporalPhoto`

`EventSuggester` is generic over `TemporalPhoto` — id, creation date, location —
rather than taking `PhotoItem` directly. That is what makes the grouping rules
reachable from a test: `FakePhoto` conforms to it with dates chosen by the test,
which is impossible with a real `PHAsset`. `PhotoItem` conforms, so no call site
changed.

If you add logic that deserves a test and it is stuck behind PhotoKit, the same
move usually works: name the handful of fields the logic actually reads, and
take those.
