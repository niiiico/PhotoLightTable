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
    @AppStorage(PreferenceKeys.loupeFields) private var fieldsRaw = LoupeFields.defaultValue

    @StateObject private var zoomState = LoupeZoom()
    @StateObject private var edit = PhotoEditSession()
    @State private var isEditing = false
    @State private var showsHistory = false
    @Environment(\.modelContext) private var modelContext

    private var current: PhotoItem? {
        guard let focusID = app.focusID else { return items.first }
        return items.first { $0.id == focusID } ?? items.first
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            photoArea
            if isEditing { editBar } else { bottomBar }
        }
        .background(Color.black)
        .ignoresSafeArea()
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onAppear {
            isFocused = true
            zoomState.startMonitoringScroll()
        }
        .onDisappear { zoomState.stopMonitoringScroll() }
        .animation(.easeOut(duration: 0.12), value: currentPick)
        .onKeyPress(action: handleKey)
        .task(id: current?.id) {
            if isEditing { endEditing() }
            zoomState.reset()
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
                if let image = isEditing ? (edit.preview ?? image) : image {
                    Image(platformImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .scaleEffect(zoomState.zoom)
                        .offset(zoomState.pan)
                } else if isLoading {
                    ProgressView().controlSize(.large)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .contentShape(Rectangle())
            .gesture(panGesture)
            .simultaneousGesture(magnifyGesture)
            .onTapGesture(count: 2) { zoomState.toggle() }
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
            .onChanged { zoomState.dragTo($0.translation) }
            .onEnded { _ in zoomState.endDrag() }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { zoomState.magnify($0.magnification) }
            .onEnded { _ in zoomState.endMagnify() }
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

            if zoomState.isZoomed {
                Text("\(Int(zoomState.zoom * 100))%")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Button("Fit") { zoomState.reset() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }

            if !isEditing {
                Button {
                    Task { await beginEditing() }
                } label: {
                    Label("Edit", systemImage: "slider.horizontal.3")
                        .labelStyle(.iconOnly)
                        .font(.title3)
                        .foregroundStyle(edit.hasExistingEdit ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .help("Adjust this photo (E)")
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

    /// Each value is a menu: clicking it swaps that slot for another field.
    /// Arranging the bar where you read it beats a checklist in Settings, so
    /// there is no longer a Settings pane for this.
    private var bottomBar: some View {
        let fields = LoupeFields.decode(fieldsRaw)
        let unused = MetadataField.allCases.filter { !fields.contains($0) }

        return HStack(spacing: 14) {
            FlowLayout(spacing: 14) {
                ForEach(Array(fields.enumerated()), id: \.element) { index, field in
                    fieldSlot(field, at: index)
                }

                if !unused.isEmpty {
                    Menu {
                        ForEach(unused) { field in
                            Button(field.label) { setFields(fields + [field]) }
                        }
                    } label: {
                        Image(systemName: "plus.circle")
                            .foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Show another field")
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

    private func fieldSlot(_ field: MetadataField, at index: Int) -> some View {
        let fields = LoupeFields.decode(fieldsRaw)
        let value = current.flatMap { field.display(item: $0, metadata: metadata) }

        return Menu {
            ForEach(MetadataField.allCases) { candidate in
                Button {
                    var updated = fields
                    // Swapping in a field that's already shown elsewhere would
                    // duplicate it, so the two slots trade places instead.
                    if let existing = updated.firstIndex(of: candidate) {
                        updated.swapAt(index, existing)
                    } else {
                        updated[index] = candidate
                    }
                    setFields(updated)
                } label: {
                    if candidate == field {
                        Label(candidate.label, systemImage: "checkmark")
                    } else {
                        Text(candidate.label)
                    }
                }
            }
            Divider()
            Button("Remove", role: .destructive) {
                var updated = fields
                updated.remove(at: index)
                setFields(updated)
            }
        } label: {
            // A slot the photo has no value for still shows, so it stays
            // clickable and the bar doesn't reshuffle between images.
            Text(value ?? "—")
                .font(.callout)
                .foregroundStyle(value == nil ? .tertiary
                                 : (field == .dateTime ? .primary : .secondary))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("\(field.label) — click to change")
    }

    private func setFields(_ fields: [MetadataField]) {
        fieldsRaw = LoupeFields.encode(fields)
    }

    // MARK: - Editing

    private var editBar: some View {
        HStack(spacing: 14) {
            Label("Exposure", systemImage: "plusminus.circle")
                .labelStyle(.titleOnly)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize()

            Slider(value: Binding(
                get: { edit.recipe.exposure },
                set: { edit.recipe.exposure = $0; edit.renderPreview() }
            ), in: -3...3, step: 0.05)
            .frame(minWidth: 180)

            Text(String(format: "%+.2f EV", edit.recipe.exposure))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()

            Button("Reset") {
                edit.recipe = .neutral
                edit.renderPreview()
            }
            .disabled(edit.recipe.isNeutral)

            Divider().frame(height: 16)

            if edit.hasExistingEdit {
                Button("Revert to Original") {
                    Task {
                        try? await edit.revert(for: current!)
                        await reloadAfterEdit()
                    }
                }
                .help("Discards every edit, including ones made in other apps")
            }

            Button {
                showsHistory.toggle()
            } label: {
                Label("History", systemImage: "clock.arrow.circlepath")
                    .labelStyle(.iconOnly)
            }
            .help("Earlier versions of this photo")
            .popover(isPresented: $showsHistory, arrowEdge: .top) {
                historyPopover
            }

            Button("Cancel") { endEditing() }

            Button("Apply") {
                Task {
                    guard let current else { return }
                    try? await edit.commit(for: current)
                    await reloadAfterEdit()
                    endEditing()
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!edit.isDirty || edit.isCommitting)

            if edit.isCommitting { ProgressView().controlSize(.small) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var historyPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Version History")
                .font(.headline)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 8)

            if edit.history.isEmpty {
                Text("No edits recorded for this photo yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(edit.history.enumerated()), id: \.element.persistentModelID) { index, version in
                            historyRow(version, isCurrent: index == 0)
                            if version !== edit.history.last { Divider() }
                        }
                    }
                }
                .frame(maxHeight: 260)

                Divider()
                Button("Clear History", role: .destructive) {
                    guard let current else { return }
                    edit.clearHistory(for: current)
                }
                .buttonStyle(.plain)
                .font(.callout)
                .foregroundStyle(.red)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
        }
        .frame(width: 280)
    }

    private func historyRow(_ version: PhotoEditVersion, isCurrent: Bool) -> some View {
        Button {
            guard let current else { return }
            Task {
                try? await edit.restore(version, for: current)
                await reloadAfterEdit()
                showsHistory = false
            }
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(version.recipe?.summary ?? "Unreadable")
                        .font(.callout.weight(isCurrent ? .semibold : .regular))
                    Text(version.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isCurrent {
                    Text("Current")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        }
        .buttonStyle(.plain)
        .disabled(isCurrent)
    }

    private func beginEditing() async {
        guard let current else { return }
        isEditing = true
        zoomState.reset()
        edit.modelContext = modelContext
        await edit.begin(for: current)
        if !edit.canEdit { isEditing = false }
    }

    private func endEditing() {
        isEditing = false
        edit.cancel()
    }

    /// The committed render replaces the asset's image, so the copy on screen —
    /// and the thumbnail cache behind it — are both stale.
    private func reloadAfterEdit() async {
        guard let current else { return }
        ThumbnailLoader.shared.forget(current)
        await loadImage()
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
        case .escape:
            if isEditing { endEditing() } else { close() }
            return .handled
        case .space, .return:
            guard !isEditing else { return .ignored }
            close()
            return .handled
        default:
            break
        }

        guard let character = press.characters.lowercased().first,
              let focusID = app.focusID else { return .ignored }

        if character == "e" {
            if isEditing { endEditing() } else { Task { await beginEditing() } }
            return .handled
        }

        // While editing, the digits and verdict keys belong to the panel's
        // controls rather than to rating.
        guard !isEditing else { return .ignored }

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
            zoomState.toggle()
            return .handled
        case "+", "=":
            zoomState.set(zoomState.zoom * 1.5)
            return .handled
        case "-":
            zoomState.set(zoomState.zoom / 1.5)
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
