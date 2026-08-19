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

    /// Whether to fetch the photographs Photos keeps hidden.
    ///
    /// Off, because hiding a photograph is a decision and a light table that
    /// ignores it is not one. Available for answering a question: a Lightroom
    /// collection that matches nothing at all, when the shoot is certainly in
    /// the library, is what a hidden album looks like from outside.
    static var includesHidden: Bool {
        isEnabled && ProcessInfo.processInfo.environment["LIGHTTABLE_INCLUDE_HIDDEN"] == "1"
    }

    /// Hide the newest photograph at launch and report what survives.
    static var hidesNewest: Bool {
        isEnabled && ProcessInfo.processInfo.environment["LIGHTTABLE_HIDE_PROBE"] == "1"
    }

    /// An identifier to ask after at launch — the same question from a process
    /// that never saw the photograph while it was visible.
    static var resolveIdentifier: String? {
        guard isEnabled, let id = ProcessInfo.processInfo.environment["LIGHTTABLE_RESOLVE_ID"],
              !id.isEmpty else { return nil }
        return id
    }

    /// An identifier to unhide at launch, putting the experiment back.
    static var unhideIdentifier: String? {
        guard isEnabled, let id = ProcessInfo.processInfo.environment["LIGHTTABLE_UNHIDE_ID"],
              !id.isEmpty else { return nil }
        return id
    }

    /// A Photos album to interrogate at launch.
    ///
    /// For the one question the ordinary fetch cannot answer: `PHAsset`'s own
    /// header says a hidden photograph is kept out of moments but "may still be
    /// included in other smart or regular album collections". If that holds, an
    /// album is a way for someone to hand this app photographs it is otherwise
    /// not allowed to see, without unhiding them.
    static var probeAlbum: String? {
        guard isEnabled,
              let name = ProcessInfo.processInfo.environment["LIGHTTABLE_PROBE_ALBUM"],
              !name.isEmpty else { return nil }
        return name
    }

    /// A Lightroom catalogue to survey at launch, for working on the matching
    /// without a hand on the menu.
    ///
    /// It only ever reports: the events themselves are made by someone deciding
    /// to make them, from the proposal, in front of the numbers.
    ///
    ///     LIGHTTABLE_DEBUG=1 LIGHTTABLE_LIGHTROOM_CATALOG=/path/to.lrcat LightTable
    static var lightroomCatalog: URL? {
        guard isEnabled,
              let path = ProcessInfo.processInfo.environment["LIGHTTABLE_LIGHTROOM_CATALOG"],
              !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

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
