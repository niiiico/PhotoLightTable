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
    static func from(_ image: PlatformImage) -> CIImage? {
        #if os(macOS)
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
