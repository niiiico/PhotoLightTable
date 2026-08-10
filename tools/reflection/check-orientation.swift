#!/usr/bin/env swift
// Does CIRAWFilter apply the capture's orientation to the auxiliary mattes,
// or only to the main image?
import CoreImage
import Foundation

let url = URL(fileURLWithPath: CommandLine.arguments[1])
guard let raw = CIRAWFilter(imageURL: url) else { exit(1) }
print("raw.orientation = \(raw.orientation.rawValue)  (1 = up, 3 = rotate 180)")
print("native size     = \(raw.nativeSize)")
print("output extent   = \(raw.outputImage?.extent ?? .zero)")
print("matte extent    = \(raw.semanticSegmentationSkyMatte?.extent ?? .zero)")
