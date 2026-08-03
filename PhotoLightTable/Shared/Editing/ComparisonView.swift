import SwiftUI

enum ComparisonMode: String, CaseIterable, Identifiable {
    case off, split, sideBySide

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: return "No Comparison"
        case .split: return "Split"
        case .sideBySide: return "Side by Side"
        }
    }

    var symbolName: String {
        switch self {
        case .off: return "rectangle"
        case .split: return "rectangle.split.2x1"
        case .sideBySide: return "rectangle.grid.1x2.fill"
        }
    }

    var isActive: Bool { self != .off }
}

/// Shows the photo as it was against the photo as it is.
///
/// Split puts both in the same frame under a draggable divider, which is what
/// answers "did that actually help" for a local adjustment. Side by side keeps
/// them separate, which reads better for overall tone and colour.
struct ComparisonView: View {
    let before: PlatformImage
    let after: PlatformImage
    let mode: ComparisonMode

    @Binding var splitPosition: Double

    var body: some View {
        switch mode {
        case .off:
            EmptyView()
        case .split:
            splitView
        case .sideBySide:
            sideBySideView
        }
    }

    private var splitView: some View {
        GeometryReader { geo in
            let frame = CropOverlay.fittedRect(aspect: aspect, in: geo.size)
            let divider = frame.minX + frame.width * splitPosition

            ZStack(alignment: .topLeading) {
                Image(platformImage: after)
                    .resizable()
                    .aspectRatio(contentMode: .fit)

                // The two are the same size and position, so masking one to the
                // left of the divider lines the halves up exactly.
                Image(platformImage: before)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .mask(alignment: .leading) {
                        Rectangle().frame(width: max(0, divider))
                    }

                Rectangle()
                    .fill(.white)
                    .frame(width: 1, height: frame.height)
                    .offset(x: divider, y: frame.minY)

                handle(at: divider, y: frame.midY)
                    .gesture(dragGesture(in: frame))

                label("Before", at: .leading, frame: frame)
                label("After", at: .trailing, frame: frame)
            }
        }
    }

    private var sideBySideView: some View {
        HStack(spacing: 10) {
            captioned(before, "Before")
            captioned(after, "After")
        }
    }

    private func captioned(_ image: PlatformImage, _ caption: String) -> some View {
        VStack(spacing: 6) {
            Image(platformImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
            Text(caption.uppercased())
                .font(.caption2.weight(.bold))
                .kerning(0.8)
                .foregroundStyle(.secondary)
        }
    }

    private func handle(at x: CGFloat, y: CGFloat) -> some View {
        Circle()
            .fill(.white)
            .frame(width: Platform.hasPointer ? 22 : 32, height: Platform.hasPointer ? 22 : 32)
            .overlay {
                Image(systemName: "arrow.left.and.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.black.opacity(0.7))
            }
            .shadow(radius: 3)
            .position(x: x, y: y)
            .contentShape(Circle().inset(by: -Platform.minimumHitTarget / 2))
    }

    private func dragGesture(in frame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard frame.width > 0 else { return }
                splitPosition = min(max((value.location.x - frame.minX) / frame.width, 0), 1)
            }
    }

    private func label(_ text: String,
                       at edge: HorizontalAlignment,
                       frame: CGRect) -> some View {
        Text(text.uppercased())
            .font(.caption2.weight(.bold))
            .kerning(0.8)
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.black.opacity(0.45), in: Capsule())
            .position(x: edge == .leading ? frame.minX + 44 : frame.maxX - 40,
                      y: frame.minY + 20)
            .allowsHitTesting(false)
    }

    private var aspect: CGFloat {
        after.size.height > 0 ? after.size.width / after.size.height : 1
    }
}
