import AppKit

/// Clears ``SupermuxSidebarDragState`` when a sidebar reorder drag ends without
/// a delivered drop.
///
/// SwiftUI's `.onDrag` has no "drag ended / cancelled" callback: a row's
/// `DropDelegate.performDrop` only fires when the release lands on a valid drop
/// target. A drag released anywhere else (empty space, another panel, outside
/// the window) leaves the dragged id set, so the source row would stay dimmed
/// forever. This watches for the mouse-up / Escape that ends such a drag and
/// clears the marker. Mirrors cmux's `SidebarDragFailsafeMonitor`.
@MainActor
public final class SupermuxSidebarDragFailsafe {
    /// Virtual key code for the Escape key (cancels a drag).
    private static let escapeKeyCode: UInt16 = 53

    private weak var dragState: SupermuxSidebarDragState?
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var keyDownMonitor: Any?

    /// Creates an idle failsafe.
    public init() {}

    /// Begins watching for drag-end events that should clear `dragState`.
    /// Idempotent — re-binding `dragState` without reinstalling the monitors.
    /// - Parameter dragState: The drag state to clear when a drag aborts.
    public func start(clearing dragState: SupermuxSidebarDragState) {
        self.dragState = dragState
        guard localMouseMonitor == nil else { return }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            MainActor.assumeIsolated { self?.scheduleEnd(cancelled: false) }
            return event
        }
        // Global monitor catches a release outside the app's own windows.
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleEnd(cancelled: false) }
        }
        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == Self.escapeKeyCode {
                // Escape cancels: the previewed order is discarded, never
                // committed (a release ends the drag and commits instead).
                MainActor.assumeIsolated { self?.scheduleEnd(cancelled: true) }
            }
            return event
        }
    }

    /// Removes the event monitors. Call from the host view's `onDisappear`.
    public func stop() {
        for monitor in [localMouseMonitor, globalMouseMonitor, keyDownMonitor] {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
        localMouseMonitor = nil
        globalMouseMonitor = nil
        keyDownMonitor = nil
        dragState = nil
    }

    /// Ends the drag on the next runloop tick so a real drop — whose
    /// `performDrop` runs as part of the same mouse-up and still needs the
    /// dragged id — completes the reorder before the marker is cleared. A
    /// release (`cancelled: false`) commits any previewed order; Escape
    /// (`cancelled: true`) discards it.
    private func scheduleEnd(cancelled: Bool) {
        // Idle steady state (no drag in flight): bail before dispatching. These
        // monitors see every left mouse-up app-wide (and, via the global
        // monitor, in other apps) plus every Escape press; without this guard
        // each such event would mutate the @Observable drag state and
        // re-render every project/workspace row. The reads here run outside
        // any SwiftUI observation scope, so they register no dependency.
        guard let dragState, dragState.hasActiveDrag else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if cancelled {
                    dragState.cancel()
                } else {
                    dragState.clear()
                }
            }
        }
    }
}
