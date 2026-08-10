#!/usr/bin/env swift

/// Writes a downscaled preview of a RAW and of its sky matte, for looking at.
///
/// Usage: swift export-preview.swift <input.dng> <output-dir> [long edge]

import CoreImage
import Foundation

let args = CommandLine.arguments
let url = URL(fileURLWithPath: args[1])
let outputDir = URL(fileURLWithPath: args[2])
let longEdge = args.count > 3 ? Double(args[3]) ?? 1400 : 1400

guard let raw = CIRAWFilter(imageURL: url), let image = raw.outputImage else {
    print("Could not decode \(url.lastPathComponent)")
    exit(1)
}

let scale = longEdge / max(image.extent.width, image.extent.height)
let context = CIContext()
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func write(_ image: CIImage, to name: String) throws {
    let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    try context.writeJPEGRepresentation(of: scaled,
                                        to: outputDir.appendingPathComponent(name),
                                        colorSpace: sRGB,
                                        options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.9])
    print("wrote \(name)")
}

try write(image, to: "preview.jpg")

if let matte = raw.semanticSegmentationSkyMatte {
    // Scaled to the image's geometry so the two can be compared directly.
    let aligned = matte.transformed(by: CGAffineTransform(
        scaleX: image.extent.width / matte.extent.width,
        y: image.extent.height / matte.extent.height))
    try write(aligned, to: "matte.jpg")
}
