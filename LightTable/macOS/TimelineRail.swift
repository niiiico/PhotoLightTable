#if os(macOS)
import SwiftUI

/// Where the grid is scrolled to, kept out of the grid's own state.
///
/// It changes on every frame of a scroll, and the grid's body builds the
/// structure for every day section in the library — making that body depend on
/// the scroll position would rebuild all of it, sixty times a second. The rail
/// observes this instead, and the grid holds it with `@State` rather than
/// `@StateObject` so that holding it does not mean watching it.
@MainActor
final class ScrollPosition: ObservableObject {
    @Published var fraction: Double = 0
}

/// The scrubber beside the grid: a year-and-month scale you can grab.
///
/// Beside rather than over the photographs. A rail floating on top of the
/// right-hand column means the rightmost frame of every row cannot be clicked,
/// which is a strange price to pay for a scrollbar.
struct TimelineRail: View {
    /// Fixed, because the grid has to subtract it before working out how many
    /// columns fit.
    static let width: CGFloat = 58

    let ticks: [TimelineIndex.Tick]
    @ObservedObject var position: ScrollPosition
    /// The day a fraction of the way down, for the callout under the pointer.
    let dayFor: (Double) -> Date?
    /// Continuous while dragging: the grid follows the pointer.
    let onScrub: (Double) -> Void
    /// On release: the focus lands, so the keyboard carries on from there.
    let onLand: (Double) -> Void

    @Environment(\.surfaces) private var surfaces
    @State private var pointer: Double?
    @State private var isHovering = false

    var body: some View {
        GeometryReader { geo in
            let height = geo.size.height
            ZStack(alignment: .topTrailing) {
                // The whole column takes the drag, not just the marks: aiming
                // at a one-pixel tick is not scrubbing.
                Rectangle()
                    .fill(isActive ? surfaces.header.opacity(0.9) : .clear)
                    .contentShape(Rectangle())

                ForEach(ticks, id: \.fraction) { tick in
                    tickRow(tick)
                        .offset(y: tick.fraction * height - 7)
                }

                thumb
                    .offset(y: position.fraction * height - 1)

                if let pointer {
                    callout(at: pointer, height: height)
                }
            }
            .animation(.easeOut(duration: 0.12), value: isActive)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let fraction = clamp(value.location.y / height)
                        pointer = fraction
                        onScrub(fraction)
                    }
                    .onEnded { value in
                        let fraction = clamp(value.location.y / height)
                        pointer = nil
                        onLand(fraction)
                    }
            )
            .onHover { isHovering = $0 }
        }
        .frame(width: Self.width)
    }

    private var isActive: Bool { isHovering || pointer != nil }

    private func tickRow(_ tick: TimelineIndex.Tick) -> some View {
        HStack(spacing: 4) {
            Spacer(minLength: 0)
            Text(tick.label)
                .font(.system(size: 9, weight: tick.isMajor ? .semibold : .regular))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(tick.isMajor ? 0.55 : 0.35))
                .fixedSize()
            Rectangle()
                .fill(.white.opacity(tick.isMajor ? 0.35 : 0.2))
                .frame(width: tick.isMajor ? 8 : 5, height: 1)
        }
        .padding(.trailing, 6)
        .frame(height: 14)
    }

    private var thumb: some View {
        Rectangle()
            .fill(.white.opacity(0.75))
            .frame(height: 2)
            .padding(.leading, 10)
    }

    /// The day under the pointer, shown to the left of the rail so the hand
    /// holding the scrubber is not covering the answer.
    private func callout(at fraction: Double, height: CGFloat) -> some View {
        Text(dayFor(fraction)?.formatted(.dateTime.day().month(.abbreviated).year()) ?? "")
            .font(.system(size: 11, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(.white)
            .fixedSize()
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(surfaces.rail.opacity(0.95), in: Capsule())
            .offset(x: -66, y: fraction * height - 12)
    }

    private func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}
/// The scroll position, reported out of the scrolled content.
struct ScrollFractionKey: PreferenceKey {
    static let defaultValue: Double = 0
    static func reduce(value: inout Double, nextValue: () -> Double) {
        value = nextValue()
    }
}
#endif
