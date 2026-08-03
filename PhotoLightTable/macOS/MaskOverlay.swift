#if os(macOS)
import SwiftUI

/// Handles for placing a gradient over the photo.
///
/// Works in the same normalized, top-left space the recipe stores, so what is
/// dragged here is what renders — at preview size and at full resolution alike.
struct MaskOverlay: View {
    @Binding var mask: EditMask
    let imageAspect: CGFloat

    /// Shown while the shape is being changed, then faded out. Leaving it up
    /// permanently would tint every judgement made about the photo underneath.
    @State private var showsCoverage = false
    @State private var fadeTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { geo in
            let frame = CropOverlay.fittedRect(aspect: imageAspect, in: geo.size)
            let p0 = point(mask.start, in: frame)
            let p1 = point(mask.end, in: frame)

            ZStack(alignment: .topLeading) {
                coverage(from: p0, to: p1, in: frame)
                    .opacity(showsCoverage ? 1 : 0)
                    .animation(.easeInOut(duration: showsCoverage ? 0.12 : 0.45),
                               value: showsCoverage)

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
            .onAppear(perform: revealCoverage)
        }
    }

    /// A wash following the mask's own falloff, so the ramp is visible rather
    /// than inferred from two dots — where it starts, where it reaches full
    /// strength, and which side of the line is affected.
    @ViewBuilder
    private func coverage(from p0: CGPoint, to p1: CGPoint, in frame: CGRect) -> some View {
        let tint = Color.red.opacity(0.32)
        let near: Color = mask.isInverted ? tint : .clear
        let far: Color = mask.isInverted ? .clear : tint

        switch mask.kind {
        case .linear:
            Rectangle()
                .fill(LinearGradient(
                    stops: [.init(color: near, location: 0), .init(color: far, location: 1)],
                    startPoint: unit(p0, in: frame),
                    endPoint: unit(p1, in: frame)))
                .frame(width: frame.width, height: frame.height)
                .offset(x: frame.minX, y: frame.minY)

        case .radial:
            let radius = max(1, hypot(p1.x - p0.x, p1.y - p0.y))
            Rectangle()
                .fill(RadialGradient(
                    stops: [.init(color: far, location: 0), .init(color: near, location: 1)],
                    center: unit(p0, in: frame),
                    startRadius: 0,
                    endRadius: radius))
                .frame(width: frame.width, height: frame.height)
                .offset(x: frame.minX, y: frame.minY)

        case .brush:
            EmptyView()
        }
    }

    /// Shows the wash and starts it fading. Called on every drag change, so the
    /// fade keeps being pushed out while the shape is still moving.
    private func revealCoverage() {
        fadeTask?.cancel()
        showsCoverage = true
        fadeTask = Task {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            showsCoverage = false
        }
    }

    /// SwiftUI gradients take unit points in the view's own space, while the
    /// handles live in the fitted image rect.
    private func unit(_ point: CGPoint, in frame: CGRect) -> UnitPoint {
        guard frame.width > 0, frame.height > 0 else { return .center }
        return UnitPoint(x: (point.x - frame.minX) / frame.width,
                         y: (point.y - frame.minY) / frame.height)
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
                revealCoverage()
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
