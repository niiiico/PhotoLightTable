#if os(macOS)
import SwiftUI

/// Full-window single-photo review. Same keys as the grid, so the rhythm of
/// culling doesn't change when you zoom in to check focus.
///
/// Nothing is drawn over the photo. The chrome sits in its own bars above and
/// below, and the verdict frame is separated from the image by the padding
/// around it — when you are judging an image, anything laid on top of it is
/// something you have to mentally subtract.
struct LoupeView: View {
    let items: [PhotoItem]

    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var ratings: RatingStore
    @FocusState private var isFocused: Bool

    @State private var image: PlatformImage?
    @State private var isLoading = false
    @State private var metadata: PhotoMetadata = .empty
    @AppStorage(PreferenceKey.loupeFields) private var fieldsRaw = LoupeFields.defaultValue

    @State private var zoom: CGFloat = 1
    @State private var committedZoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var committedPan: CGSize = .zero

    private static let maxZoom: CGFloat = 8
    private static let doubleClickZoom: CGFloat = 2.5

    private var current: PhotoItem? {
        guard let focusID = app.focusID else { return items.first }
        return items.first { $0.id == focusID } ?? items.first
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            photoArea
            bottomBar
        }
        .background(Color.black)
        .ignoresSafeArea()
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onAppear { isFocused = true }
        .animation(.easeOut(duration: 0.12), value: currentPick)
        .onKeyPress(action: handleKey)
        .task(id: current?.id) {
            resetZoom()
            await loadImage()
        }
        .task(id: current?.id) {
            guard let current else { return }
            metadata = await MetadataLoader.shared.metadata(for: current)
        }
    }

    // MARK: - Photo

    private var photoArea: some View {
        GeometryReader { geo in
            ZStack {
                if let image {
                    Image(platformImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .scaleEffect(zoom)
                        .offset(pan)
                } else if isLoading {
                    ProgressView().controlSize(.large)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .contentShape(Rectangle())
            .gesture(panGesture)
            .simultaneousGesture(magnifyGesture)
            .onTapGesture(count: 2) { toggleZoom() }
        }
        .padding(14)
        // Drawn outside that padding, so the frame never touches the image.
        .overlay {
            if let tint = verdictTint {
                Rectangle().strokeBorder(tint, lineWidth: 4)
            }
        }
    }

    private var panGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                guard zoom > 1 else { return }
                pan = CGSize(width: committedPan.width + value.translation.width,
                             height: committedPan.height + value.translation.height)
            }
            .onEnded { _ in committedPan = pan }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                zoom = min(max(committedZoom * value.magnification, 1), Self.maxZoom)
                if zoom == 1 { pan = .zero }
            }
            .onEnded { _ in
                committedZoom = zoom
                committedPan = pan
            }
    }

    private func setZoom(_ value: CGFloat) {
        zoom = min(max(value, 1), Self.maxZoom)
        committedZoom = zoom
        // Panning is meaningless at fit, and a leftover offset would shift the
        // next photo off-centre.
        if zoom == 1 {
            pan = .zero
            committedPan = .zero
        }
    }

    private func toggleZoom() {
        setZoom(zoom > 1 ? 1 : Self.doubleClickZoom)
    }

    private func resetZoom() {
        zoom = 1
        committedZoom = 1
        pan = .zero
        committedPan = .zero
    }

    // MARK: - Bars

    private var topBar: some View {
        HStack(spacing: 12) {
            if currentPick != .unrated {
                HStack(spacing: 7) {
                    Image(systemName: currentPick.symbolName)
                        .font(.system(size: 14, weight: .bold))
                    Text(currentPick.label.uppercased())
                        .font(.system(size: 13, weight: .heavy))
                        .kerning(0.8)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(currentPick.tint, in: Capsule())
            }

            if let id = current?.id, let color = ratings.rating(for: id).color {
                Circle().fill(color.color).frame(width: 13, height: 13)
            }

            Spacer()

            if zoom > 1 {
                Text("\(Int(zoom * 100))%")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Button("Fit") { setZoom(1) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }

            Button {
                close()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close the loupe (Esc)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var bottomBar: some View {
        let fields = LoupeFields.decode(fieldsRaw)
            .compactMap { field -> (MetadataField, String)? in
                guard let current,
                      let value = field.display(item: current, metadata: metadata) else { return nil }
                return (field, value)
            }

        return HStack(spacing: 14) {
            FlowLayout(spacing: 14) {
                ForEach(fields, id: \.0) { field, value in
                    Text(value)
                        .font(.callout)
                        .foregroundStyle(field == .dateTime ? .primary : .secondary)
                        .help(field.label)
                }
            }

            Spacer(minLength: 8)

            if let current, let index = items.firstIndex(where: { $0.id == current.id }) {
                Text("\(index + 1) of \(items.count)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: - State

    private func close() {
        app.isLoupePresented = false
    }

    private var currentPick: Pick {
        guard let current else { return .unrated }
        return ratings.rating(for: current.id).pick
    }

    private var verdictTint: Color? {
        currentPick == .unrated ? nil : currentPick.tint
    }

    private func loadImage() async {
        guard let current else { return }
        isLoading = true
        defer { isLoading = false }
        image = await ThumbnailLoader.shared.fullImage(for: current, maxDimension: 2400)
    }

    // MARK: - Keyboard

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case .leftArrow:
            app.move(by: -1, in: items, extendSelection: false); return .handled
        case .rightArrow:
            app.move(by: 1, in: items, extendSelection: false); return .handled
        case .escape, .space, .return:
            close()
            return .handled
        default:
            break
        }

        guard let character = press.characters.lowercased().first,
              let focusID = app.focusID else { return .ignored }

        switch character {
        case "p":
            ratings.setPick(.picked, for: [focusID])
            app.move(by: 1, in: items, extendSelection: false)
            return .handled
        case "x":
            ratings.setPick(.rejected, for: [focusID])
            app.move(by: 1, in: items, extendSelection: false)
            return .handled
        case "u":
            ratings.clear([focusID])
            return .handled
        case "z":
            toggleZoom()
            return .handled
        case "+", "=":
            setZoom(zoom * 1.5)
            return .handled
        case "-":
            setZoom(zoom / 1.5)
            return .handled
        default:
            // 6–0 stay colour labels here, as they are in the grid.
            if let color = ColorLabel.forShortcutKey(character) {
                ratings.setColor(color, for: [focusID])
                return .handled
            }
            return .ignored
        }
    }
}
#endif
