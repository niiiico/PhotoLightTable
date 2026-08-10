# ADR 003 — One target for Mac, iPhone and iPad

- **Date:** 2026-07-28
- **Status:** Accepted

## Context

The Mac app came first. Touch culling on the couch — the same library, the same
verdicts, on an iPad — was wanted almost immediately, with an iPhone version
after it.

The usual structuring is separate app targets sharing a framework. That buys
enforced boundaries: shared code physically cannot reach AppKit, because the
framework does not link it.

It also costs a framework target, an embed phase, access-control noise on every
shared type, and a project file that has to be edited by hand for each of them.

## Decision

**One app target with several destinations** — macOS 15+, iOS/iPadOS 18+ — and
platform differences expressed in source.

```
Shared/     compiles everywhere, no AppKit or UIKit types
macOS/      wrapped in #if os(macOS)
iOS/        wrapped in #if !os(macOS)
```

`PlatformImage` and the helpers in `Platform.swift` absorb the type differences.
Preference *values* are shared; only the Settings *UI* is macOS-specific, since
iOS has no `Settings` scene.

The project uses **synchronized file groups** (Xcode 16+), so new files under
`PhotoLightTable/` are picked up without touching `project.pbxproj`.

Signing is scoped to macOS: `CODE_SIGN_ENTITLEMENTS[sdk=macosx*]`. The Apple
account cannot create an iOS app record — App Store Connect refuses with
`PLATFORM_NOT_ALLOWED_DUE_TO_CONTRACT_STATE` — so the iOS build must work
without a registered App ID.

## Consequences

- The `Shared/` boundary is a **convention, not a compiler guarantee**. Nothing
  stops someone importing AppKit there; only review catches it.
- The touch UI is a separate design rather than a reflow — the Mac views assume
  a pointer, a hardware keyboard and a menu bar. This is a deliberate product
  call as much as a technical one, and it is why `iOS/` is written fresh rather
  than shared with `macOS/`.
- The editor's overlays sit in `Shared/Editing/` precisely because they *are*
  shareable: they draw with SwiftUI over a photo and work the same under a
  finger or a pointer. That is what let the iPad have the real editor rather
  than a reduced one.
- iOS distribution is blocked at the account level, not the code level. Nothing
  needing a provisioning profile — TestFlight, App Store — can be attempted
  until that changes.
- Adding a test target still required editing `project.pbxproj` by hand;
  synchronized groups remove the per-file work, not the per-target work.
