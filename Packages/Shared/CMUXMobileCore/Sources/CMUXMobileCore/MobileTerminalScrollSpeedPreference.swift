import Foundation

/// User preference scaling how many terminal lines a scroll gesture moves.
///
/// Applied to wheel-line delivery (alternate-screen TUIs and other
/// non-position-mapped scroll paths), where each delivered line is a discrete
/// input for the running program, so gesture-to-line sensitivity is a feel
/// preference rather than a geometric mapping. Bounded primary-screen history
/// keeps 1:1 direct manipulation and is deliberately not scaled.
///
/// Pure schema declaration (key/range/default) and two pure functions;
/// `UserDefaults` is already an injected parameter of `resolve(from:)`,
/// so instantiation would add no test seam.
/// lint:allow namespace-enum namespace-type — declaration-only, seamless.
public enum MobileTerminalScrollSpeedPreference {
    /// UserDefaults key, written by Settings and read at surface mount time.
    public static let defaultsKey = "cmux.mobile.terminalScrollSpeed"

    /// Supported multiplier range: quarter speed through 1.5×.
    public static let range: ClosedRange<Double> = 0.25...1.5

    /// Default multiplier: unscaled.
    public static let defaultSpeed = 1.0

    /// Clamps an arbitrary stored or requested value to the supported range.
    /// Non-finite values fall back to the default.
    public static func clamped(_ speed: Double) -> Double {
        guard speed.isFinite else { return defaultSpeed }
        return min(max(speed, range.lowerBound), range.upperBound)
    }

    /// The effective multiplier from `defaults`, falling back to ``defaultSpeed``.
    public static func resolve(from defaults: UserDefaults = .standard) -> Double {
        guard let stored = defaults.object(forKey: defaultsKey) as? Double else {
            return defaultSpeed
        }
        return clamped(stored)
    }
}
