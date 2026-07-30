#if os(macOS)
import AppKit
import SwiftUI

/// Zoom and pan state for the loupe.
///
/// A reference type because the scroll-wheel monitor is a long-lived closure:
/// capturing SwiftUI `@State` there would freeze the values as they were when
/// the monitor was installed.
@MainActor
final class LoupeZoom: ObservableObject {
    @Published private(set) var zoom: CGFloat = 1
    @Published private(set) var pan: CGSize = .zero

    private var committedZoom: CGFloat = 1
    private var committedPan: CGSize = .zero
    private var monitor: Any?

    static let maxZoom: CGFloat = 8
    static let doubleClickZoom: CGFloat = 2.5

    var isZoomed: Bool { zoom > 1 }

    // MARK: - Scroll wheel

    /// A local monitor rather than a view: scroll events are delivered by hit
    /// testing, and the image and its gesture recognizers sit in front of any
    /// view we could put behind them.
    func startMonitoringScroll() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, self.isZoomed else { return event }
            MainActor.assumeIsolated {
                self.panBy(dx: event.scrollingDeltaX, dy: event.scrollingDeltaY)
            }
            return nil // consumed, so the grid behind doesn't scroll too
        }
    }

    func stopMonitoringScroll() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    // MARK: - Mutation

    func panBy(dx: CGFloat, dy: CGFloat) {
        pan = CGSize(width: pan.width + dx, height: pan.height + dy)
        committedPan = pan
    }

    func dragTo(_ translation: CGSize) {
        guard isZoomed else { return }
        pan = CGSize(width: committedPan.width + translation.width,
                     height: committedPan.height + translation.height)
    }

    func endDrag() { committedPan = pan }

    func magnify(_ factor: CGFloat) {
        zoom = min(max(committedZoom * factor, 1), Self.maxZoom)
        if zoom == 1 { pan = .zero }
    }

    func endMagnify() {
        committedZoom = zoom
        committedPan = pan
    }

    func set(_ value: CGFloat) {
        zoom = min(max(value, 1), Self.maxZoom)
        committedZoom = zoom
        // Panning is meaningless at fit, and a leftover offset would shift the
        // next photo off-centre.
        if zoom == 1 {
            pan = .zero
            committedPan = .zero
        }
    }

    func toggle() { set(isZoomed ? 1 : Self.doubleClickZoom) }

    func reset() { set(1) }
}
#endif
