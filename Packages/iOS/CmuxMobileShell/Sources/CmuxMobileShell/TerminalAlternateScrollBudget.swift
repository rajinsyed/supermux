import Foundation

/// Bounds how many alternate-screen wheel lines a gesture may deliver to the
/// Mac, so a fast drag cannot build a downstream backlog that keeps consuming
/// after the finger lifts.
///
/// On the alternate screen every forwarded line becomes a discrete input for
/// the TUI (an arrow-key sequence or a mouse-wheel report), and the visible
/// result arrives only as the TUI repaints. A fast drag can emit far more
/// lines in 300 ms than that pipeline (RPC → PTY → TUI repaint → render-grid
/// frame back to the phone) can absorb, and the surplus plays out AFTER
/// touch-up — which reads as phantom momentum on a phone whose local scroll
/// view has no inertia at all.
///
/// The budget is a token bucket over line magnitude. Excess lines are dropped,
/// never queued: queuing would preserve exactly the deferred playback this
/// exists to prevent. Dropping only shortens how far one fast drag travels;
/// a sustained slower drag is refilled continuously and feels unchanged.
struct TerminalAlternateScrollBudget: Equatable, Sendable {
    /// Lines a gesture may deliver instantly before throttling begins. Sized
    /// to roughly one visible "step" burst for a full-screen TUI; physical
    /// traces measured under 4 lines per typical gesture, so this must stay
    /// small enough that a fast drag actually hits the limiter.
    static let defaultBurstLines = 4.0
    /// Sustained delivery rate. A dogfood tuning point, not a measured TUI
    /// service rate: low enough to bound backlog visibly, high enough that a
    /// deliberate continuous drag still travels.
    static let defaultRefillLinesPerSecond = 20.0

    private let burstLines: Double
    private let refillLinesPerSecond: Double
    private var availableLines: Double
    private var lastRefillTime: TimeInterval?

    init(
        burstLines: Double = Self.defaultBurstLines,
        refillLinesPerSecond: Double = Self.defaultRefillLinesPerSecond
    ) {
        self.burstLines = max(1, burstLines)
        self.refillLinesPerSecond = max(1, refillLinesPerSecond)
        self.availableLines = max(1, burstLines)
    }

    /// Admits `lines` that were already scaled by the user's scroll-speed
    /// multiplier. The budget is evaluated in UNSCALED gesture units
    /// (`lines / speed`) and the admission is scaled back, so the delivered
    /// cap is proportional to the preference. Without this, a fast drag
    /// saturates the bucket at the same absolute line count regardless of
    /// speed, and the Settings slider has no visible effect on TUIs.
    mutating func admit(lines: Double, speed: Double, at now: TimeInterval) -> Double {
        let clampedSpeed = max(speed, 0.01)
        return admit(lines: lines / clampedSpeed, at: now) * clampedSpeed
    }

    /// Admits up to the currently available magnitude of `lines`, preserving
    /// sign, and drops the remainder. `now` must be monotonic (system uptime);
    /// a backwards step refills nothing AND keeps the newer stored timestamp,
    /// so a later recovered clock cannot double-count the interval it already
    /// covered.
    mutating func admit(lines: Double, at now: TimeInterval) -> Double {
        guard lines != 0 else { return 0 }
        if let lastRefillTime {
            if now > lastRefillTime {
                availableLines = min(
                    burstLines,
                    availableLines + (now - lastRefillTime) * refillLinesPerSecond
                )
                self.lastRefillTime = now
            }
        } else {
            lastRefillTime = now
        }
        let magnitude = min(abs(lines), availableLines)
        availableLines -= magnitude
        return lines < 0 ? -magnitude : magnitude
    }
}
