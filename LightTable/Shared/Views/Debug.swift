import Foundation

/// Tools for looking at what the app has decided, kept out of the way of anyone
/// who did not ask for them.
///
/// Gated on an environment variable rather than on `#if DEBUG`, because the
/// build worth inspecting is usually the one that was released — a family
/// recovered wrongly, or a mask stored at the wrong size, shows up on the
/// installed app rather than on a debug build. A variable is invisible to
/// anyone launching from the Dock and costs nothing to set when it is wanted:
///
///     LIGHTTABLE_DEBUG=1 /Applications/LightTable.app/Contents/MacOS/LightTable
///
/// or by adding it to the scheme's environment in Xcode.
enum Debug {
    static let isEnabled = ProcessInfo.processInfo.environment["LIGHTTABLE_DEBUG"] == "1"
}
