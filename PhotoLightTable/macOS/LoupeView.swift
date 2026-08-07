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
    @EnvironmentObject private var library: PhotoLibraryService
    @FocusState private var isFocused: Bool

    @State private var image: PlatformImage?
    @State private var isLoading = false
    @State private var metadata: PhotoMetadata = .empty
    @AppStorage(PreferenceKeys.loupeFields) private var fieldsRaw = LoupeFields.defaultValue

    @StateObject private var zoomState = LoupeZoom()
    @StateObject private var edit = PhotoEditSession()
    @State private var isEditing = false
    @State private var showsHistory = false
    @State private var editError: String?
    @State private var variantLabel: String?
    @State private var isCropping = false
    @State private var cropAspect: CropAspect = .free
    @State private var selectedMaskID: UUID?
    @State private var isPickingWhitePoint = false
    @State private var comparison: ComparisonMode = .off
    @State private var splitPosition: Double = 0.5
    @State private var brushRadius: Double = BrushStroke.defaultRadius
    @State private var isErasing = false
    @Environment(\.modelContext) private var modelContext

    private var current: PhotoItem? {
        guard let focusID = app.focusID else { return items.first }
        return items.first { $0.id == focusID } ?? items.first
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                topBar
                photoArea
                // Metadata stays put while editing: aperture and shutter are
                // part of judging an adjustment, not something to swap out for
                // the controls.
                bottomBar
            }

            if isEditing {
                Divider()
                editPanel
            }
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
        .alert("Save as a new photo",
               isPresented: Binding(get: { variantLabel != nil },
                                    set: { if !$0 { variantLabel = nil } })) {
            TextField("Name", text: Binding(
                get: { variantLabel ?? "" },
                set: { variantLabel = $0 }))
            Button("Cancel", role: .cancel) { variantLabel = nil }
            Button("Save") { saveVariant() }
        } message: {
            Text("The original keeps its own edits. This treatment is added to your library as a separate photo, alongside it.")
        }
        .animation(.easeOut(duration: 0.12), value: currentPick)
        .onKeyPress(action: handleKey)
        .task(id: current?.id) {
            zoomState.reset()
            await loadImage()
            // Editing stays on across photos, so a run of frames can be worked
            // through without leaving and re-entering the panel each time.
            if isEditing, let current {
                selectedMaskID = nil
                comparison = .off
                isPickingWhitePoint = false
                edit.wantsBeforePreview = false
                await edit.begin(for: current)
                renderForCurrentTool()
            }
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
                if comparison.isActive,
                   let before = edit.beforePreview,
                   let after = edit.preview {
                    ComparisonView(before: before, after: after,
                                   mode: comparison,
                                   splitPosition: $splitPosition)
                } else if let image = isEditing ? (edit.preview ?? image) : image {
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
            .overlay {
                if isPickingWhitePoint, let displayed = edit.preview ?? image {
                    WhitePointPicker(
                        imageAspect: displayed.size.height > 0
                            ? displayed.size.width / displayed.size.height : 1,
                        onPick: { point in
                            let target: PhotoEditSession.MaskTarget =
                                selectedMaskID.map { .mask($0) } ?? .whole
                            if !edit.sampleWhitePoint(at: point, into: target) {
                                editError = "That area is too dark to balance from — try a lighter neutral."
                            }
                            isPickingWhitePoint = false
                        },
                        onCancel: { isPickingWhitePoint = false })
                }
            }
            .overlay {
                if !isCropping, selectedMaskID != nil, !edit.recipe.crop.isFull,
                   let displayed = edit.preview ?? image {
                    CropBoundsIndicator(
                        crop: edit.recipe.crop,
                        imageAspect: displayed.size.height > 0
                            ? displayed.size.width / displayed.size.height : 1)
                }
            }
            .overlay {
                if !isCropping, let displayed = edit.preview ?? image,
                   let selected = selectedMask {
                    let aspect = displayed.size.height > 0
                        ? displayed.size.width / displayed.size.height : 1

                    if selected.kind == .brush {
                        BrushOverlay(mask: maskBinding(selected.id),
                                     imageAspect: aspect,
                                     brushRadius: brushRadius,
                                     isErasing: isErasing,
                                     showsPaint: true,
                                     softness: selected.softness)
                    } else {
                        MaskOverlay(mask: maskBinding(selected.id), imageAspect: aspect)
                    }
                }
            }
            .overlay {
                if isCropping, let displayed = edit.preview ?? image {
                    CropOverlay(crop: Binding(
                        get: { edit.recipe.crop },
                        set: { edit.recipe.crop = $0 }
                    ),
                    imageAspect: displayed.size.height > 0
                        ? displayed.size.width / displayed.size.height : 1,
                    aspect: cropAspect)
                }
            }
            // Zoom and pan would fight the handles for the same drags.
            .gesture(handlesAreActive ? nil : panGesture)
            .simultaneousGesture(handlesAreActive ? nil : magnifyGesture)
            .onTapGesture(count: 2) { if !handlesAreActive { zoomState.toggle() } }
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

            if isEditing {
                Menu {
                    ForEach(ComparisonMode.allCases) { mode in
                        Button {
                            setComparison(mode)
                        } label: {
                            Label(mode.label, systemImage: mode.symbolName)
                        }
                    }
                } label: {
                    Label("Compare", systemImage: comparison.symbolName)
                        .labelStyle(.iconOnly)
                        .foregroundStyle(comparison.isActive ? Color.accentColor : .secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(!edit.hasVisibleChange)
                .help(edit.hasVisibleChange
                      ? "Compare with how it was (\\)"
                      : "Nothing has changed to compare yet")
            }

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

    /// One panel for the whole session, down the side rather than across the
    /// bottom: a vertical stack gives each slider its full width, and it leaves
    /// the photo the whole height of the window.
    ///
    /// Crop is a tool whose handles toggle rather than a mode with its own
    /// confirmation. Every change accumulates in the recipe, and the session is
    /// written once, at the end.
    private var editPanel: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let current {
                        VersionsStrip(family: ratings.family(of: current.id),
                                      currentID: current.id,
                                      label: { ratings.variantLabel(for: $0) },
                                      onSelect: { openVersion($0) })
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        sectionHeading(selectedMask == nil ? "Adjust" : "Adjust Mask",
                                       isReset: activeTone.isNeutral && activeTone.whitePoint == nil) {
                            for adjustment in Adjustment.allCases { setTone(adjustment, 0) }
                            setWhitePoint(nil)
                            renderForCurrentTool()
                        }
                        whiteBalanceRow
                        ForEach(Adjustment.allCases) { adjustmentSlider($0) }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Masks")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Menu {
                                Button("Linear Gradient") { addMask(.linear) }
                                Button("Radial Gradient") { addMask(.radial) }
                                Button("Brush") { addMask(.brush) }
                            } label: {
                                Image(systemName: "plus")
                            }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .fixedSize()
                        }

                        if edit.recipe.masks.isEmpty {
                            Text("Add a gradient to adjust part of the photo.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(edit.recipe.masks) { mask in
                                maskRow(mask)
                            }

                            if let selected = selectedMask, selected.kind == .brush {
                                brushControls(selected.id)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        sectionHeading("Crop", isReset: edit.recipe.crop.isFull) {
                            edit.recipe.crop = .full
                            renderForCurrentTool()
                        }

                        Toggle(isOn: Binding(get: { isCropping }, set: { setCropping($0) })) {
                            Label("Show crop handles", systemImage: "crop")
                        }
                        .toggleStyle(.button)
                        .help("Crop this photo (C)")

                        if isCropping {
                            Picker("Aspect", selection: $cropAspect) {
                                ForEach(CropAspect.allCases) { option in
                                    Text(option.label).tag(option)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                        }
                    }
                }
                .padding(16)
            }

            Divider()
            editFooter
        }
        .frame(width: 300)
        .background(.bar)
    }

    private func sectionHeading(_ title: String,
                                isReset: Bool,
                                reset: @escaping () -> Void) -> some View {
        HStack {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Spacer()
            Button("Reset", action: reset)
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
                .disabled(isReset)
                .opacity(isReset ? 0.4 : 1)
        }
    }

    private var editFooter: some View {
        VStack(spacing: 10) {
            if let editError {
                Label(editError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 8) {
                Button {
                    showsHistory.toggle()
                } label: {
                    Label("History", systemImage: "clock.arrow.circlepath")
                        .labelStyle(.iconOnly)
                }
                .help("Earlier versions of this photo")
                .popover(isPresented: $showsHistory, arrowEdge: .leading) { historyPopover }

                if edit.hasExistingEdit {
                    Button {
                        guard let current else { return }
                        Task {
                            do {
                                try await edit.revert(for: current)
                                await reloadAfterEdit()
                            } catch { editError = error.localizedDescription }
                        }
                    } label: {
                        Label("Revert", systemImage: "arrow.uturn.backward")
                            .labelStyle(.iconOnly)
                    }
                    .help("Revert to original — discards every edit, including other apps'")
                }

                if edit.isCommitting { ProgressView().controlSize(.small) }

                Spacer()

                Menu {
                    Button("Save as New Photo…") {
                        variantLabel = edit.recipe.suggestedVariantLabel
                    }
                    .disabled(edit.recipe.isNeutral)

                    Divider()

                    Button("Split into Left and Right") { splitLeftRight() }
                } label: {
                    Label("New Photo", systemImage: "plus.rectangle.on.rectangle")
                        .labelStyle(.iconOnly)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Add a copy of this photo to your library, leaving the original as it is")
                .disabled(edit.isCommitting)

                Button("Cancel") { endEditing(commit: false) }

                Button(edit.isDirty ? "Save" : "Done") { endEditing(commit: true) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(edit.isCommitting)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
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
                do {
                    try await edit.restore(version, for: current)
                    await reloadAfterEdit()
                } catch { editError = error.localizedDescription }
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
        renderForCurrentTool()
    }

    /// Double-click the label to return one adjustment to neutral, which is
    /// quicker than dragging a slider back to exactly zero.
    private func adjustmentSlider(_ adjustment: Adjustment) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Text(adjustment.label)
                    .font(.caption)
                    .foregroundStyle(activeTone[adjustment] == 0 ? .secondary : .primary)
                Spacer()
                Text(adjustment.formatted(activeTone[adjustment]))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                // Shown only when there is something to undo, so a row at
                // neutral stays quiet.
                Button {
                    setTone(adjustment, 0)
                    renderForCurrentTool()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 8, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .opacity(activeTone[adjustment] == 0 ? 0 : 1)
                .disabled(activeTone[adjustment] == 0)
                .help("Reset \(adjustment.label)")
            }
            // The label is only a label. Resetting lives on the control, where
            // the pointer already is, and a double-click on a caption is easy to
            // trigger while trying to read the value.
            .help(adjustment.explanation.map { "\(adjustment.label) — \($0)" }
                  ?? adjustment.label)

            Slider(value: Binding(
                get: { activeTone[adjustment] },
                set: { setTone(adjustment, $0); renderForCurrentTool() }
            ), in: adjustment.range)
            .controlSize(.small)
            .onDoubleClick {
                setTone(adjustment, 0)
                renderForCurrentTool()
            }
            .help("Double-click to reset")
        }
    }

    // MARK: - Masks

    private var selectedMask: EditMask? {
        guard let selectedMaskID else { return nil }
        return edit.recipe.masks.first { $0.id == selectedMaskID }
    }

    /// Masks are addressed by identity rather than position.
    ///
    /// A binding that captures an index reads a stale slot the moment the array
    /// changes underneath it — which is what saving does, since committing
    /// resets the recipe while the overlay is still on screen. That crashed with
    /// an out-of-range access rather than degrading.
    private func maskBinding(_ id: UUID) -> Binding<EditMask> {
        Binding(
            get: { edit.recipe.masks.first { $0.id == id } ?? EditMask() },
            set: { newValue in
                guard let index = edit.recipe.masks.firstIndex(where: { $0.id == id }) else { return }
                edit.recipe.masks[index] = newValue
                renderForCurrentTool()
            })
    }

    private func updateMask(_ id: UUID, _ change: (inout EditMask) -> Void) {
        guard let index = edit.recipe.masks.firstIndex(where: { $0.id == id }) else { return }
        change(&edit.recipe.masks[index])
        renderForCurrentTool()
    }

    /// The sliders edit whichever tone is in focus — the whole image, or the
    /// selected mask. One set of controls, one meaning at a time.
    private var activeTone: ToneAdjustments {
        selectedMask?.tone ?? edit.recipe.tone
    }

    private func setTone(_ adjustment: Adjustment, _ value: Double) {
        if let id = selectedMaskID, edit.recipe.masks.contains(where: { $0.id == id }) {
            updateMask(id) { $0.tone[adjustment] = value }
        } else {
            edit.recipe.tone[adjustment] = value
        }
    }

    private func addMask(_ kind: EditMask.Kind) {
        var mask = EditMask()
        mask.kind = kind
        if kind == .radial {
            mask.start = EditPoint(x: 0.5, y: 0.5)
            mask.end = EditPoint(x: 0.78, y: 0.5)
        }
        if kind == .brush { isErasing = false }
        edit.recipe.masks.append(mask)
        // Cropping and mask placement both want the pointer, so adding a mask
        // puts the crop handles away.
        isCropping = false
        selectMask(mask.id)
    }

    private func maskRow(_ mask: EditMask) -> some View {
        let isSelected = mask.id == selectedMaskID
        return HStack(spacing: 8) {
            Button {
                updateMask(mask.id) { $0.isEnabled.toggle() }
            } label: {
                Image(systemName: mask.isEnabled ? "eye" : "eye.slash")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(mask.isEnabled ? "Hide this mask" : "Show this mask")

            VStack(alignment: .leading, spacing: 1) {
                Text(mask.name)
                    .font(.caption.weight(isSelected ? .semibold : .regular))
                Text(mask.tone.isNeutral ? "No adjustments" : mask.tone.summary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Menu {
                Button(mask.isInverted ? "Uninvert" : "Invert") {
                    updateMask(mask.id) { $0.isInverted.toggle() }
                }
                Divider()
                Button("Delete", role: .destructive) {
                    edit.recipe.masks.removeAll { $0.id == mask.id }
                    if selectedMaskID == mask.id { selectMask(nil) } else { renderForCurrentTool() }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor.opacity(0.18) : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { selectMask(isSelected ? nil : mask.id) }
    }

    @ViewBuilder
    private func brushControls(_ id: UUID) -> some View {
        let mask = edit.recipe.masks.first { $0.id == id } ?? EditMask()
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: $isErasing) {
                Text("Paint").tag(false)
                Text("Erase").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            VStack(alignment: .leading, spacing: 1) {
                HStack {
                    Text("Size").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(brushRadius * 200))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: $brushRadius, in: 0.01...0.3)
                    .controlSize(.small)
                    .onDoubleClick { brushRadius = BrushStroke.defaultRadius }
                    .help("Double-click to reset")
            }

            VStack(alignment: .leading, spacing: 1) {
                HStack {
                    Text("Softness").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(mask.softness * 100))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: Binding(
                    get: { mask.softness },
                    set: { value in updateMask(id) { $0.softness = value } }
                ), in: 0...1)
                .controlSize(.small)
                .onDoubleClick {
                    updateMask(id) { $0.softness = EditMask.defaultSoftness }
                }
                .help("Double-click to reset")
            }

            Button("Clear Strokes") {
                updateMask(id) { $0.strokes = [] }
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)
            .disabled(mask.strokes.isEmpty)
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
    }

    private var whiteBalanceRow: some View {
        HStack(spacing: 6) {
            Button {
                isPickingWhitePoint.toggle()
                if isPickingWhitePoint {
                    // The picker needs the click the other overlays would take.
                    zoomState.reset()
                    isCropping = false
                    if comparison.isActive { comparison = .off; edit.wantsBeforePreview = false }
                    renderForCurrentTool()
                }
            } label: {
                Label("White Balance", systemImage: "eyedropper")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(isPickingWhitePoint ? Color.accentColor
                             : (activeTone.whitePoint == nil ? .secondary : .primary))
            .help("Click a neutral grey or white in the photo")

            Spacer()

            if activeTone.whitePoint != nil {
                Button {
                    setWhitePoint(nil)
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 8, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Clear the sampled white balance")
            }
        }
        .padding(.bottom, 2)
    }

    private func setWhitePoint(_ value: WhitePoint?) {
        if let id = selectedMaskID, edit.recipe.masks.contains(where: { $0.id == id }) {
            updateMask(id) { $0.tone.whitePoint = value }
        } else {
            edit.recipe.tone.whitePoint = value
            renderForCurrentTool()
        }
    }

    private func setCropping(_ active: Bool) {
        isCropping = active
        // The two overlays would compete for the same drags.
        if active {
            zoomState.reset()
            selectedMaskID = nil
            if comparison.isActive { comparison = .off; edit.wantsBeforePreview = false }
        }
        renderForCurrentTool()
    }

    /// Overlays map the pointer against the unzoomed fitted rect, so a zoomed
    /// view would place handles and strokes at a fraction of the intended
    /// offset. Zoom is dropped when handles come up, and suppressed while
    /// they're there.
    private func selectMask(_ id: UUID?) {
        selectedMaskID = id
        if id != nil {
            zoomState.reset()
            if isCropping { isCropping = false }
            if comparison.isActive { comparison = .off; edit.wantsBeforePreview = false }
        }
        renderForCurrentTool()
    }

    private var handlesAreActive: Bool {
        isCropping || selectedMaskID != nil || isPickingWhitePoint
    }

    /// Comparison, crop handles and mask handles each want the whole frame, so
    /// turning one on puts the others away.
    private func setComparison(_ mode: ComparisonMode) {
        comparison = mode
        edit.wantsBeforePreview = mode.isActive
        if mode.isActive {
            zoomState.reset()
            isCropping = false
            selectedMaskID = nil
        }
        renderForCurrentTool()
    }

    /// The preview drops the crop whenever handles are being placed against the
    /// whole frame.
    ///
    /// Mask geometry is stored against the uncropped image, so placing a mask
    /// over a cropped preview would record coordinates relative to the crop and
    /// render them relative to the full frame — the handle and the effect would
    /// sit in different places, and further apart the tighter the crop.
    private var showsUncroppedFrame: Bool {
        isCropping || selectedMaskID != nil
    }

    private func renderForCurrentTool() {
        edit.renderPreview(applyCrop: !showsUncroppedFrame)
    }

    /// Keeps the original as it is and adds this treatment as a photo of its
    /// own, built from the original pixels so it stays editable rather than
    /// being a flattened copy.
    /// Switches the session to another photo in the family.
    ///
    /// Committing first rather than discarding: the same rule as moving between
    /// photos with the arrow keys, so a version chip is not the one control
    /// that silently throws work away.
    private func openVersion(_ assetID: String) {
        guard let target = items.first(where: { $0.id == assetID }) else {
            editError = "That version isn't in the current selection."
            return
        }
        guard isEditing, edit.isDirty, let current else {
            app.focusID = target.id
            return
        }
        Task {
            do {
                try await edit.commit(for: current)
                await reloadAfterEdit()
                app.focusID = target.id
            } catch {
                editError = error.localizedDescription
            }
        }
    }

    private func splitLeftRight() {
        guard let current else { return }
        let recipe = edit.recipe
        Task {
            do {
                try await PhotoVariants.splitLeftRight(current,
                                                       applying: recipe,
                                                       context: modelContext,
                                                       library: library)
                ratings.reloadVariants()
                edit.discardChanges()
            } catch {
                editError = error.localizedDescription
            }
        }
    }

    private func saveVariant() {
        guard let current, let label = variantLabel else { return }
        let recipe = edit.recipe
        variantLabel = nil
        Task {
            do {
                try await PhotoVariants.create(from: current,
                                               applying: recipe,
                                               label: label.isEmpty ? "Variant" : label,
                                               context: modelContext,
                                               library: library)
                ratings.reloadVariants()
                // The treatment now lives on the new photo, so the original
                // goes back to how it was. Leaving it applied would mean the
                // next save — or just walking to the next photo, which commits
                // — quietly changed the original too.
                edit.discardChanges()
            } catch {
                editError = error.localizedDescription
            }
        }
    }

    private func endEditing(commit: Bool) {
        guard commit, edit.isDirty, let current else {
            isEditing = false
            isCropping = false
            selectedMaskID = nil
            isPickingWhitePoint = false
            comparison = .off
            edit.wantsBeforePreview = false
            editError = nil
            edit.cancel()
            return
        }

        Task {
            do {
                try await edit.commit(for: current)
                await reloadAfterEdit()
                isEditing = false
                isCropping = false
                selectedMaskID = nil
                isPickingWhitePoint = false
                comparison = .off
                edit.wantsBeforePreview = false
                editError = nil
                edit.cancel()
            } catch {
                // Stay open on failure: closing would look like the work was
                // saved when it wasn't.
                editError = error.localizedDescription
            }
        }
    }

    /// Moving to another photo saves the session rather than discarding it —
    /// the changes were made deliberately, and everything here is revertible.
    private func navigate(by offset: Int) {
        guard isEditing, edit.isDirty, let current else {
            app.move(by: offset, in: items, extendSelection: false)
            return
        }
        Task {
            do {
                try await edit.commit(for: current)
                await reloadAfterEdit()
                app.move(by: offset, in: items, extendSelection: false)
            } catch {
                // Left on the photo whose save failed, rather than carrying the
                // unsaved recipe onto the next one.
                editError = error.localizedDescription
            }
        }
    }

    /// The committed render replaces the asset's image, so the copy on screen —
    /// and the thumbnail cache behind it — are both stale.
    private func reloadAfterEdit() async {
        guard let current else { return }
        library.refreshAsset(withID: current.id)
        // `current` resolves against the items this view was handed, which still
        // describe the pre-edit asset — the refreshed one has to be taken from
        // the service directly.
        let refreshed = library.items.first { $0.id == current.id } ?? current
        image = await ThumbnailLoader.shared.fullImage(for: refreshed, maxDimension: 2400)
    }

    // MARK: - State

    private func close() {
        guard isEditing, edit.isDirty, let current else {
            app.isLoupePresented = false
            return
        }
        Task {
            do {
                try await edit.commit(for: current)
                await reloadAfterEdit()
                app.isLoupePresented = false
            } catch {
                // Staying open is the point: dismissing here would discard work
                // that was never written, while looking like it had been saved.
                editError = error.localizedDescription
            }
        }
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
            navigate(by: -1); return .handled
        case .rightArrow:
            navigate(by: 1); return .handled
        case .escape:
            if isPickingWhitePoint { isPickingWhitePoint = false }
            else if isCropping { setCropping(false) }
            else if isEditing { endEditing(commit: false) }
            else { close() }
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

        if character == "\\", isEditing, edit.hasVisibleChange {
            setComparison(comparison == .split ? .off : .split)
            return .handled
        }

        if character == "c", isEditing {
            setCropping(!isCropping)
            return .handled
        }

        if character == "e" {
            if isEditing { endEditing(commit: true) } else { Task { await beginEditing() } }
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
            guard !handlesAreActive else { return .ignored }
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
