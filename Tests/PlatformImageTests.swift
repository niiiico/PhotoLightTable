import CoreImage
import Foundation
import Testing

@testable import LightTable

#if os(macOS)
import AppKit

@Suite("Turning a platform image back into pixels")
struct PlatformImageTests {
    @Test("An image whose size disagrees with its pixels keeps its pixels")
    func sizeDisagreesWithPixels() throws {
        // This is `PHContentEditingInput.displaySizeImage` for a photo taken
        // with the camera rotated: the backing bitmap is landscape and the
        // NSImage's size is portrait, because size is in points and carries
        // the orientation.
        //
        // Re-rendering such an image at its size squashes it instead of
        // rotating it, and everything measured from the result is wrong by
        // exactly the aspect ratio — which is how a subject mask came to be
        // stored at 9:16 for a 3:4 photograph.
        let context = CGContext(data: nil, width: 400, height: 300,
                                bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        let landscape = context.makeImage()!

        let image = NSImage(cgImage: landscape, size: CGSize(width: 300, height: 400))
        let converted = try #require(CIImage.from(image))

        #expect(converted.extent.width == 400)
        #expect(converted.extent.height == 300)
    }

    @Test("An ordinary image is unchanged")
    func sizeAgreesWithPixels() throws {
        let context = CGContext(data: nil, width: 120, height: 90,
                                bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let cgImage = context.makeImage()!
        let converted = try #require(CIImage.from(PlatformImage.from(cgImage)))

        #expect(converted.extent.width == 120)
        #expect(converted.extent.height == 90)
    }
}
#endif
