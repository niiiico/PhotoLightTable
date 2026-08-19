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

    /// The middle of the last window handed to PhotoKit to decode ahead.
    /// Deliberately not published: priming is a side effect of scrolling, not
    /// something anything on screen is drawn from.
    var lastPrimedCentre: Int?
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
    /// The first photograph of the day a fraction of the way down, for the
    /// callout under the pointer.
    let previewFor: (Double) -> (day: Date, item: PhotoItem)?
    /// On release: the grid moves and the focus lands, so the keyboard carries
    /// on from there.
    ///
    /// Only on release. Scrolling the grid live meant tearing a lazy grid of
    /// ninety thousand photographs to a new position on every point of the
    /// drag, which is as heavy as it sounds. The callout shows where you are
    /// instead — the day, and the first frame of it — and the grid goes there
    /// once.
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

                if let pointer, let preview = previewFor(pointer) {
                    ScrubPreview(day: preview.day, item: preview.item)
                        .offset(x: -128, y: pointer * height - 34)
                }
            }
            .animation(.easeOut(duration: 0.12), value: isActive)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        pointer = clamp(value.location.y / height)
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

    private func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}
/// The day under the pointer, and the first frame of it.
///
/// Shown to the left of the rail, so the hand holding the scrubber is not
/// covering the answer. A date alone is not enough to aim with: the thumbnail
/// is how you recognise the afternoon you were looking for.
private struct ScrubPreview: View {
    let day: Date
    let item: PhotoItem

    @Environment(\.surfaces) private var surfaces
    @State private var image: PlatformImage?

    private let side: CGFloat = 68

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                RoundedRectangle(cornerRadius: 3).fill(surfaces.table)
                if item.isHidden {
                    Image(systemName: "eye.slash")
                        .font(.system(size: 16, weight: .light))
                        .foregroundStyle(.white.opacity(0.35))
                } else if let image {
                    Image(platformImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                }
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: 3))

            Text(day.formatted(.dateTime.day().month(.abbreviated).year()))
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.white)
                .fixedSize()
        }
        .padding(7)
        .background(surfaces.rail.opacity(0.96), in: RoundedRectangle(cornerRadius: 7))
        .shadow(radius: 8, y: 2)
        // Reloaded as the pointer crosses into another day; the loader caches,
        // so scrubbing back over ground already covered costs nothing.
        .task(id: item.id) {
            guard !item.isHidden else { return }
            for await next in ThumbnailLoader.shared.thumbnails(
                for: item, size: CGSize(width: side, height: side), mode: .fill) {
                image = next
            }
        }
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
