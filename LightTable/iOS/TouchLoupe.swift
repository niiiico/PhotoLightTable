#if !os(macOS)
import SwiftUI

/// Full-screen review, where the culling actually happens on touch.
///
/// A verdict is a swipe: up to pick, down to reject. That is the whole point of
/// the app on a device with no keyboard — the hand stays on the photo, and a
/// judgement costs one movement rather than a trip to a button.
struct TouchLoupe: View {
    let items: [PhotoItem]

    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var ratings: RatingStore
    @Environment(\.dismiss) private var dismiss

    @State private var image: PlatformImage?
    @State private var isLoading = false
    @State private var drag: CGSize = .zero
    @State private var showsChrome = true
    @State private var isEditing = false

    /// How far a swipe has to travel to count, so a nudge while panning doesn't
    /// silently rate a photo.
    private let verdictThreshold: CGFloat = 90

    private var current: PhotoItem? {
        guard let focusID = app.focusID else { return items.first }
        return items.first { $0.id == focusID } ?? items.first
    }

    var body: some View {
        if isEditing, let current {
            TouchEditor(item: current, onFinished: {
                isEditing = false
                Task { await load() }
            }, onOpenVersion: { assetID in
                guard items.contains(where: { $0.id == assetID }) else { return }
                app.focusID = assetID
            })
        } else {
            review
        }
    }

    private var review: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if current?.isHidden == true {
                // Said here too: on touch there is no menu to explain it, and a
                // black screen with nothing on it reads as a fault.
                VStack(spacing: 12) {
                    Image(systemName: "eye.slash")
                        .font(.system(size: 30, weight: .light))
                    Text("Hidden in Photos")
                        .font(.system(size: 15, weight: .medium))
                    Text("Unhide it in Photos to see it here.")
                        .font(.system(size: 12))
                }
                .foregroundStyle(.white.opacity(0.5))
            } else if let image {
                Image(platformImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .offset(drag)
                    .scaleEffect(1 - min(abs(drag.height) / 1200, 0.08))
            } else if isLoading {
                ProgressView().controlSize(.large).tint(.white)
            }

            verdictHint

            if showsChrome {
                chrome.transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .gesture(swipe)
        .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { showsChrome.toggle() } }
        .statusBarHidden()
        .task(id: current?.id) { await load() }
    }

    // MARK: - Swipe

    private var swipe: some Gesture {
        DragGesture()
            .onChanged { drag = $0.translation }
            .onEnded { value in
                let horizontal = value.translation.width
                let vertical = value.translation.height

                // Whichever axis travelled further decides what the gesture
                // meant, so a diagonal doesn't both rate and navigate.
                if abs(horizontal) > abs(vertical) {
                    if abs(horizontal) > verdictThreshold {
                        move(by: horizontal < 0 ? 1 : -1)
                    }
                } else if abs(vertical) > verdictThreshold {
                    verdict(vertical < 0 ? .picked : .rejected)
                }
                withAnimation(.spring(duration: 0.25)) { drag = .zero }
            }
    }

    /// Shows what the swipe in progress would do, so the gesture is discoverable
    /// by trying it rather than by being told.
    @ViewBuilder
    private var verdictHint: some View {
        let vertical = drag.height
        if abs(vertical) > abs(drag.width), abs(vertical) > 20 {
            let pick: Pick = vertical < 0 ? .picked : .rejected
            let progress = min(abs(vertical) / verdictThreshold, 1)

            VStack {
                if pick == .rejected { Spacer() }
                Label(pick.label.uppercased(), systemImage: pick.symbolName)
                    .font(.headline.weight(.heavy))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(pick.tint.opacity(0.85), in: Capsule())
                    .scaleEffect(0.85 + progress * 0.15)
                    .opacity(progress)
                if pick == .picked { Spacer() }
            }
            .padding(.vertical, 70)
            .allowsHitTesting(false)
        }
    }

    private func verdict(_ pick: Pick) {
        guard let current else { return }
        ratings.setPick(pick, for: [current.id])
        move(by: 1)
    }

    private func move(by offset: Int) {
        app.move(by: offset, in: items, extendSelection: false)
    }

    // MARK: - Chrome

    private var chrome: some View {
        VStack {
            HStack {
                if let current {
                    let rating = ratings.rating(for: current.id)
                    if rating.pick != .unrated {
                        Label(rating.pick.label, systemImage: rating.pick.symbolName)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(rating.pick.tint, in: Capsule())
                    }
                    if let color = rating.color {
                        Circle().fill(color.color).frame(width: 12, height: 12)
                    }
                }

                Spacer()

                if let current, let index = items.firstIndex(where: { $0.id == current.id }) {
                    Text("\(index + 1) of \(items.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.8))
                }

                Button { isEditing = true } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.trailing, 6)
                }
                .accessibilityLabel("Edit")

                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)

            Spacer()

            // The same verdicts as buttons: swiping is quicker once known, and
            // invisible until then.
            HStack(spacing: 14) {
                verdictButton(.picked)
                verdictButton(.rejected)
                verdictButton(.unrated)

                Menu {
                    ForEach(ColorLabel.allCases) { color in
                        Button(color.label) { setColor(color) }
                    }
                    Button("No Colour") { setColor(nil) }
                } label: {
                    Image(systemName: "paintpalette")
                        .font(.title3)
                        .frame(width: 52, height: 44)
                        .background(.ultraThinMaterial, in: Capsule())
                }
            }
            .padding(.bottom, 24)
        }
    }

    private func verdictButton(_ pick: Pick) -> some View {
        Button {
            guard let current else { return }
            if pick == .unrated {
                ratings.clear([current.id])
            } else {
                ratings.setPick(pick, for: [current.id])
            }
        } label: {
            Image(systemName: pick.chipSymbolName)
                .font(.title3.weight(.semibold))
                .foregroundStyle(pick == .unrated ? Color.secondary : pick.tint)
                .frame(width: 52, height: 44)
                .background(.ultraThinMaterial, in: Capsule())
        }
    }

    private func setColor(_ color: ColorLabel?) {
        guard let current else { return }
        ratings.setColor(color, for: [current.id])
    }

    private func load() async {
        guard let current else { return }
        isLoading = true
        defer { isLoading = false }
        guard !current.isHidden else {
            image = nil
            isLoading = false
            return
        }
        for await next in ThumbnailLoader.shared.fullImages(for: current, maxDimension: 2400) {
            image = next
        }
    }
}
#endif
