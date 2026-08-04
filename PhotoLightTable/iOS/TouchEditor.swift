#if !os(macOS)
import SwiftData
import SwiftUI

/// The editor on touch.
///
/// The same recipe, overlays and commit path as the Mac — only the arrangement
/// differs. Tools are picked explicitly rather than being always-present, since
/// there is no room for eleven sliders and a set of handles at once, and only
/// one of them can have the screen anyway.
struct TouchEditor: View {
    let item: PhotoItem
    let onFinished: () -> Void

    @EnvironmentObject private var library: PhotoLibraryService
    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var sizeClass

    @StateObject private var edit = PhotoEditSession()
    @StateObject private var zoom = LoupeZoom()

    @State private var tool: Tool = .adjust
    @State private var selectedMaskID: UUID?
    @State private var brushRadius = BrushStroke.defaultRadius
    @State private var isErasing = false
    @State private var isShowingBefore = false
    @State private var isPickingWhitePoint = false
    @State private var errorMessage: String?

    enum Tool: String, CaseIterable, Identifiable {
        case adjust, crop, masks

        var id: String { rawValue }
        var label: String {
            switch self {
            case .adjust: return "Adjust"
            case .crop: return "Crop"
            case .masks: return "Masks"
            }
        }
        var symbolName: String {
            switch self {
            case .adjust: return "slider.horizontal.3"
            case .crop: return "crop"
            case .masks: return "circle.lefthalf.filled"
            }
        }
    }

    /// A regular width has room beside the photo; a compact one does not, so the
    /// controls go underneath instead of squeezing the image.
    private var usesSidePanel: Bool { sizeClass == .regular }

    var body: some View {
        Group {
            if usesSidePanel {
                HStack(spacing: 0) {
                    photo
                    Divider()
                    panel.frame(width: 320)
                }
            } else {
                VStack(spacing: 0) {
                    photo
                    Divider()
                    panel.frame(maxHeight: 320)
                }
            }
        }
        .background(Color.black)
        .task {
            edit.modelContext = modelContext
            // Kept ready throughout: it is only re-rendered when the loaded
            // recipe or the crop changes, so holding the photo is instant
            // rather than waiting on a render.
            edit.wantsBeforePreview = true
            await edit.begin(for: item)
            renderForCurrentTool()
        }
    }

    // MARK: - Photo

