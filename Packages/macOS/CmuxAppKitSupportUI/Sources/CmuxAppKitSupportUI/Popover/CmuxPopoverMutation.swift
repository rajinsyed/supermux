public import AppKit

@MainActor
public final class CmuxPopoverVisibleUpdateScheduler {
    private var pendingUpdate: (@MainActor () -> Void)?
    // SUPERMUX:begin popover-dynamic-height-reanchor
    private var scheduledGeneration: UInt64?
    // SUPERMUX:end popover-dynamic-height-reanchor
    private var generation: UInt64 = 0

    public init() {}

    public func schedule(_ update: @escaping @MainActor () -> Void) {
        pendingUpdate = update
        // SUPERMUX:begin popover-dynamic-height-reanchor
        guard scheduledGeneration == nil else { return }
        let generation = self.generation
        scheduledGeneration = generation
        // A main-actor Task may run later in the same AppKit update cycle. A
        // common-mode run-loop callback crosses the layout/render boundary that
        // NSPopover presentation, hosted-root layout, and dismissal must not re-enter.
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            // RunLoop guarantees main-thread delivery, but Foundation does not
            // annotate this callback with MainActor.
            MainActor.assumeIsolated {
                self?.flush(ifCurrent: generation)
            }
        }
        // SUPERMUX:end popover-dynamic-height-reanchor
    }

    public func cancel() {
        generation &+= 1
        // SUPERMUX:begin popover-dynamic-height-reanchor
        scheduledGeneration = nil
        // SUPERMUX:end popover-dynamic-height-reanchor
        pendingUpdate = nil
    }

    private func flush(ifCurrent generation: UInt64) {
        // SUPERMUX:begin popover-dynamic-height-reanchor
        guard scheduledGeneration == generation, generation == self.generation else { return }
        scheduledGeneration = nil
        // SUPERMUX:end popover-dynamic-height-reanchor
        guard let pendingUpdate else { return }
        self.pendingUpdate = nil
        pendingUpdate()
    }
}

// SUPERMUX:begin lint-allow-upstream-debt
// SUPERMUX:end lint-allow-upstream-debt (lint:allow namespace-type — upstream debt at the 0.64.20 merge; conventions gate runs only on the fork while upstream CI is paused)
@MainActor
public enum CmuxPopoverMutation {
    public static func performWithoutImplicitAnimation(_ body: () -> Void) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            body()
        }
    }

    public static func setContentSize(_ size: NSSize, on popover: NSPopover) {
        if popover.isShown {
            performWithoutImplicitAnimation {
                popover.contentSize = size
            }
        } else {
            popover.contentSize = size
        }
    }
}
