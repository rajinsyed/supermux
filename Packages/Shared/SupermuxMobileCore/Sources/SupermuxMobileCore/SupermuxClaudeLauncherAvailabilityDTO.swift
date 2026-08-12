/// Availability information for one Mac-side Claude launcher.
public struct SupermuxClaudeLauncherAvailabilityDTO: Codable, Sendable, Equatable {
    /// Launcher represented by this row.
    public var launcher: SupermuxClaudeLauncher
    /// Whether the Mac can launch it now.
    public var available: Bool
    /// User-facing launcher label.
    public var displayName: String
    /// Bounded unavailability explanation, when any.
    public var unavailableReason: String?

    /// Creates launcher availability information.
    /// - Parameters:
    ///   - launcher: Launcher represented by this row.
    ///   - available: Whether the launcher is available.
    ///   - displayName: User-facing launcher label.
    ///   - unavailableReason: Optional bounded explanation.
    public init(
        launcher: SupermuxClaudeLauncher,
        available: Bool,
        displayName: String,
        unavailableReason: String? = nil
    ) {
        self.launcher = launcher
        self.available = available
        self.displayName = displayName
        self.unavailableReason = unavailableReason
    }

    private enum CodingKeys: String, CodingKey {
        case launcher
        case available
        case displayName = "display_name"
        case unavailableReason = "unavailable_reason"
    }
}
