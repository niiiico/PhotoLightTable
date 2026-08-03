#if os(macOS)
import SwiftUI

/// Painting surface for a brush mask.
///
/// Strokes are captured in the same normalized, top-left space the recipe
/// stores, so what is painted here is what renders — and the mask survives a
/// change of preview size or a full-resolution commit unchanged.
struct BrushOverlay: View {
    @Binding var mask: EditMask
    let imageAspect: CGFloat
    let brushRadius: Double
    let isErasing: Bool
    /// Painted area is shown while the brush is in hand and hidden otherwise,
    /// so the photo can be judged without a wash of colour over it.
    let showsPaint: Bool
    /// Feathering, as a fraction of the shorter side — the same value the mask
    /// is rasterised with.
    let softness: Double

    @State private var strokeID: UUID?
    @State private var pointer: CGPoint?
    @State private var isPainting = false

    var body: some View {
        GeometryReader { geo in
            let frame = CropOverlay.fittedRect(aspect: imageAspect, in: geo.size)

            ZStack(alignment: .topLeading) {
                if showsPaint {
                    paint(in: frame)
                }

                Color.clear
                    .contentShape(Rectangle())
                    .gesture(paintGesture(in: frame))
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location): pointer = location
                        case .ended: pointer = nil
                        }
                    }

                if let pointer {
                    // The cursor shows the brush's true footprint; a size in the
                    // panel means nothing without seeing it against the photo.
                    // The outer ring is how far the feathering reaches, which is
                    // otherwise invisible until something is painted.
                    ZStack {
                        Circle()
                            .strokeBorder(.white.opacity(0.25),
                                          style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                            .frame(width: diameter(in: frame) + featherRadius(in: frame) * 2,
                                   height: diameter(in: frame) + featherRadius(in: frame) * 2)

                        Circle()
                            .strokeBorder(.white.opacity(0.9), lineWidth: 1)
                            .background(Circle().fill(.white.opacity(isErasing ? 0 : 0.08)))
                            .frame(width: diameter(in: frame), height: diameter(in: frame))
                    }
                    .position(pointer)
                    .allowsHitTesting(false)
                }
            }
        }
    }

    /// Erase strokes are composited out of the painted area rather than drawn in
    /// another colour, so what is shown matches what the mask will contain.
    ///
    /// The whole thing is blurred by the mask's own softness, so the wash shows
    /// how far the effect actually feathers past the stroke rather than implying
    /// a hard edge the render won't have. It brightens while painting, which is
    /// when the extent is the thing being judged.
    private func paint(in frame: CGRect) -> some View {
        ZStack {
            ForEach(mask.strokes) { stroke in
                path(for: stroke, in: frame)
                    .stroke(Color.red.opacity(isPainting ? 0.42 : 0.3),
                            style: StrokeStyle(lineWidth: lineWidth(stroke.radius, in: frame),
                                               lineCap: .round,
                                               lineJoin: .round))
                    .blendMode(stroke.isErase ? .destinationOut : .normal)
            }
        }
        .compositingGroup()
        .blur(radius: featherRadius(in: frame))
        .animation(.easeOut(duration: 0.15), value: isPainting)
        .allowsHitTesting(false)
    }

    /// Mirrors the rasteriser, which blurs the mask by `softness * shortSide *
    /// 0.12` — so the wash feathers by the same proportion the render will.
    private func featherRadius(in frame: CGRect) -> CGFloat {
        softness * min(frame.width, frame.height) * 0.12
    }

    private func path(for stroke: BrushStroke, in frame: CGRect) -> Path {
        Path { path in
            let points = stroke.points.map { point(in: frame, $0) }
            guard let first = points.first else { return }
            if points.count == 1 {
                // A single tap still has to show as a dot.
                let radius = lineWidth(stroke.radius, in: frame) / 2
                path.addEllipse(in: CGRect(x: first.x - radius, y: first.y - radius,
                                           width: radius * 2, height: radius * 2))
            } else {
                path.move(to: first)
                for next in points.dropFirst() { path.addLine(to: next) }
            }
        }
    }

    private func paintGesture(in frame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                pointer = value.location
                isPainting = true
                guard frame.width > 0, frame.height > 0 else { return }
                let point = EditPoint(x: (value.location.x - frame.minX) / frame.width,
                                      y: (value.location.y - frame.minY) / frame.height)

                if let strokeID,
                   let index = mask.strokes.firstIndex(where: { $0.id == strokeID }) {
                    // Thinned: a drag reports far more positions than a stroke
                    // needs, and every one of them is stored and re-rendered.
                    if let last = mask.strokes[index].points.last,
                       hypot(last.x - point.x, last.y - point.y) < brushRadius * 0.15 {
                        return
                    }
                    mask.strokes[index].points.append(point)
                } else {
                    var stroke = BrushStroke()
                    stroke.radius = brushRadius
                    stroke.isErase = isErasing
                    stroke.points = [point]
                    mask.strokes.append(stroke)
                    strokeID = stroke.id
                }
            }
            .onEnded { _ in
                strokeID = nil
                isPainting = false
            }
    }

    private func point(in frame: CGRect, _ point: EditPoint) -> CGPoint {
        CGPoint(x: frame.minX + point.x * frame.width,
                y: frame.minY + point.y * frame.height)
    }

    /// Radius is a fraction of the shorter side, matching how it is rasterised.
    private func lineWidth(_ radius: Double, in frame: CGRect) -> CGFloat {
        radius * 2 * min(frame.width, frame.height)
    }

    private func diameter(in frame: CGRect) -> CGFloat {
        max(4, lineWidth(brushRadius, in: frame))
    }
}
#endif
