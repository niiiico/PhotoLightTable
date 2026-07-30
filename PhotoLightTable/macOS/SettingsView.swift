#if os(macOS)
import SwiftUI

struct SettingsView: View {
    var body: some View {
        AppearanceSettings()
            .frame(width: 460, height: 300)
    }
}

private struct AppearanceSettings: View {
    @AppStorage(PreferenceKeys.thumbnailFillMode) private var fillModeRaw = ThumbnailFillMode.fill.rawValue

    private var fillMode: Binding<ThumbnailFillMode> {
        Binding(
            get: { ThumbnailFillMode(rawValue: fillModeRaw) ?? .fill },
            set: { fillModeRaw = $0.rawValue }
        )
    }

    @AppStorage(PreferenceKeys.appearance) private var appearanceRaw = AppearancePreference.system.rawValue

    private var appearance: Binding<AppearancePreference> {
        Binding(
            get: { AppearancePreference(rawValue: appearanceRaw) ?? .system },
            set: { appearanceRaw = $0.rawValue }
        )
    }

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: appearance) {
                    ForEach(AppearancePreference.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)

                Text("Dark keeps the surround out of the way while you judge an image; light is easier in a bright room.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

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
#endif
