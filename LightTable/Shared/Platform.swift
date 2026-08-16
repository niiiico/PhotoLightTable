import CoreImage
import SwiftUI

#if os(macOS)
import AppKit
typealias PlatformImage = NSImage
#else
import UIKit
typealias PlatformImage = UIImage
#endif

extension Image {
    init(platformImage: PlatformImage) {
        #if os(macOS)
        self.init(nsImage: platformImage)
        #else
        self.init(uiImage: platformImage)
        #endif
    }
}

extension PlatformImage {
    static func from(_ cgImage: CGImage) -> PlatformImage {
        #if os(macOS)
        // A zero size takes the CGImage's own pixel dimensions.
        NSImage(cgImage: cgImage, size: .zero)
        #else
        UIImage(cgImage: cgImage)
        #endif
    }
}

extension CIImage {
    /// The image's own pixels, not a re-rendering of it.
    ///
    /// `tiffRepresentation` draws the image into a box the size of its `size`,
    /// which is in points. When those disagree with the backing pixels — as
    /// they do for `PHContentEditingInput.displaySizeImage` on a photo taken
    /// with the camera rotated — the result is squashed rather than merely
    /// resampled, and every measurement taken from it is wrong in a way that
    /// looks plausible. A subject mask captured through it came back at 9:16
    /// for a 3:4 photograph.
    static func from(_ image: PlatformImage) -> CIImage? {
        #if os(macOS)
        var rect = CGRect(origin: .zero, size: image.size)
        if let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
            return CIImage(cgImage: cgImage)
        }
        guard let data = image.tiffRepresentation else { return nil }
        return CIImage(data: data)
        #else
        if let ciImage = image.ciImage { return ciImage }
        guard let cgImage = image.cgImage else { return nil }
        return CIImage(cgImage: cgImage)
        #endif
    }
}

enum Platform {
    /// Smallest comfortable hit target. A pointer lands where it is aimed; a
    /// fingertip covers about 44 points and cannot see what is under it.
    static var minimumHitTarget: CGFloat {
        #if os(macOS)
        24
        #else
        44
        #endif
    }

    /// Whether a pointer is the primary input. Hover states and 12-point
    /// handles only make sense when it is.
    static var hasPointer: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    /// Backing scale, used to ask PhotoKit for thumbnails at native resolution
    /// rather than upscaling a point-sized image.
    static var screenScale: CGFloat {
        #if os(macOS)
        NSScreen.main?.backingScaleFactor ?? 2
        #else
        UITraitCollection.current.displayScale
        #endif
    }

    /// Takes the user to wherever photo-library permission is granted. The two
    /// platforms disagree on both the URL and who opens it.
    @MainActor
    static func openPhotoPrivacySettings() {
        #if os(macOS)
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos") else { return }
        NSWorkspace.shared.open(url)
        #else
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
        #endif
    }
}
