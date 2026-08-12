# Changelog

Newest first. One line per day of work, occasionally more when a day covered
several major features.

2026-08-12 - Wire Sparkle for silent macOS updates and drop the App Sandbox, keeping Hardened Runtime and the Photos entitlement that Hardened Runtime also reads. A macOS-only package turned out not to trouble the single multiplatform target: platformFilters on the build file means iOS resolves Sparkle and simply does not link it.

2026-08-11 - Design over-the-air distribution to my own devices, and record it: ADR 007 renames the app to LightTable and moves it to `net.dev2.lighttable`, ADR 008 drops the macOS sandbox for Sparkle and adds an update prompt on iOS, and ADR 003 is amended — the account blocks App Store Connect, not provisioning, so Ad Hoc distribution was available all along.

2026-08-10 - Undo and redo brush strokes one at a time, and make Clear reversible; show the red mask wash only while the brush is in hand, so the tonal sliders can be judged against the photo rather than through a colour cast.

2026-08-10 - Prototype removing a window reflection from sky: fit a smooth lower envelope to the sky in linear light and subtract what does not fit, using the capture's own sky matte. Works on IMG_6112; findings and the six bugs found getting there are written up in docs/reflection-removal.md.

2026-08-09 - Add a test target: 44 tests over the edit recipe's decoding and the event clustering rules, with `EventSuggester` made generic over what grouping actually reads so it can be tested without a photo library.

2026-08-09 - Write up the project: this changelog reconstructed from the history, the README brought up to date with the editor, variants and iOS, and six ADRs for the decisions behind them.

2026-08-07 - Split a photo into left and right halves, each a real photo made from the original pixels with a crop applied, so both stay re-croppable and revertible.

2026-08-04 - Save an edit as a new photo alongside the original, group photos sharing a pixel source into a family in the grid, and list that family as a versions strip in the editor; a variant no longer leaves its treatment applied to the photo it came from.

2026-08-04 - Replace before/after on touch with holding the photo to see the original.

2026-08-03 - Bring the app to iPhone and iPad: sidebar, grid and swipe culling, then the editor itself by sharing its overlays with macOS.

2026-08-03 - Add black point, definition, noise reduction and a white-balance eyedropper; show where a mask reaches while its shape is being changed; double-click a slider to reset it.

2026-08-03 - Apply orientation once on the RAW path, and stamp a build number in the corner derived from the commit count, so it is monotonic across machines.

2026-08-02 - Build the editor: exposure round-tripped through Photos, then crop, a tonal stack, gradient masks, brush masks and blur — all one edit session saved once, rather than an Apply between each operation.

2026-08-02 - Add a version history to revert to any earlier state, copy and paste adjustments across a selection, and a before/after comparison; fix a crash saving masks and the findings from an independent review.

2026-07-31 - Stop publishing state from inside a view update.

2026-07-30 - Make album sync two-way, then rebuild events and ratings from the Photos albums directly.

2026-07-30 - Loupe: zoom, two-finger pan, editable metadata slots and nothing over the photo; add a light/dark appearance setting.

2026-07-30 - Drag to select in the grid, extend or toggle with Command, and memoise the library projections so selection keeps up.

2026-07-29 - Scope automatic signing to macOS, so iOS builds need no App ID.

2026-07-28 - First version: keyboard-driven culling of the macOS Photos library — pick/reject, colour labels, browsing by date or by hand-defined event, mirrored into LightTable albums.

2026-07-28 - Move the counts into the toolbar and drop the status bar; restructure as a multiplatform target ahead of the iOS port.
