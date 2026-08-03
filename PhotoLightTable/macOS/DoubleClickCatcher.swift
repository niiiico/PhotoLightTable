#if os(macOS)
import AppKit
import SwiftUI

/// Reports a double-click landing inside the view it is attached to.
///
/// SwiftUI gestures never fire on a `Slider`: it is backed by `NSSlider`, which
/// consumes mouse events for its own tracking before any recogniser sees them —
/// even a `.simultaneousGesture`. A local event monitor sees them regardless of
/// the responder chain, and this view exists only to supply a frame to test the
/// click against. `hitTest` returns nil so it is never a hit target and single
/// clicks, drags and click-to-jump are untouched; only the second click of a
/// double-click is taken, and only when it lands inside these bounds.
struct DoubleClickCatcher: NSViewRepresentable {
    var action: () -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.action = action
        return view
    }

    func updateNSView(_ nsView: CatcherView, context: Context) {
        nsView.action = action
    }

    static func dismantleNSView(_ nsView: CatcherView, coordinator: ()) {
        nsView.stopMonitoring()
    }

    final class CatcherView: NSView {
        var action: (() -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { stopMonitoring() } else { startMonitoring() }
        }

        /// Never a hit target, so the control underneath behaves normally.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        private func startMonitoring() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                guard let self,
                      event.clickCount == 2,
                      let window = self.window,
                      event.window === window else { return event }

                let point = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(point) else { return event }

                self.action?()
                // Swallowed. Passing it on lets the slider handle the same click
                // and jump its value to the click position, which lands after the
                // reset and undoes it — the reset ran, and then the control put
                // the value straight back.
                return nil
            }
        }

        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}

extension View {
    /// Runs `action` on a double-click anywhere within this view's bounds.
    func onDoubleClick(perform action: @escaping () -> Void) -> some View {
        background(DoubleClickCatcher(action: action))
    }
}
#endif
