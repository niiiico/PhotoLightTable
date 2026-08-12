# ADR 008 — Shipping updates: Sparkle on the Mac, a prompt on iOS, and no sandbox

- **Date:** 2026-08-11
- **Status:** Accepted

## Context

[ota ADR 001](../../ota/docs/adr-001-ota-distribution.md) settles the server:
artifacts in the cluster, a Sparkle appcast for macOS, a `manifest.plist` and an
`itms-services://` link for iOS. This ADR is the half that ships inside the app.

Two things about the app make that less mechanical than it sounds.

The macOS build is **sandboxed** — `com.apple.security.app-sandbox`, plus
file and Photos-library entitlements. Sparkle runs under a sandbox, but only
with both of its XPC services embedded and `temporary-exception.mach-lookup`
entitlements naming them, which is a well-known source of updates that fail
silently in release builds and never in debug.

And the target is one multiplatform target ([ADR 003](adr-003-single-multiplatform-target.md)),
while Sparkle is macOS-only.

## Decision

### The macOS sandbox goes

`com.apple.security.app-sandbox` is removed from the macOS build. Sparkle then
needs nothing beyond an ordinary dependency.

The sandbox was bought for a Mac App Store that this account cannot reach — App
Store Connect refuses to create app records at all ([ADR 003, amended](adr-003-single-multiplatform-target.md#amendment-2026-08-11)).
It is paying a real cost for an option that does not exist.

**Hardened Runtime stays.** It is a different setting, it is what notarization
actually requires, and it is not what complicates Sparkle.

### Sparkle 2 on macOS

Added by SPM as a platform-conditional dependency, used behind `#if os(macOS)`,
configured for automatic checks and automatic install. The Mac updates itself
with no interaction — the transparency the whole exercise is for.

`SUFeedURL` and `SUPublicEDKey` go in the Info.plist. The EdDSA private key
stays in the login keychain on the build machine and is never uploaded; the
release tool signs locally and posts the signature as metadata.

### A prompt on iOS

On launch — and on foreground, debounced — the app fetches `latest.json`,
compares `CFBundleVersion`, and on a newer build offers a sheet whose button
opens the `itms-services://` URL. One tap, then the install replaces the app in
place with its data intact.

The comparison is a plain integer compare, which is sound here because the build
number is the commit count: monotonic, and identical on every machine for the
same commit. `BuildStamp` already reads exactly these keys and can be reused
rather than duplicated.

The check fails silently. Off the LAN and off the VPN the service is
unreachable, and that is the normal case on cellular, not an error worth showing.

## Alternatives considered

**Keep the sandbox and embed Sparkle's XPC services.** Supported and documented.
Rejected because it adds two embedded binaries, three entitlements and a class of
failure that only appears in release builds — all to preserve a boundary whose
only external justification was Mac App Store eligibility.

**Write a small updater instead of taking Sparkle.** Download, verify, swap,
relaunch — each step has an edge case Sparkle has already found. No.

**Share one update mechanism across both platforms.** Sparkle is macOS-only and
iOS cannot install anything itself, so the genuinely shared part is the version
comparison and nothing else. It is kept that small rather than wrapped in an
abstraction pretending the two are the same.

## Consequences

- **Dropping the sandbox is a real reduction in containment**, not a formality.
  The app gains full user-level file access, and a bug that would have been
  contained no longer is. Accepted because it runs only on my own devices from
  artifacts I sign — but it is a downgrade, and worth revisiting if the app is
  ever handed to anyone else.
- Photos access is unaffected. On macOS it is governed by TCC and
  `NSPhotoLibraryUsageDescription`, and the sandbox stops applying without
  taking the entitlement with it — `personal-information.photos-library` is
  read by Hardened Runtime too, which is why it was kept rather than deleted
  with the rest. **Verified 2026-08-12** by running the unsandboxed build; the
  library is reachable.
- Notarization adds a round trip to `notarytool` — a minute or two — to every
  macOS release, and the machine must be online to cut one.
- The release tool must **refuse to publish a dirty tree**. `BuildStamp` marks
  one with a trailing `+`, which would make the build number non-comparable and
  the appcast wrong.
- Sparkle appears in the project file and in the macOS build only, so the
  multiplatform target now has a platform-conditional dependency. ADR 003 stands;
  this is the first thing to test its `#if os(macOS)` convention at the package
  level rather than the source level.
