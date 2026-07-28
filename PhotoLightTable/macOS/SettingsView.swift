#if os(macOS)
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            AppearanceSettings()
                .tabItem { Label("Appearance", systemImage: "square.grid.2x2") }
            LoupeSettings()
                .tabItem { Label("Loupe", systemImage: "camera.aperture") }
        }
        .frame(width: 460, height: 400)
    }
}

private struct AppearanceSettings: View {
    @AppStorage(PreferenceKey.thumbnailFillMode) private var fillModeRaw = ThumbnailFillMode.fill.rawValue

    private var fillMode: Binding<ThumbnailFillMode> {
        Binding(
            get: { ThumbnailFillMode(rawValue: fillModeRaw) ?? .fill },
            set: { fillModeRaw = $0.rawValue }
        )
    }

    var body: some View {
        Form {
            Section {
                Picker("Thumbnails", selection: fillMode) {
                    ForEach(ThumbnailFillMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.inline)

                Text(fillMode.wrappedValue.help)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Appearance")
            }
        }
        .formStyle(.grouped)
    }
}

private struct LoupeSettings: View {
    @AppStorage(PreferenceKey.loupeFields) private var fieldsRaw = LoupeFields.defaultValue

    private var selected: Set<MetadataField> {
        Set(LoupeFields.decode(fieldsRaw))
    }

    var body: some View {
        Form {
            Section {
                ForEach(MetadataField.allCases) { field in
                    Toggle(field.label, isOn: Binding(
                        get: { selected.contains(field) },
                        set: { isOn in
                            var current = selected
                            if isOn { current.insert(field) } else { current.remove(field) }
                            fieldsRaw = LoupeFields.encode(
                                MetadataField.allCases.filter { current.contains($0) })
                        }
                    ))
                }
            } header: {
                Text("Show in the loupe")
            } footer: {
                Text("Fields a photo doesn't carry are skipped rather than shown empty, so switching everything on costs nothing on files without EXIF.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Restore Defaults") {
                    fieldsRaw = LoupeFields.defaultValue
                }
            }
        }
        .formStyle(.grouped)
    }
}
#endif
