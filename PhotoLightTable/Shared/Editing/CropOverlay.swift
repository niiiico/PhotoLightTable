import SwiftUI

/// Aspect ratios offered while cropping. `nil` leaves the rect free.
enum CropAspect: String, CaseIterable, Identifiable {
    case free, original, square, threeTwo, fourThree, sixteenNine

    var id: String { rawValue }

    var label: String {
        switch self {
        case .free: return "Free"
        case .original: return "Original"
        case .square: return "1:1"
        case .threeTwo: return "3:2"
        case .fourThree: return "4:3"
        case .sixteenNine: return "16:9"
        }
    }

    /// Width over height, or nil when unconstrained. `original` resolves against
    /// the photo, so it needs the image's own ratio.
    func ratio(imageAspect: CGFloat) -> CGFloat? {
        switch self {
        case .free: return nil
        case .original: return imageAspect
        case .square: return 1
        case .threeTwo: return 3.0 / 2
        case .fourThree: return 4.0 / 3
        case .sixteenNine: return 16.0 / 9
        }
    }
}

/// Drag handles over the photo, working in the same normalized, top-left space
/// the recipe stores — so what is dragged here is exactly what gets rendered,
/// at preview size and at full resolution alike.
struct CropOverlay: View {
    @Binding var crop: CropRect
    let imageAspect: CGFloat
    let aspect: CropAspect

    @State private var dragStart: CropRect?

    private var handle: CGFloat { max(22, Platform.minimumHitTarget) }
    private var knob: CGFloat { Platform.hasPointer ? 12 : 18 }
    private let border: CGFloat = 1.5

    var body: some View {
        GeometryReader { geo in
            let frame = Self.fittedRect(aspect: imageAspect, in: geo.size)
            let rect = viewRect(in: frame)

            ZStack(alignment: .topLeading) {
                dimming(around: rect, in: geo.size)

                Rectangle()
                    .strokeBorder(.white, lineWidth: border)
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
                    .allowsHitTesting(false)

                thirds(in: rect)

                // Inside the rect: reposition without resizing.
                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
                    .gesture(moveGesture(in: frame))

                ForEach(Corner.allCases) { corner in
                    handleView(corner, rect: rect, frame: frame)
                }
            }
        }
    }

    // MARK: - Pieces

    private func dimming(around rect: CGRect, in size: CGSize) -> some View {
        // Four bands rather than a masked shape: no blend modes, and the cleared
        // area stays exactly aligned with the border.
        ZStack(alignment: .topLeading) {
            band(x: 0, y: 0, w: size.width, h: rect.minY)
            band(x: 0, y: rect.maxY, w: size.width, h: size.height - rect.maxY)
            band(x: 0, y: rect.minY, w: rect.minX, h: rect.height)
            band(x: rect.maxX, y: rect.minY, w: size.width - rect.maxX, h: rect.height)
        }
        .allowsHitTesting(false)
    }

    private func band(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) -> some View {
        Color.black.opacity(0.55)
            .frame(width: max(0, w), height: max(0, h))
            .offset(x: x, y: y)
    }

