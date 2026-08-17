import SwiftUI

/// The run of photographs either side of the one being looked at.
///
/// The loupe shows one frame at a time, which is what it is for — but arrowing
/// through a take gives no sense of where you are in it, whether the next frame
/// is the same moment or a different one, or how much is left. A strip along
/// the bottom answers all three without taking the picture off the screen.
///
/// Deliberately small and quiet. It is context, not a second grid, and anything
/// large enough to judge from would be competing with the photograph above it.
struct FilmStrip: View {
    let items: [PhotoItem]
    let currentID: String?
    /// Verdict per photo, so the strip can show what has been decided without
    /// reaching into the store from a view this small.
    let ratingFor: (String) -> RatingValue
    let onSelect: (String) -> Void
    let onDismiss: () -> Void

    @Environment(\.surfaces) private var surfaces

    private let height: CGFloat = 62

    var body: some View {
        ScrollViewReader { proxy in
            HStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 4) {
                        ForEach(items) { item in
                            FilmStripCell(item: item,
                                          height: height,
                                          isCurrent: item.id == currentID,
                                          rating: ratingFor(item.id),
                                          surfaces: surfaces)
                                .id(item.id)
                                .onTapGesture { onSelect(item.id) }
                        }
                    }
                    .padding(.horizontal, 8)
                }

                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(8)
                }
                .buttonStyle(.plain)
                .help("Hide the strip (F)")
            }
            .frame(height: height + 12)
            .background(surfaces.mat)
            // Centred on the current photo rather than merely scrolled into
            // view: what is coming next matters as much as what is here, and an
            // edge-aligned strip shows only one side of it.
            .onChange(of: currentID) { _, newValue in
                guard let newValue else { return }
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
            .onAppear {
                guard let currentID else { return }
                proxy.scrollTo(currentID, anchor: .center)
            }
        }
    }
}

/// One frame in the strip.
///
/// Its own small view rather than a `ThumbnailCell`, which carries verdicts,
/// stacks, capture badges and selection — none of which belong at this size,
/// where they would be illegible marks over a picture too small to read.
private struct FilmStripCell: View, Equatable {
    let item: PhotoItem
    let height: CGFloat
    let isCurrent: Bool
    let rating: RatingValue
    /// Passed in for the same reason as `ThumbnailCell`'s: this cell is
    /// compared, and the comparison cannot see the environment.
    let surfaces: Surfaces

    @State private var image: PlatformImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3)
                .fill(surfaces.table)

            if let image {
                Image(platformImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            }
        }
        .frame(width: height, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        // The mark only, no word: at this size a label would be a smudge, and
        // the shape of the symbol is what is being read anyway.
        .overlay(alignment: .topLeading) {
            if rating.pick != .unrated {
                Image(systemName: rating.pick.symbolName)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(2.5)
                    .background(rating.pick.tint, in: Circle())
                    .padding(3)
            }
        }
        .overlay(alignment: .bottom) {
            if let color = rating.color {
                color.color
                    .frame(height: 3)
                    .clipShape(RoundedRectangle(cornerRadius: 1.5))
                    .padding(.horizontal, 5)
                    .padding(.bottom, 3)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(isCurrent ? Color.accentColor : .clear, lineWidth: 2)
        }
        .opacity(isCurrent ? 1 : 0.55)
        .animation(.easeOut(duration: 0.15), value: isCurrent)
        .task(id: item.id) {
            image = await ThumbnailLoader.shared.thumbnail(
                for: item,
                size: CGSize(width: height, height: height),
                mode: .fill)
        }
    }

    static func == (lhs: FilmStripCell, rhs: FilmStripCell) -> Bool {
        lhs.item.id == rhs.item.id && lhs.isCurrent == rhs.isCurrent
            && lhs.height == rhs.height && lhs.rating == rhs.rating
            && lhs.surfaces.levels == rhs.surfaces.levels
    }
}
