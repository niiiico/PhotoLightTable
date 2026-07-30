#if os(macOS)
import AppKit
import SwiftUI

/// Reports two-finger scroll deltas.
///
/// SwiftUI has no gesture for the scroll wheel, so this drops down to AppKit.
/// Placed as a background it sits behind the image and receives scroll events
/// that nothing in front consumes, leaving click and drag gestures untouched.
struct ScrollPanCatcher: NSViewRepresentable {
    var onScroll: (CGSize) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ nsView: CatcherView, context: Context) {
        nsView.onScroll = onScroll
    }

    final class CatcherView: NSView {
        var onScroll: ((CGSize) -> Void)?

        override func scrollWheel(with event: NSEvent) {
            // scrollingDelta already accounts for the system's natural-scrolling
            // setting, so the content follows the fingers without inverting here.
            let delta = CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY)
            guard delta != .zero else { return }
            onScroll?(delta)
        }
    }
}
#endif
