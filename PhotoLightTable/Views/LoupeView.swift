import AppKit
import SwiftUI

/// Full-screen single-photo review. Same keys as the grid, so the rhythm of
/// culling doesn't change when you zoom in to check focus.
struct LoupeView: View {
    let items: [PhotoItem]

    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var ratings: RatingStore
    @FocusState private var isFocused: Bool

    @State private var image: NSImage?
    @State private var isLoading = false
    @State private var metadata: PhotoMetadata = .empty
    @AppStorage(PreferenceKey.loupeFields) private var fieldsRaw = LoupeFields.defaultValue

    private var current: PhotoItem? {
        guard let focusID = app.focusID else { return items.first }
        return items.first { $0.id == focusID } ?? items.first
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    // The verdict frames the photo itself, so it can't be missed
                    // while your eye is on the image rather than the info bar.
                    .overlay {
                        if let tint = verdictTint {
                            Rectangle().strokeBorder(tint, lineWidth: 5)
                        }
                    }
                    .padding(24)
            } else if isLoading {
                ProgressView().controlSize(.large)
            }

            VStack {
                HStack {
                    verdictBadge
                    Spacer()
                    Button {
                        close()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                    .padding(20)
                    .help("Close the loupe (Esc)")
                }
                Spacer()
                if let current { infoBar(for: current) }
            }
        }
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onAppear { isFocused = true }
        .animation(.easeOut(duration: 0.12), value: currentPick)
        .onKeyPress(action: handleKey)
        .task(id: current?.id) { await loadImage() }
        .task(id: current?.id) {
            guard let current else { return }
            metadata = await MetadataLoader.shared.metadata(for: current)
        }
    }

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

    @ViewBuilder
    private var verdictBadge: some View {
        if currentPick != .unrated {
            HStack(spacing: 7) {
                Image(systemName: currentPick.symbolName)
                    .font(.system(size: 15, weight: .bold))
                Text(currentPick.label.uppercased())
                    .font(.system(size: 14, weight: .heavy))
                    .kerning(0.8)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(currentPick.tint, in: Capsule())
            .shadow(radius: 6)
            .padding(20)
            .transition(.opacity.combined(with: .scale))
        }
    }

    private func infoBar(for item: PhotoItem) -> some View {
        let rating = ratings.rating(for: item.id)
        let fields = LoupeFields.decode(fieldsRaw)
            .compactMap { field -> (MetadataField, String)? in
                guard let value = field.display(item: item, metadata: metadata) else { return nil }
                return (field, value)
            }

        return HStack(spacing: 14) {
            // Wraps rather than truncating, so switching on every field degrades
            // to two lines instead of hiding the ones at the end.
            FlowLayout(spacing: 14) {
                ForEach(fields, id: \.0) { field, value in
                    Text(value)
                        .font(.callout)
                        .foregroundStyle(field == .dateTime ? .primary : .secondary)
                        .help(field.label)
                }
            }

            Spacer(minLength: 8)

            if rating.pick != .unrated {
                Label(rating.pick.label, systemImage: rating.pick.symbolName)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(rating.pick.tint)
            }
            if let color = rating.color {
                Circle()
                    .fill(color.color)
                    .frame(width: 12, height: 12)
            }
            if let index = items.firstIndex(where: { $0.id == item.id }) {
                Text("\(index + 1) of \(items.count)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding(20)
    }

    private func loadImage() async {
        guard let current else { return }
        isLoading = true
        defer { isLoading = false }
        image = await ThumbnailLoader.shared.fullImage(for: current, maxDimension: 2400)
    }

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
        default:
            if let color = ColorLabel.forShortcutKey(character) {
                ratings.setColor(color, for: [focusID])
                return .handled
            }
            return .ignored
        }
    }
}
