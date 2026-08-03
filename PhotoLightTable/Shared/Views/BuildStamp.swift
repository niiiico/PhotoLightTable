import SwiftUI

/// Version and build, small and out of the way.
///
/// Its real job is answering "is this the build I just made" without checking
/// process identifiers or file timestamps, so the build number is the part that
/// has to be legible.
struct BuildStamp: View {
    var body: some View {
        Text(Self.text)
            .font(.system(size: 9, weight: .medium).monospacedDigit())
            .foregroundStyle(.secondary)
            .opacity(0.55)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .help("Version \(Self.version), build \(Self.build)")
    }

    private static var text: String { "\(version) (\(build))" }

    private static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    private static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }
}
