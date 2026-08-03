import SwiftUI

/// Version and build, small and out of the way.
///
/// The build number is the commit count, so it is the same on every machine for
/// the same commit and only ever increases. A trailing "+" means the tree had
/// uncommitted changes, which is the case where the number alone would be a
/// claim the build cannot support.
struct BuildStamp: View {
    var body: some View {
        Text("\(Self.version) (\(Self.label))")
            .font(.system(size: 9, weight: .medium).monospacedDigit())
            .foregroundStyle(.secondary)
            .opacity(0.55)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .help(Self.detail)
    }

    private static func string(_ key: String) -> String? {
        Bundle.main.object(forInfoDictionaryKey: key) as? String
    }

    private static var version: String { string("CFBundleShortVersionString") ?? "—" }

    private static var label: String {
        string("LTBuildLabel") ?? string("CFBundleVersion") ?? "—"
    }

    private static var detail: String {
        let commit = string("LTBuildCommit") ?? "unknown"
        let dirty = label.hasSuffix("+") ? " with uncommitted changes" : ""
        return "Version \(version), build \(label) — commit \(commit)\(dirty)"
    }
}
