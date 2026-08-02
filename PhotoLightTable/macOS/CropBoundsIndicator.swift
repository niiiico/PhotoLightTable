#if os(macOS)
import SwiftUI

/// Dims what the crop will discard.
///
/// Shown while a mask is being placed, because placing one drops the crop from
/// the preview — masks are stored against the uncropped image, so they have to
/// be positioned against it. Without this the wider frame would be misleading
/// about what the photo actually ends up being.
struct CropBoundsIndicator: View {
    let crop: CropRect
    let imageAspect: CGFloat

    var body: some View {
        GeometryReader { geo in
            let frame = CropOverlay.fittedRect(aspect: imageAspect, in: geo.size)
            let rect = CGRect(x: frame.minX + crop.x * frame.width,
                              y: frame.minY + crop.y * frame.height,
                              width: crop.width * frame.width,
                              height: crop.height * frame.height)

            ZStack(alignment: .topLeading) {
                band(x: 0, y: 0, w: geo.size.width, h: rect.minY)
                band(x: 0, y: rect.maxY, w: geo.size.width, h: geo.size.height - rect.maxY)
                band(x: 0, y: rect.minY, w: rect.minX, h: rect.height)
                band(x: rect.maxX, y: rect.minY, w: geo.size.width - rect.maxX, h: rect.height)

                Rectangle()
                    .strokeBorder(.white.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
            }
            .allowsHitTesting(false)
        }
    }

    private func band(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) -> some View {
        Color.black.opacity(0.35)
            .frame(width: max(0, w), height: max(0, h))
            .offset(x: x, y: y)
    }
}
#endif
