#if os(macOS)
import SwiftUI

/// Catches a click on the photo and reports where it landed, normalized.
///
/// Works in the same top-left space the recipe stores, so the sample is taken
/// from the point that was clicked whatever size the preview happens to be.
struct WhitePointPicker: View {
    let imageAspect: CGFloat
    let onPick: (EditPoint) -> Void
    let onCancel: () -> Void

    @State private var pointer: CGPoint?

    var body: some View {
        GeometryReader { geo in
            let frame = CropOverlay.fittedRect(aspect: imageAspect, in: geo.size)

            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    // A drag rather than a tap, because a tap gesture reports no
                    // location and the location is the whole point.
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { pointer = $0.location }
                            .onEnded { value in
                                guard frame.width > 0, frame.height > 0,
                                      frame.contains(value.location) else {
                                    onCancel()
                                    return
                                }
                                onPick(EditPoint(
                                    x: (value.location.x - frame.minX) / frame.width,
                                    y: (value.location.y - frame.minY) / frame.height))
                            }
                    )
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location): pointer = location
                        case .ended: pointer = nil
                        }
                    }

                if let pointer {
                    // Ringed at the size actually sampled, so it is clear this
                    // averages a patch rather than reading one pixel.
                    ZStack {
                        Circle()
                            .strokeBorder(.white, lineWidth: 1.5)
                            .frame(width: 26, height: 26)
                        Circle()
                            .strokeBorder(.black.opacity(0.5), lineWidth: 1)
                            .frame(width: 28, height: 28)
                        Rectangle().fill(.white).frame(width: 1, height: 9)
                        Rectangle().fill(.white).frame(width: 9, height: 1)
                    }
                    .position(pointer)
                    .allowsHitTesting(false)
                }

                Text("Click a neutral grey or white — Esc to cancel")
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.black.opacity(0.55), in: Capsule())
                    .position(x: geo.size.width / 2, y: 26)
                    .allowsHitTesting(false)
            }
        }
    }
}
#endif
