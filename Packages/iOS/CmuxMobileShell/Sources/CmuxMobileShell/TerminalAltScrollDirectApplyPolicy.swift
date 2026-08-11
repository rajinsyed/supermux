import Foundation

/// Decides when an alternate-screen repaint delta may skip the verified
/// freeze/apply/present/read-back/verify pipeline and apply directly.
///
/// During an active scroll gesture a TUI emits repaint deltas faster than the
/// verified pipeline's per-frame Metal fence can drain them, which reads as
/// jank: motion arrives in uneven clumps. Deltas inside a short window after
/// the last scroll input apply directly (same ordered VT patch bytes, no
/// fence). Full frames always stay verified, and the first verified delta
/// after the window re-checks pixel exactness — an inconsistency introduced
/// during the window fails that comparison and triggers the existing full
/// replay recovery, so correctness is deferred by at most the window, never
/// lost.
struct TerminalAltScrollDirectApplyPolicy: Equatable, Sendable {
    /// How long after the last scroll input deltas keep the direct path.
    /// Long enough to cover the RPC → PTY → TUI repaint → frame return for
    /// the tail of a gesture (~150–300 ms observed), short enough that
    /// steady-state output returns to verified application promptly.
    static let activityWindow: TimeInterval = 0.8

    /// Whether an alternate-screen delta frame may apply directly.
    /// - Parameters:
    ///   - isFullFrame: Full frames always verify (they are the recovery
    ///     baseline and are rare enough not to jank).
    ///   - lastScrollInputAt: Uptime of the surface's last forwarded
    ///     alternate-screen scroll input, if any.
    ///   - now: Current monotonic uptime.
    static func shouldApplyDirectly(
        isFullFrame: Bool,
        lastScrollInputAt: TimeInterval?,
        now: TimeInterval
    ) -> Bool {
        guard !isFullFrame, let lastScrollInputAt else { return false }
        let elapsed = now - lastScrollInputAt
        return elapsed >= 0 && elapsed < activityWindow
    }
}
