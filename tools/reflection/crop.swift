#!/usr/bin/env swift
// Crops a region given in top-left pixel coordinates, for comparing detail.
// usage: swift crop.swift <in> <out.jpg> <x> <yTop> <w> <h> [zoom]
import CoreImage
import Foundation

let a = CommandLine.arguments
let src = URL(fileURLWithPath: a[1])
let dst = URL(fileURLWithPath: a[2])
let x = Double(a[3])!, yTop = Double(a[4])!, w = Double(a[5])!, h = Double(a[6])!
let zoom = a.count > 7 ? Double(a[7])! : 1

// RAW first: CIImage(contentsOf:) opens a DNG but does NOT apply its
// orientation, so the crop would silently be of a different region.
guard var image = CIRAWFilter(imageURL: src)?.outputImage ?? CIImage(contentsOf: src) else { exit(1) }
// Core Image's origin is bottom-left; the arguments are top-left.
let y = image.extent.height - yTop - h
image = image.cropped(to: CGRect(x: x, y: y, width: w, height: h))
image = image.transformed(by: CGAffineTransform(translationX: -x, y: -y))
image = image.transformed(by: CGAffineTransform(scaleX: zoom, y: zoom))

let context = CIContext()
try context.writeJPEGRepresentation(of: image, to: dst,
                                    colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
print("wrote \(dst.lastPathComponent)")
