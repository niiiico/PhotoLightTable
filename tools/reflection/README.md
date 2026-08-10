# Reflection removal prototype

Command-line tools for removing a window reflection from the sky region of a RAW
photo. **Not part of the app** — this is exploratory work, run by hand.

The findings, the method and the reasoning are in
[`docs/reflection-removal.md`](../../docs/reflection-removal.md). Read that
first; this file only covers how to run things.

Everything here is a standalone `swift` script — no target, no build step.

## Doing the thing

```
swift reflection-fix.swift <input.dng> <output.tiff> [strength] [degree]
```

- `strength` — how much of the detected reflection to remove, 0…1 (default 1)
- `degree` — polynomial degree of the sky model (default 3)

Requires the capture to carry a `semanticSegmentationSkyMatte`, which in
practice means an iPhone RAW. It writes three diagnostics beside the output,
and they are the reason the bugs in the findings document were found rather
than guessed at — look at them before believing any result:

| File | What it shows |
| --- | --- |
| `<out>.mask.jpg` | where the correction was allowed to act |
| `<out>.removed.jpg` | how much was actually removed (exaggerated ×4) |
| `<out>.model.jpg` | the fitted sky, which should be a clean smooth gradient |

It also prints the excess-over-model distribution, which is what the brightness
cap is derived from.

## Looking first

```
swift inspect-raw.swift <input.dng>
```

Reports size, orientation, highlight-recovery support, and which auxiliary
mattes the file carries. **Run this first on any new photo** — if there is no
sky matte, the main script cannot run as written.

```
swift inspect-matte.swift <input.dng>
```

Geometry and value histogram of the sky matte. Worth running on any photo that
behaves oddly: the matte is a soft confidence map, not a binary mask, and its
levels vary from capture to capture.

```
swift check-orientation.swift <input.dng>
```

Prints `raw.orientation` and the image/matte extents. Small, but orientation
mismatches between the image and its matte caused two separate bugs.

## Looking at results

```
swift export-preview.swift <input.dng> <output-dir> [long edge]
```

Writes `preview.jpg` and `matte.jpg`, downscaled and aligned to the same
geometry, for comparing the photo against its mask.

```
swift crop.swift <in> <out.jpg> <x> <yTop> <w> <h> [zoom]
```

Crops a region given in **top-left** pixel coordinates from either a RAW or a
rendered file, for checking detail at 1:1. Reflection artefacts hide at
full-frame preview size — the erased aeroplane wing was invisible until this was
used.

## A warning

`CIImage(contentsOf:)` opens a DNG but does **not** apply its orientation, and
`CIRAWFilter`'s auxiliary mattes are not oriented either while its `outputImage`
is. Both caused silently wrong output. Any new code here that reads a RAW or a
matte should apply the orientation deliberately.
