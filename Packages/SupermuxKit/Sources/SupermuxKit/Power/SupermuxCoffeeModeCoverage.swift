/// Describes whether Coffee Mode is active and actually keeping the Mac awake.
///
/// The state is intentionally small. Coffee Mode holds one public IOKit
/// assertion—the app-scoped equivalent of `caffeinate -i`—which prevents idle
/// system sleep while still allowing the display to turn off normally.
public struct SupermuxCoffeeModeCoverage: Sendable, Equatable {
    /// Whether the user has Coffee Mode switched on.
    public let isActive: Bool

    /// Whether macOS granted the idle-system-sleep assertion.
    public let keepsSystemAwake: Bool

    /// Creates a Coffee Mode coverage snapshot.
    ///
    /// - Parameters:
    ///   - isActive: Whether Coffee Mode is switched on.
    ///   - keepsSystemAwake: Whether the keep-awake assertion is held.
    public init(isActive: Bool, keepsSystemAwake: Bool) {
        self.isActive = isActive
        self.keepsSystemAwake = keepsSystemAwake
    }

    /// The inactive state, with no keep-awake assertion held.
    public static let off = SupermuxCoffeeModeCoverage(
        isActive: false,
        keepsSystemAwake: false
    )

    /// Whether Coffee Mode is on but macOS refused its keep-awake assertion.
    public var isDegraded: Bool {
        isActive && !keepsSystemAwake
    }
}
