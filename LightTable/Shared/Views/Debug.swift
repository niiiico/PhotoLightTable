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

    /// Times a piece of work and prints it when it took long enough to be felt.
    ///
    /// A sixtieth of a second is the budget for anything on the way to the
    /// screen; half of that is the threshold here, so what shows up in the log
    /// is only work that is actually in the way. Silent unless asked for, and
    /// the timing itself costs a clock read.
    @discardableResult
    static func time<T>(_ label: String,
                        threshold: Double = 0.008,
                        _ work: () -> T) -> T {
        guard isEnabled else { return work() }
        let started = CFAbsoluteTimeGetCurrent()
        let result = work()
        let elapsed = CFAbsoluteTimeGetCurrent() - started
        if elapsed >= threshold {
            // Standard error, unbuffered: redirected to a file, `print` holds
            // its output until the buffer fills, which for a few lines a second
            // means the log is empty exactly while it is being read.
            fputs(String(format: "[perf] %@ %.1f ms\n", label, elapsed * 1000), stderr)
        }
        return result
    }
}