    private var photo: some View {
        GeometryReader { geo in
            ZStack {
                // The original replaces the edit in place rather than sitting
                // beside it: the same pixels in the same position is what makes
                // a difference legible, and there is no room on a phone for two
                // copies of the photo.
                if let image = isShowingBefore ? (edit.beforePreview ?? edit.preview) : edit.preview {
                    Image(platformImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .scaleEffect(zoom.zoom)
                        .offset(zoom.pan)
                } else {
                    ProgressView().controlSize(.large).tint(.white)
                }

                if isShowingBefore {
                    VStack {
                        Text("ORIGINAL")
                            .font(.caption2.weight(.heavy))
                            .kerning(0.8)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(.black.opacity(0.55), in: Capsule())
                            .padding(.top, 16)
                        Spacer()
                    }
                    .allowsHitTesting(false)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .overlay { overlays }
            // Zoom is a pinch and pan is a drag, both directly on the image.
            // The Mac's scroll-wheel monitor has no counterpart here and none is
            // needed.
            .gesture(handlesAreActive ? nil : panGesture)
            .simultaneousGesture(handlesAreActive ? nil : magnifyGesture)
            .simultaneousGesture(holdToCompare)
        }
    }

    @ViewBuilder
    private var overlays: some View {
        let aspect = edit.preview.map { $0.size.height > 0 ? $0.size.width / $0.size.height : 1 } ?? 1

        if isPickingWhitePoint {
            WhitePointPicker(
                imageAspect: aspect,
                onPick: { point in
                    let target: PhotoEditSession.MaskTarget =
                        selectedMaskID.map { .mask($0) } ?? .whole
                    if !edit.sampleWhitePoint(at: point, into: target) {
                        errorMessage = "That area is too dark to balance from."
                    }
                    isPickingWhitePoint = false
                },
                onCancel: { isPickingWhitePoint = false })
        } else if tool == .crop {
            CropOverlay(crop: Binding(
                get: { edit.recipe.crop },
                set: { edit.recipe.crop = $0 }
            ), imageAspect: aspect, aspect: cropAspect)
        } else if let mask = selectedMask {
            if mask.kind == .brush {
                BrushOverlay(mask: maskBinding(mask.id),
                             imageAspect: aspect,
                             brushRadius: brushRadius,
                             isErasing: isErasing,
                             showsPaint: true,
                             softness: mask.softness)
            } else {
                MaskOverlay(mask: maskBinding(mask.id), imageAspect: aspect)
            }
        }
    }

    @State private var cropAspect: CropAspect = .free

    private var handlesAreActive: Bool {
        tool == .crop || selectedMaskID != nil || isPickingWhitePoint
    }

    private var panGesture: some Gesture {
        DragGesture()
            .onChanged { zoom.dragTo($0.translation) }
            .onEnded { _ in zoom.endDrag() }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { zoom.magnify($0.magnification) }
            .onEnded { _ in zoom.endMagnify() }
    }

    /// Press and hold anywhere on the photo to see it as it was.
    ///
    /// Sequenced rather than a plain long press, because the state has to
    /// follow the finger being down: a long press alone reports that it fired,
    /// not that it is still being held, and the original would never go away.
    private var holdToCompare: some Gesture {
        LongPressGesture(minimumDuration: 0.22)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { value in
                if case .second(true, _) = value {
                    withAnimation(.easeOut(duration: 0.1)) { isShowingBefore = true }
                }
            }
            .onEnded { _ in
                withAnimation(.easeOut(duration: 0.1)) { isShowingBefore = false }
            }
    }

    // MARK: - Panel

    private var panel: some View {
        VStack(spacing: 0) {
            Picker("Tool", selection: Binding(get: { tool }, set: { setTool($0) })) {
                ForEach(Tool.allCases) { tool in
                    Label(tool.label, systemImage: tool.symbolName).tag(tool)
                }
            }
            .pickerStyle(.segmented)
            .labelStyle(.titleAndIcon)
            .padding(12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch tool {
                    case .adjust: adjustControls
                    case .crop: cropControls
                    case .masks: maskControls
                    }
                }
                .padding(16)
            }

            Divider()
            footer
        }
        .background(.bar)
    }

    private var adjustControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Button {
                    isPickingWhitePoint.toggle()
                    if isPickingWhitePoint { selectedMaskID = nil; renderForCurrentTool() }
                } label: {
                    Label("White Balance", systemImage: "eyedropper")
                        .font(.callout)
                }
                .buttonStyle(.bordered)
                .tint(isPickingWhitePoint ? .accentColor : .secondary)

                if activeTone.whitePoint != nil {
                    Button("Clear") { setWhitePoint(nil) }
                        .font(.caption)
                }
            }

            ForEach(Adjustment.allCases) { adjustment in
                slider(adjustment)
            }
        }
    }

    private func slider(_ adjustment: Adjustment) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(adjustment.label)
                    .font(.caption)
                    .foregroundStyle(activeTone[adjustment] == 0 ? .secondary : .primary)
                Spacer()
                Text(adjustment.formatted(activeTone[adjustment]))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                // Double-tap on a slider is unreliable on a control that owns
                // its own gestures, so resetting is an explicit button here.
                Button {
                    setTone(adjustment, 0)
                    renderForCurrentTool()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .opacity(activeTone[adjustment] == 0 ? 0 : 1)
                .disabled(activeTone[adjustment] == 0)
            }

            Slider(value: Binding(
                get: { activeTone[adjustment] },
                set: { setTone(adjustment, $0); renderForCurrentTool() }
            ), in: adjustment.range)
        }
    }

    private var cropControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Aspect", selection: $cropAspect) {
                ForEach(CropAspect.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.menu)

            Button("Reset Crop") {
                edit.recipe.crop = .full
                renderForCurrentTool()
            }
            .disabled(edit.recipe.crop.isFull)
        }
    }

    private var maskControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Menu {
                Button("Linear Gradient") { addMask(.linear) }
                Button("Radial Gradient") { addMask(.radial) }
                Button("Brush") { addMask(.brush) }
            } label: {
                Label("Add Mask", systemImage: "plus")
            }

            if edit.recipe.masks.isEmpty {
                Text("Add a gradient or brush to adjust part of the photo.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(edit.recipe.masks) { mask in
                    maskRow(mask)
                }
            }

            if let mask = selectedMask {
                Divider()
                if mask.kind == .brush { brushControls(mask) }
                Text("Adjustments apply to this mask.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                ForEach(Adjustment.allCases) { slider($0) }
            }
        }
    }

    private func maskRow(_ mask: EditMask) -> some View {
        let isSelected = mask.id == selectedMaskID
        return HStack {
            Button {
                updateMask(mask.id) { $0.isEnabled.toggle() }
            } label: {
                Image(systemName: mask.isEnabled ? "eye" : "eye.slash")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 1) {
                Text(mask.name).font(.callout.weight(isSelected ? .semibold : .regular))
                Text(mask.tone.summary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button(role: .destructive) {
                edit.recipe.masks.removeAll { $0.id == mask.id }
                if selectedMaskID == mask.id { selectedMaskID = nil }
                renderForCurrentTool()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(isSelected ? Color.accentColor.opacity(0.18) : .clear,
                    in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture {
            selectedMaskID = isSelected ? nil : mask.id
            zoom.reset()
            renderForCurrentTool()
        }
    }

    private func brushControls(_ mask: EditMask) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $isErasing) {
                Text("Paint").tag(false)
                Text("Erase").tag(true)
            }
            .pickerStyle(.segmented)

            VStack(alignment: .leading, spacing: 2) {
                Text("Size").font(.caption).foregroundStyle(.secondary)
                Slider(value: $brushRadius, in: 0.01...0.3)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Softness").font(.caption).foregroundStyle(.secondary)
                Slider(value: Binding(
                    get: { mask.softness },
                    set: { value in updateMask(mask.id) { $0.softness = value } }
                ), in: 0...1)
            }

            Button("Clear Strokes") { updateMask(mask.id) { $0.strokes = [] } }
                .font(.caption)
                .disabled(mask.strokes.isEmpty)
        }
    }

    private var footer: some View {
        VStack(spacing: 8) {
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 12) {
                if edit.hasVisibleChange {
                    Label("Hold photo for original", systemImage: "hand.tap")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .labelStyle(.titleAndIcon)
                }

                if edit.hasExistingEdit {
                    Button {
                        Task {
                            do {
                                try await edit.revert(for: item)
                                library.refreshAsset(withID: item.id)
                            } catch { errorMessage = error.localizedDescription }
                        }
                    } label: {
                        Image(systemName: "arrow.uturn.backward.circle")
                    }
                }

                if edit.isCommitting { ProgressView().controlSize(.small) }

                Spacer()

                Button("Cancel") { onFinished() }

                Button(edit.isDirty ? "Save" : "Done") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(edit.isCommitting)
            }
        }
        .padding(12)
    }

    // MARK: - Actions

    private func save() {
        guard edit.isDirty else { onFinished(); return }
        Task {
            do {
                try await edit.commit(for: item)
                library.refreshAsset(withID: item.id)
                onFinished()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func setTool(_ newTool: Tool) {
        tool = newTool
        if newTool != .masks { selectedMaskID = nil }
        isPickingWhitePoint = false
        zoom.reset()
        renderForCurrentTool()
    }

    /// Mask geometry is stored against the uncropped image, so placing one has
    /// to happen against the uncropped frame — the same rule as on the Mac.
    private func renderForCurrentTool() {
        edit.renderPreview(applyCrop: !(tool == .crop || selectedMaskID != nil))
    }

    private var selectedMask: EditMask? {
        guard let selectedMaskID else { return nil }
        return edit.recipe.masks.first { $0.id == selectedMaskID }
    }

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

    private func addMask(_ kind: EditMask.Kind) {
        var mask = EditMask()
        mask.kind = kind
        if kind == .radial {
            mask.start = EditPoint(x: 0.5, y: 0.5)
            mask.end = EditPoint(x: 0.78, y: 0.5)
        }
        edit.recipe.masks.append(mask)
        selectedMaskID = mask.id
        zoom.reset()
        renderForCurrentTool()
    }

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

    private func setWhitePoint(_ value: WhitePoint?) {
        if let id = selectedMaskID, edit.recipe.masks.contains(where: { $0.id == id }) {
            updateMask(id) { $0.tone.whitePoint = value }
        } else {
            edit.recipe.tone.whitePoint = value
            renderForCurrentTool()
        }
    }
}
#endif
