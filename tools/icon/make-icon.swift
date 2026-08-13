#!/usr/bin/env swift

/// Draws the app icon and writes every size the asset catalog asks for.
///
/// The icon is the thing the app is named after: a backlit panel with a few
/// frames laid on it. Everything is drawn rather than illustrated so it can be
/// regenerated, adjusted and diffed — an icon that only exists as a PNG is a
/// file nobody can change.
///
/// Legibility at 16pt drove the design. At that size only two things survive: a
/// bright rectangle against a dark ground, and the dark marks on it. Detail
/// finer than that is drawn for the large sizes and simply disappears on the
/// small ones, which is the right way round.
///
/// Usage: swift make-icon.swift <output-directory>

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.count > 1
                          ? CommandLine.arguments[1]
                          : FileManager.default.currentDirectoryPath)

// MARK: - Drawing

/// Everything is expressed against a 1024 canvas and scaled, so one drawing
/// serves every size.
let canvas: CGFloat = 1024

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

func roundedPath(_ rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

/// - Parameter inset: how far the artwork sits inside the canvas. macOS icons
///   float in their tile with room for a shadow; iOS fills the square and lets
///   the system mask it.
func draw(in context: CGContext, size: CGFloat, inset: CGFloat, cornerRadius: CGFloat) {
    let scale = size / canvas
    context.scaleBy(x: scale, y: scale)

    let plate = CGRect(x: inset, y: inset, width: canvas - inset * 2, height: canvas - inset * 2)
    let space = CGColorSpaceCreateDeviceRGB()

    // The ground: near black, warmer at the bottom so the panel above it reads
    // as lit rather than as a flat white shape.
    context.saveGState()
    context.addPath(roundedPath(plate, radius: cornerRadius))
    context.clip()
    if let ground = CGGradient(colorsSpace: space,
                               colors: [color(30, 36, 46), color(8, 10, 14)] as CFArray,
                               locations: [0, 1]) {
        context.drawLinearGradient(ground,
                                   start: CGPoint(x: 0, y: plate.maxY),
                                   end: CGPoint(x: 0, y: plate.minY),
                                   options: [])
    }

    // The light itself, thrown upward from the panel. Drawn before the panel so
    // the panel sits in its own glow rather than on top of it.
    let panel = plate.insetBy(dx: plate.width * 0.10, dy: plate.height * 0.17)
    if let glow = CGGradient(colorsSpace: space,
                             colors: [color(255, 244, 214, 0.75),
                                      color(255, 244, 214, 0)] as CFArray,
                             locations: [0, 1]) {
        context.drawRadialGradient(glow,
                                   startCenter: CGPoint(x: panel.midX, y: panel.midY),
                                   startRadius: 0,
                                   endCenter: CGPoint(x: panel.midX, y: panel.midY),
                                   endRadius: panel.width * 0.98,
                                   options: [])
    }

    // The panel: warm at the bottom, cool at the top, the way a lightbox looks
    // when it is on.
    let panelRadius = panel.width * 0.055
    context.saveGState()
    context.addPath(roundedPath(panel, radius: panelRadius))
    context.clip()
    if let surface = CGGradient(colorsSpace: space,
                                colors: [color(255, 252, 244), color(226, 236, 250)] as CFArray,
                                locations: [0, 1]) {
        context.drawLinearGradient(surface,
                                   start: CGPoint(x: panel.minX, y: panel.minY),
                                   end: CGPoint(x: panel.maxX, y: panel.maxY),
                                   options: [])
    }

    // Three frames laid on the panel, the middle one standing slightly proud —
    // the one being looked at. Widths differ so it reads as photographs rather
    // than as a grid.
    let gap = panel.width * 0.055
    let margin = panel.width * 0.085
    let usable = panel.width - margin * 2 - gap * 2
    let widths = [usable * 0.28, usable * 0.40, usable * 0.32]
    let heights: [CGFloat] = [0.52, 0.66, 0.46]

    var x = panel.minX + margin
    for (index, width) in widths.enumerated() {
        let height = panel.height * heights[index]
        let frame = CGRect(x: x, y: panel.midY - height / 2, width: width, height: height)
        let radius = width * 0.07

        context.addPath(roundedPath(frame, radius: radius))
        context.setFillColor(index == 1 ? color(20, 25, 33) : color(58, 67, 81))
        context.fillPath()

        // A thin bright edge, as if light were leaking around the frame.
        context.addPath(roundedPath(frame.insetBy(dx: -width * 0.012, dy: -width * 0.012),
                                    radius: radius * 1.1))
        context.setStrokeColor(color(255, 255, 255, 0.35))
        context.setLineWidth(width * 0.02)
        context.strokePath()

        x += width + gap
    }
    context.restoreGState()

    // A hairline around the whole tile, so the icon has an edge on a light
    // background as well as a dark one.
    context.addPath(roundedPath(plate.insetBy(dx: 1, dy: 1), radius: cornerRadius))
    context.setStrokeColor(color(255, 255, 255, 0.09))
    context.setLineWidth(2)
    context.strokePath()
    context.restoreGState()
}

func render(size: CGFloat, fullBleed: Bool) -> CGImage? {
    guard let context = CGContext(data: nil,
                                  width: Int(size),
                                  height: Int(size),
                                  bitsPerComponent: 8,
                                  bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }

    context.setAllowsAntialiasing(true)
    context.interpolationQuality = .high

    // iOS masks the icon itself and requires the square to be filled; macOS
    // expects the artwork to float, with its own rounding and margin.
    draw(in: context,
         size: size,
         inset: fullBleed ? 0 : 100,
         cornerRadius: fullBleed ? 0 : 185)

    return context.makeImage()
}

func write(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL,
                                                           UTType.png.identifier as CFString,
                                                           1, nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw CocoaError(.fileWriteUnknown)
    }
}

