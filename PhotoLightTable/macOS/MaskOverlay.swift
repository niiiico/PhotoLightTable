#if os(macOS)
import SwiftUI

/// Handles for placing a gradient over the photo.
///
/// Works in the same normalized, top-left space the recipe stores, so what is
/// dragged here is what renders — at preview size and at full resolution alike.
struct MaskOverlay: View {
    @Binding var mask: EditMask
    let imageAspect: CGFloat

    var body: some View {
        GeometryReader { geo in
            let frame = CropOverlay.fittedRect(aspect: imageAspect, in: geo.size)
            let p0 = point(mask.start, in: frame)
            let p1 = point(mask.end, in: frame)

            ZStack(alignment: .topLeading) {
                guides(from: p0, to: p1, in: frame)

                Path { $0.move(to: p0); $0.addLine(to: p1) }
                    .stroke(.white.opacity(0.9), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .allowsHitTesting(false)

                handle(at: p0, filled: false)
                    .gesture(drag(for: \.start, in: frame))
                handle(at: p1, filled: true)
                    .gesture(drag(for: \.end, in: frame))
            }
            .opacity(mask.kind == .brush ? 0 : 1)
        }
    }

    /// The extent of the effect: parallel lines through each end for a linear
    /// ramp, a circle for a radial one. Without them the two dots say where the
    /// gradient is anchored but nothing about what it covers.
    @ViewBuilder
    private func guides(from p0: CGPoint, to p1: CGPoint, in frame: CGRect) -> some View {
        switch mask.kind {
        case .linear:
            let angle = atan2(p1.y - p0.y, p1.x - p0.x) + .pi / 2
            let reach = max(frame.width, frame.height)
            let dx = cos(angle) * reach
            let dy = sin(angle) * reach

            Path { path in
                path.move(to: CGPoint(x: p0.x - dx, y: p0.y - dy))
                path.addLine(to: CGPoint(x: p0.x + dx, y: p0.y + dy))
                path.move(to: CGPoint(x: p1.x - dx, y: p1.y - dy))
                path.addLine(to: CGPoint(x: p1.x + dx, y: p1.y + dy))
            }
            .stroke(.white.opacity(0.5), lineWidth: 1)
            .allowsHitTesting(false)

        case .brush:
            EmptyView()

        case .radial:
            let radius = hypot(p1.x - p0.x, p1.y - p0.y)
            Circle()
                .strokeBorder(.white.opacity(0.6), lineWidth: 1)
                .frame(width: radius * 2, height: radius * 2)
                .offset(x: p0.x - radius, y: p0.y - radius)
                .allowsHitTesting(false)
        }
    }

    private func handle(at point: CGPoint, filled: Bool) -> some View {
        Circle()
            .fill(filled ? .white : .white.opacity(0.25))
            .overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
            .frame(width: 13, height: 13)
            .contentShape(Circle().inset(by: -12))
            .offset(x: point.x - 6.5, y: point.y - 6.5)
    }

    private func drag(for keyPath: WritableKeyPath<EditMask, EditPoint>,
                      in frame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard frame.width > 0, frame.height > 0 else { return }
                mask[keyPath: keyPath] = EditPoint(
                    x: min(max((value.location.x - frame.minX) / frame.width, -0.5), 1.5),
                    y: min(max((value.location.y - frame.minY) / frame.height, -0.5), 1.5))
            }
    }

    private func point(_ point: EditPoint, in frame: CGRect) -> CGPoint {
        CGPoint(x: frame.minX + point.x * frame.width,
                y: frame.minY + point.y * frame.height)
    }
}
#endif
