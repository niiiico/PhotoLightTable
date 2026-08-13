import SwiftUI

struct ThumbnailCell: View, Equatable {
    let item: PhotoItem
    let size: CGFloat
    let rating: RatingValue
    let isSelected: Bool
    let isFocused: Bool
    /// Only set during a genuine multi-selection — a checkmark on every cell you
    /// arrow through would be noise.
    let showsSelectionBadge: Bool
    /// Changes when the asset's pixels change under a stable identifier, which
    /// is what makes an edited photo reload rather than serve its old cache
    /// entry — and what lets `.equatable()` see that this cell is now different.
    let imageVersion: Int
    /// Non-nil when this photo is an alternative treatment of another.
    var variantLabel: String? = nil
    /// How many photos share this one's pixels, counting itself. Anything above
    /// one draws as a stack; zero and one are the ordinary case.
    var stackCount: Int = 0
    /// Whether the family this photo stands for is opened out in the grid. An
    /// open stack keeps its badge — that is what closes it again — but drops
    /// the pile, since the other photos are on the table beside it.
    var isStackExpanded: Bool = false
    var onToggleStack: (() -> Void)? = nil

    private var isStack: Bool { stackCount > 1 }

    @State private var image: PlatformImage?
    @AppStorage(PreferenceKeys.thumbnailFillMode) private var fillModeRaw = ThumbnailFillMode.fill.rawValue

    private var fillMode: ThumbnailFillMode {
        ThumbnailFillMode(rawValue: fillModeRaw) ?? .fill
    }

    private var isActive: Bool { isSelected || isFocused }

    /// Selected cells inset their image to reveal a coloured mat behind it.
    /// Shrinking the photo is what makes selection readable at a glance, in a
    /// way a border drawn over a busy photo never is.
    private var matInset: CGFloat { isActive ? 6 : 0 }

    /// A closed stack shows two cards peeking out behind the photo, offset down
    /// and right. An open one drops them: its members are on the table beside
    /// it, so a pile behind the first would be claiming them twice.
    private var showsPile: Bool { isStack && !isStackExpanded }

    /// Scaled with the cell, so the pile still reads at a small thumbnail size
    /// without swallowing a large one.
    private var pileOffset: CGFloat { showsPile ? max(3, min(7, size * 0.038)) : 0 }

    /// The photo gives up room for the pile rather than overflowing the cell,
    /// which would otherwise collide with its neighbours in the grid.
    private var contentSize: CGFloat { size - matInset * 2 - pileOffset * 2 }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(matColor)

            ZStack {
                if showsPile {
                    pileCard(shift: pileOffset, opacity: 0.22)
                    pileCard(shift: 0, opacity: 0.4)
                }

                photo
                    .frame(width: contentSize, height: contentSize)
                    .offset(x: -pileOffset, y: -pileOffset)
            }
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
        .task(id: "\(item.id)#\(fillModeRaw)#\(imageVersion)") {
            // Referenced directly rather than held in a @StateObject: the
            // loader is shared, so wrapping it per cell made every thumbnail
            // observe it for no benefit.
            image = await ThumbnailLoader.shared.thumbnail(for: item,
                                           size: CGSize(width: size, height: size),
                                           mode: fillMode)
        }
    }

    // MARK: - Stack

    private func pileCard(shift: CGFloat, opacity: Double) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Color.white.opacity(opacity))
            .overlay {
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(.black.opacity(0.25), lineWidth: 0.5)
            }
            .frame(width: contentSize, height: contentSize)
            .offset(x: shift, y: shift)
    }

    /// The count is the control: there is nowhere else to put a disclosure that
    /// would not be another thing drawn over the photograph.
    private var stackBadge: some View {
        Button {
            onToggleStack?()
        } label: {
            HStack(spacing: 3) {
                Image(systemName: isStackExpanded ? "rectangle.stack.fill" : "rectangle.stack")
                Text("\(stackCount)")
            }
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.black.opacity(0.6), in: Capsule())
        }
        .buttonStyle(.plain)
        .padding(6)
        .help(isStackExpanded
              ? "Stack these versions back together"
              : "Show all \(stackCount) versions of this photo")
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
                    .frame(width: contentSize, height: contentSize)
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
            if let variantLabel {
                HStack {
                    Text(variantLabel)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.55), in: Capsule())
                        .padding(.leading, 5)
                    Spacer()
                }
                .padding(.top, 2)
            }

            Spacer()
            HStack {
                if isStack { stackBadge }
                Spacer()
                if showsSelectionBadge {
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

    /// Selecting one photo re-renders the parent, which hands every visible cell
    /// a fresh value. Without this, all of them rebuild — including decoding
    /// their image view — when only one changed.
    static func == (lhs: ThumbnailCell, rhs: ThumbnailCell) -> Bool {
        lhs.item.id == rhs.item.id
            && lhs.size == rhs.size
            && lhs.rating == rhs.rating
            && lhs.isSelected == rhs.isSelected
            && lhs.isFocused == rhs.isFocused
            && lhs.showsSelectionBadge == rhs.showsSelectionBadge
            && lhs.imageVersion == rhs.imageVersion
            && lhs.variantLabel == rhs.variantLabel
            && lhs.stackCount == rhs.stackCount
            && lhs.isStackExpanded == rhs.isStackExpanded
    }
}