// MARK: - The catalog

struct Entry {
    let idiom: String
    let size: String
    let scale: String
    let pixels: CGFloat
    let fullBleed: Bool

    var filename: String {
        fullBleed ? "icon-1024.png" : "icon-mac-\(Int(pixels)).png"
    }
}

let entries: [Entry] = [
    Entry(idiom: "mac", size: "16x16", scale: "1x", pixels: 16, fullBleed: false),
    Entry(idiom: "mac", size: "16x16", scale: "2x", pixels: 32, fullBleed: false),
    Entry(idiom: "mac", size: "32x32", scale: "1x", pixels: 32, fullBleed: false),
    Entry(idiom: "mac", size: "32x32", scale: "2x", pixels: 64, fullBleed: false),
    Entry(idiom: "mac", size: "128x128", scale: "1x", pixels: 128, fullBleed: false),
    Entry(idiom: "mac", size: "128x128", scale: "2x", pixels: 256, fullBleed: false),
    Entry(idiom: "mac", size: "256x256", scale: "1x", pixels: 256, fullBleed: false),
    Entry(idiom: "mac", size: "256x256", scale: "2x", pixels: 512, fullBleed: false),
    Entry(idiom: "mac", size: "512x512", scale: "1x", pixels: 512, fullBleed: false),
    Entry(idiom: "mac", size: "512x512", scale: "2x", pixels: 1024, fullBleed: false),
    Entry(idiom: "universal", size: "1024x1024", scale: "1x", pixels: 1024, fullBleed: true),
]

try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

// One render per distinct pixel size and treatment, however many entries share
// it — 16x16@2x and 32x32@1x are the same 32 pixels.
var written: Set<String> = []
for entry in entries where !written.contains(entry.filename) {
    guard let image = render(size: entry.pixels, fullBleed: entry.fullBleed) else {
        print("could not render \(entry.filename)")
        exit(1)
    }
    try write(image, to: outputDirectory.appendingPathComponent(entry.filename))
    written.insert(entry.filename)
    print("wrote \(entry.filename)")
}

let images = entries.map { entry -> String in
    let platform = entry.idiom == "universal" ? "      \"platform\" : \"ios\",\n" : ""
    return """
        {
    \(platform)      "idiom" : "\(entry.idiom)",
          "filename" : "\(entry.filename)",
          "scale" : "\(entry.scale)",
          "size" : "\(entry.size)"
        }
    """
}

let contents = """
{
  "images" : [
\(images.joined(separator: ",\n"))
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}

"""

try contents.write(to: outputDirectory.appendingPathComponent("Contents.json"),
                   atomically: true, encoding: .utf8)
print("wrote Contents.json")
