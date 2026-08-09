import Foundation

/// Accumulates fractional alternate-screen scroll lines and emits only whole
/// lines toward the Mac.
///
/// A TUI consumes scroll as discrete wheel ticks, and older Mac hosts
/// interpret each scroll RPC's `delta_lines` as discrete ticks with macOS's
/// minimum-magnitude-1 rounding — so streaming fractional deltas (0.05-line
/// packets at gesture rate) scrolls one full line PER PACKET regardless of
/// magnitude, making speed proportional to packet rate instead of finger
/// travel and rendering the scroll-speed preference imperceptible. Emitting
/// integer lines is interpreted identically by old (discrete) and new
/// (precise-pixel) hosts, restores magnitude-proportional scrolling, and
/// sends far fewer RPCs.
struct TerminalAlternateScrollLineQuantizer: Equatable, Sendable {
    private var fractionCarry = 0.0

    /// Adds `lines` to the carry and returns the whole-line portion now due,
    /// preserving sign. The sub-line remainder carries into the next call, so
    /// a slow drag still scrolls after enough travel accumulates; a direction
    /// reversal unwinds the carry naturally through signed accumulation.
    mutating func emit(lines: Double) -> Double {
        guard lines.isFinite else { return 0 }
        fractionCarry += lines
        let whole = fractionCarry.rounded(.towardZero)
        fractionCarry -= whole
        return whole
    }
}
