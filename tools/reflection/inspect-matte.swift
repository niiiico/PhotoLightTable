#!/usr/bin/env swift

/// Dumps the sky matte's geometry and value distribution.
///
/// The reflection prototype reported far less confident sky than the photo
/// appears to contain, so before trusting any result the mask itself has to be
/// looked at: where it sits, and what its values actually are.

import CoreImage
import Foundation

let url = URL(fileURLWithPath: CommandLine.arguments[1])
guard let raw = CIRAWFilter(imageURL: url),
      let image = raw.outputImage,
      let matte = raw.semanticSegmentationSkyMatte else {
    print("Could not read a sky matte from \(url.lastPathComponent)")
    exit(1)
}

print("image extent:  \(image.extent)")
print("matte extent:  \(matte.extent)")
print("")

let width = Int(matte.extent.width)
let height = Int(matte.extent.height)
let context = CIContext(options: [.workingColorSpace: NSNull()])

var pixels = [Float](repeating: 0, count: width * height * 4)
pixels.withUnsafeMutableBytes { buffer in
    context.render(matte,
                   toBitmap: buffer.baseAddress!,
                   rowBytes: width * 16,
                   bounds: matte.extent,
                   format: .RGBAf,
                   colorSpace: nil)
}

// Are all channels the same, or does the coverage live in only one of them?
var channelMax = [Float](repeating: 0, count: 4)
for index in Swift.stride(from: 0, to: pixels.count, by: 4) {
    for channel in 0..<4 {
        channelMax[channel] = max(channelMax[channel], pixels[index + channel])
    }
}
print("per-channel maximum: r \(channelMax[0])  g \(channelMax[1])  b \(channelMax[2])  a \(channelMax[3])")
print("")

var buckets = [Int](repeating: 0, count: 11)
var above: [Float: Int] = [0.01: 0, 0.1: 0, 0.5: 0, 0.9: 0]
let total = width * height

for index in Swift.stride(from: 0, to: pixels.count, by: 4) {
    let value = pixels[index]
    buckets[min(10, max(0, Int(value * 10)))] += 1
    for threshold in above.keys where value > threshold {
        above[threshold]! += 1
    }
}

print("value histogram (red channel)")
for (bucket, count) in buckets.enumerated() {
    let share = Double(count) / Double(total) * 100
    let bar = String(repeating: "#", count: Int(share / 2))
    print(String(format: "  %.1f–%.1f  %5.1f%%  %@",
                 Double(bucket) / 10, Double(bucket + 1) / 10, share, bar))
}

print("")
for threshold in above.keys.sorted() {
    let share = Double(above[threshold]!) / Double(total) * 100
    print(String(format: "  above %.2f: %5.1f%% of the matte", threshold, share))
}
