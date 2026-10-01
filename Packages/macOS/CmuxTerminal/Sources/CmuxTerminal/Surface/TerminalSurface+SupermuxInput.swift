public import Foundation

// Supermux (fork-owned file, SUPERMUX-TOUCHPOINTS.md #638): a public door to
// the surface's runtime clipboard-read input sequencing, for input another
// Mac's device mirror delivers here outside `sendInputResult`.

extension TerminalSurface {
    /// Holds input while a paste's clipboard read is in flight, exactly as
    /// this Mac's own typing is held, and replays it afterwards in order.
    ///
    /// - Returns: `true` when `replay` was queued (deliver nothing now).
    @MainActor
    public func supermuxDeferInputDuringClipboardRead(estimatedBytes: Int, replay: @escaping () -> Void) -> Bool {
        deferInputDuringRuntimeClipboardRead(estimatedBytes: estimatedBytes, replay: replay)
    }
}
