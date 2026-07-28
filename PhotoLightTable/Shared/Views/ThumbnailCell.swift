import SwiftUI

struct ThumbnailCell: View {
    let item: PhotoItem
    let size: CGFloat
    let rating: RatingValue
    let isSelected: Bool
    let isFocused: Bool
    /// Only set during a genuine multi-selection — a checkmark on every cell you
    /// arrow through would be noise.
    let showsSelectionBadge: Bool

    @State private var image: PlatformImage?
    @StateObject private var loader = ThumbnailLoader.shared
    @AppStorage(PreferenceKey.thumbnailFillMode) private var fillModeRaw = ThumbnailFillMode.fill.rawValue

    private var fillMode: ThumbnailFillMode {
        ThumbnailFillMode(rawValue: fillModeRaw) ?? .fill
    }

    private var isActive: Bool { isSelected || isFocused }

    /// Selected cells inset their image to reveal a coloured mat behind it.
    /// Shrinking the photo is what makes selection readable at a glance, in a
    /// way a border drawn over a busy photo never is.
    private var matInset: CGFloat { isActive ? 6 : 0 }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(matColor)

            photo
                .padding(matInset)
        }
        .frame(width: size, height: size)
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(ringColor, lineWidth: ringWidth)
        }
        .shadow(color: isFocused ? Color.accentColor.opacity(0.7) : .clear,
                radius: isFocused ? 7 : 0)
        .animation(.easeOut(duration: 0.1), value: isActive)
        .contentShape(Rectangle())
        .task(id: "\(item.id)#\(fillModeRaw)") {
            image = await loader.thumbnail(for: item,
                                           size: CGSize(width: size, height: size),
                                           mode: fillMode)
        }
    }

    // MARK: - Photo

    private var photo: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3)
                .fill(fillMode == .fit ? Color.black : Color.black.opacity(0.25))

            if let image {
                Image(platformImage: image)
                    .resizable()
                    .aspectRatio(contentMode: fillMode.swiftUIContentMode)
                    .frame(width: size - matInset * 2, height: size - matInset * 2)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            } else {
                ProgressView()
                    .controlSize(.small)
            }

            // Rejects stay visible but recede, so the eye skips them while
            // scanning without losing the shape of the take.
            if rating.pick == .rejected {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.black.opacity(0.55))
            }

            badges
        }
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay(alignment: .bottom) {
            if let color = rating.color {
                color.color
                    .frame(height: 4)
                    .clipShape(RoundedRectangle(cornerRadius: 2))
                    .padding(.horizontal, 6)
                    .padding(.bottom, 4)
            }
        }
    }

    private var badges: some View {
        VStack {
            HStack {
                if rating.pick != .unrated {
                    Image(systemName: rating.pick.symbolName)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(4)
                        .background(rating.pick.tint, in: Circle())
                        .padding(5)
                }
                Spacer()
                if item.isFavorite {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.9))
                        .shadow(radius: 2)
                        .padding(6)
                }
            }
            Spacer()
            if showsSelectionBadge {
                HStack {
                    Spacer()
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white, Color.accentColor)
                        .shadow(radius: 2)
                        .padding(6)
                }
            }
        }
    }

    // MARK: - Selection styling

    private var matColor: Color {
        if isFocused { return .accentColor }
        if isSelected { return .accentColor.opacity(0.75) }
        return .clear
    }

    /// The focused cell rings in white so the keyboard cursor stays distinct
    /// from the rest of the selection, which rings in the accent colour.
    private var ringColor: Color {
        if isFocused { return .white }
        if isSelected { return .accentColor }
        return .white.opacity(0.10)
    }

    private var ringWidth: CGFloat {
        if isFocused { return 2.5 }
        if isSelected { return 2 }
        return 1
    }
}
