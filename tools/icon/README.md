# App icon

The icon is **drawn, not illustrated** — `make-icon.swift` renders it with Core
Graphics and writes every size the asset catalog asks for.

```
swift tools/icon/make-icon.swift LightTable/Assets.xcassets/AppIcon.appiconset
```

That regenerates the PNGs and `Contents.json` in place. Edit the drawing code
and run it again; there is no source file to keep in sync somewhere else, and a
change to the icon is a change you can read in a diff.

## The design

A backlit panel with three frames laid on it — the thing the app is named
after. The middle frame is darkest and tallest: the one being looked at.

Legibility at 16pt drove it. At that size only two things survive, a bright
rectangle against a dark ground and the dark marks on it, so those carry the
whole icon and everything finer is there for the large sizes only.

## Two treatments

| Platform | Treatment |
| --- | --- |
| iOS | full-bleed square, opaque — the system applies its own mask |
| macOS | inset by 100/1024 with a 185 corner radius, on transparency |

macOS expects the artwork to float in its tile with room for a shadow; iOS
requires the square to be filled. Same drawing, two framings.
