import Foundation
import IOKit.ps

/// Observes AC/battery transitions. A protocol so tests can simulate the
/// documented case where the run-loop source cannot be created.
@MainActor
public protocol SupermuxPowerSourceObserving: AnyObject {
    /// Returns `false` when observation could not be installed — callers must
    /// then treat the power source as unobservable rather than assume it stays
    /// put. See ``SupermuxPowerSourceMonitor/start(onChange:)``.
    @discardableResult
    func start(onChange: @escaping () -> Void) -> Bool
    func stop()
}

/// Calls back whenever the Mac switches between AC and battery.
///
/// Coffee Mode needs this because its lid-close layer is AC-only: unplugging
/// must drop that layer so the UI stops promising coverage the Mac no longer
/// has. `NSProcessInfoPowerStateDidChange` is NOT the right signal — that
/// reports Low Power Mode, not the power source — so this uses the IOPS
/// run-loop source, which is what actually fires on plug/unplug.
@MainActor
public final class SupermuxPowerSourceMonitor: SupermuxPowerSourceObserving {
    /// `nonisolated(unsafe)` so `deinit` can unregister the source. Every other
    /// access is main-actor isolated, and in `deinit` no other reference to
    /// this object can exist, so there is no concurrent access to race with.
    /// CFRunLoop's own APIs are thread-safe.
    private nonisolated(unsafe) var runLoopSource: CFRunLoopSource?
    private var onChange: (() -> Void)?

    public init() {}

    /// Starts observing. Calling this twice replaces the previous handler
    /// rather than registering a second run-loop source.
    ///
    /// Returns `false` when the run-loop source could not be created (the
    /// header permits NULL). Callers must treat that as "plug/unplug is
    /// undetectable" and stop relying on any AC-only behavior, rather than
    /// assuming the power source stays whatever it was at start.
    @discardableResult
    public func start(onChange: @escaping () -> Void) -> Bool {
        stop()
        self.onChange = onChange

        // `context` is an unmanaged pointer to self. It stays valid because
        // `stop()` (and `deinit` via `stop()`) removes the source before the
        // object can be deallocated.
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<SupermuxPowerSourceMonitor>
                .fromOpaque(context)
                .takeUnretainedValue()
            // The IOPS callback already runs on the run loop this source was
            // added to (the main run loop), so this is main-thread work.
            MainActor.assumeIsolated {
                monitor.onChange?()
            }
        }, context)?.takeRetainedValue() else {
            self.onChange = nil
            return false
        }

        runLoopSource = source
        // commonModes, not defaultMode: a plug/unplug during menu tracking or a
        // modal loop must still be observed, or coverage stays stale.
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        return true
    }

    public func stop() {
        if let runLoopSource {
            // Must match the mode used in `start()`; removing from a different
            // mode leaves the source registered and firing into a stale handler.
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            self.runLoopSource = nil
        }
        onChange = nil
    }

    deinit {
        if let runLoopSource {
            // Must match the mode used in `start()`; removing from a different
            // mode leaves the source registered and firing into a stale handler.
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            // Belt and braces: the callback holds an unretained pointer to
            // self, so invalidate the source too in case anything still
            // references it after removal.
            CFRunLoopSourceInvalidate(runLoopSource)
        }
    }
}
