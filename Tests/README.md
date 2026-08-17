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

## Tests that need the real library

`RealLibraryPathTests` asks PhotoKit for actual photographs instead of supplying
its own. They exist because the failures they catch were invisible to every test
that made up its input: an image built from a `CGImage` always agrees with
itself, so disagreements between an image's size and its pixels — which is what
`displaySizeImage` hands over for a photo taken with the camera rotated — could
never appear.

They skip entirely without library access, which makes them close to worthless
on another machine. That is the trade.

One of them writes: `variantCreationSucceeds` makes a real variant and removes
it again, because nothing short of asking PhotoKit catches a request it refuses
outright — `PHPhotosErrorInvalidResource` passed every geometry check ever
written. It is **not unattended**: macOS puts up a confirmation for the deletion
and the run waits on it.

```
TEST_RUNNER_LIGHTTABLE_LIVE_TESTS=1 xcodebuild test \
    -scheme LightTable -destination 'platform=macOS' \
    -only-testing:LightTableTests/RealLibraryPathTests
```

**`TEST_RUNNER_` is not decoration.** `xcodebuild` does not pass its environment
to the test host; that prefix is what crosses the boundary, and the variable
arrives inside stripped of it. Without it the variable is simply absent, and a
test gated on one silently never runs — which is worse than failing, because the
run still says everything passed.