    private func thirds(in rect: CGRect) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(1..<3) { i in
                Color.white.opacity(0.25)
                    .frame(width: rect.width, height: 0.5)
                    .offset(x: rect.minX, y: rect.minY + rect.height * CGFloat(i) / 3)
            }
            ForEach(1..<3) { i in
                Color.white.opacity(0.25)
                    .frame(width: 0.5, height: rect.height)
                    .offset(x: rect.minX + rect.width * CGFloat(i) / 3, y: rect.minY)
            }
        }
        .allowsHitTesting(false)
    }

    private func handleView(_ corner: Corner, rect: CGRect, frame: CGRect) -> some View {
        let point = corner.point(in: rect)
        return Rectangle()
            .fill(.white)
            .frame(width: knob, height: knob)
            .overlay(Rectangle().strokeBorder(.black.opacity(0.35), lineWidth: 0.5))
            // The touchable area is larger than the drawn one, so a fingertip
            // has something to catch that a 12-point square would not give it.
            .contentShape(Rectangle().inset(by: -handle / 2))
            .offset(x: point.x - knob / 2, y: point.y - knob / 2)
            .gesture(resizeGesture(corner, in: frame))
    }

    // MARK: - Gestures

    private func moveGesture(in frame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let start = dragStart ?? crop
                if dragStart == nil { dragStart = crop }
                var updated = start
                updated.x = start.x + value.translation.width / frame.width
                updated.y = start.y + value.translation.height / frame.height
                // Clamped without resizing, so dragging to an edge stops rather
                // than shrinking the rect.
                updated.x = min(max(updated.x, 0), 1 - updated.width)
                updated.y = min(max(updated.y, 0), 1 - updated.height)
                crop = updated
            }
            .onEnded { _ in dragStart = nil }
    }

    private func resizeGesture(_ corner: Corner, in frame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let start = dragStart ?? crop
                if dragStart == nil { dragStart = crop }

                let dx = value.translation.width / frame.width
                let dy = value.translation.height / frame.height
                var updated = corner.resized(start, dx: dx, dy: dy)

                if let ratio = aspect.ratio(imageAspect: imageAspect) {
                    updated = Self.constrain(updated, to: ratio,
                                             imageAspect: imageAspect, anchoredAt: corner)
                }
                crop = updated.normalized()
            }
            .onEnded { _ in dragStart = nil }
    }

    /// Holds a ratio in *image* terms, which is why the image's own aspect comes
    /// into it: a 1:1 crop is only square once the normalized rect is scaled by
    /// the photo's proportions.
    private static func constrain(_ rect: CropRect,
                                  to ratio: CGFloat,
                                  imageAspect: CGFloat,
                                  anchoredAt corner: Corner) -> CropRect {
        var result = rect
        let targetNormalized = ratio / imageAspect
        let height = result.width / targetNormalized

        if height <= 1 {
            result.height = height
        } else {
            result.height = 1
            result.width = targetNormalized
        }

        // Keep the corner opposite the one being dragged pinned.
        if corner == .topLeading || corner == .topTrailing {
            result.y = rect.y + rect.height - result.height
        }
        if corner == .topLeading || corner == .bottomLeading {
            result.x = rect.x + rect.width - result.width
        }
        return result
    }

    // MARK: - Geometry

    private func viewRect(in frame: CGRect) -> CGRect {
        CGRect(x: frame.minX + crop.x * frame.width,
               y: frame.minY + crop.y * frame.height,
               width: crop.width * frame.width,
               height: crop.height * frame.height)
    }

    /// Where an aspect-fit image actually lands inside the available space —
    /// the crop rect is relative to the photo, not to the view.
    static func fittedRect(aspect: CGFloat, in size: CGSize) -> CGRect {
        guard aspect > 0, size.width > 0, size.height > 0 else { return .zero }
        let viewAspect = size.width / size.height
        if aspect > viewAspect {
            let height = size.width / aspect
            return CGRect(x: 0, y: (size.height - height) / 2, width: size.width, height: height)
        } else {
            let width = size.height * aspect
            return CGRect(x: (size.width - width) / 2, y: 0, width: width, height: size.height)
        }
    }

    enum Corner: String, CaseIterable, Identifiable {
        case topLeading, topTrailing, bottomLeading, bottomTrailing

        var id: String { rawValue }

        func point(in rect: CGRect) -> CGPoint {
            switch self {
            case .topLeading: return CGPoint(x: rect.minX, y: rect.minY)
            case .topTrailing: return CGPoint(x: rect.maxX, y: rect.minY)
            case .bottomLeading: return CGPoint(x: rect.minX, y: rect.maxY)
            case .bottomTrailing: return CGPoint(x: rect.maxX, y: rect.maxY)
            }
        }

        /// Moves this corner while the opposite one stays put.
        func resized(_ rect: CropRect, dx: Double, dy: Double) -> CropRect {
            var result = rect
            switch self {
            case .topLeading:
                result.x = rect.x + dx
                result.y = rect.y + dy
                result.width = rect.width - dx
                result.height = rect.height - dy
            case .topTrailing:
                result.y = rect.y + dy
                result.width = rect.width + dx
                result.height = rect.height - dy
            case .bottomLeading:
                result.x = rect.x + dx
                result.width = rect.width - dx
                result.height = rect.height + dy
            case .bottomTrailing:
                result.width = rect.width + dx
                result.height = rect.height + dy
            }
            return result
        }
    }
}
