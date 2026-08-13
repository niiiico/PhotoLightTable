import Foundation

/// What this build says about itself, read from the Info.plist keys the
/// "Stamp build number" script phase writes.
///
/// Extracted from `BuildStamp` because the update check needs the same numbers
/// for a different purpose: the stamp displays them, the check compares them.
/// One reader, so the two cannot disagree about which keys they mean.
enum AppBuild {
    static func string(_ key: String) -> String? {
        Bundle.main.object(forInfoDictionaryKey: key) as? String
    }

    /// `CFBundleShortVersionString` — the marketing version.
    static var version: String { string("CFBundleShortVersionString") ?? "—" }

    /// The build with its dirty marker, for display. Never compare this.
    static var label: String { string("LTBuildLabel") ?? string("CFBundleVersion") ?? "—" }

    static var commit: String { string("LTBuildCommit") ?? "unknown" }

    /// The build as a number, for comparison.
    ///
    /// It is the commit count, so it only increases and is the same on every
    /// machine for the same commit — which is what makes a plain `<` against
    /// the published build sound. A build from a modified tree carries a
    /// trailing `+` in `label` but not here, since `CFBundleVersion` has to
    /// stay numeric.
    static var number: Int { Int(string("CFBundleVersion") ?? "") ?? 0 }
}
