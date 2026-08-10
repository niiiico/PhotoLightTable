#!/usr/bin/env swift

/// Reports what a RAW file offers for reflection removal.
///
/// The question that decides how much work sky-reflection removal is: does the
/// capture carry an embedded sky matte? `CIRAWFilter` only surfaces the
/// semantic segmentation mattes that are *already in the file* — it does not
/// compute them — so this has to be asked of the actual photo.
///
/// Usage: swift inspect-raw.swift /path/to/IMG_6112.DNG

import CoreImage
import Foundation

guard CommandLine.arguments.count == 2 else {
    print("usage: swift inspect-raw.swift <path to raw file>")
    exit(1)
}

let url = URL(fileURLWithPath: CommandLine.arguments[1])
guard FileManager.default.fileExists(atPath: url.path) else {
    print("No file at \(url.path)")
    exit(1)
}

guard let raw = CIRAWFilter(imageURL: url) else {
    print("\(url.lastPathComponent) is not a RAW file Core Image can open.")
    print("(Reflection subtraction wants the linear RAW path; a JPEG or HEIC")
    print(" cannot be subtracted from correctly.)")
    exit(1)
}

print("File:      \(url.lastPathComponent)")
print("Native:    \(Int(raw.nativeSize.width)) x \(Int(raw.nativeSize.height))")
print("Neutral:   \(Int(raw.neutralTemperature))K, tint \(raw.neutralTint)")
// If the reflection blew the sky out, there may be headroom to pull back.
print("Highlight recovery: \(raw.isHighlightRecoverySupported ? "supported" : "not supported")")
print("")

print("Auxiliary images present in the file")
print("------------------------------------")

let mattes: [(String, CIImage?)] = [
    ("sky", raw.semanticSegmentationSkyMatte),
    ("skin", raw.semanticSegmentationSkinMatte),
    ("hair", raw.semanticSegmentationHairMatte),
    ("glasses", raw.semanticSegmentationGlassesMatte),
    ("teeth", raw.semanticSegmentationTeethMatte),
    ("portrait effects", raw.portraitEffectsMatte),
    ("preview", raw.previewImage),
]

for (name, image) in mattes {
    let label = name.padding(toLength: 18, withPad: " ", startingAt: 0)
    if let image {
        let size = image.extent.size
        print("  \(label)present  (\(Int(size.width)) x \(Int(size.height)))")
    } else {
        print("  \(label)—")
    }
}

print("")
if raw.semanticSegmentationSkyMatte != nil {
    print("The sky matte is here. The mask is free, and the reflection over sky")
    print("can be attacked as: fit a smooth model to the sky, subtract what does")
    print("not fit — in linear space, via CIRAWFilter.linearSpaceFilter.")
} else {
    print("No sky matte in this file, so the mask has to be painted by hand.")
    print("The brush mask in the editor already does that; it is more work but")
    print("the method is unchanged.")
}
