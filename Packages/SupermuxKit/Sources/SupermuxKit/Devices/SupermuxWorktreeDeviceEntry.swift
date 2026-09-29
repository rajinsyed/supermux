public import Foundation

/// Whether a Mac can take a new worktree right now.
public enum SupermuxWorktreeDeviceAvailability: String, Hashable, Sendable {
    /// Connected: creating works.
    case online
    /// The link is dialing or backing off; listed but not selectable.
    case connecting
    /// Unreachable; listed but not selectable.
    case offline
}

/// One row of the New Worktree sheet's device picker: a Mac that has the
/// project (create there) or a connected Mac that lacks it ("Set Up on
/// <Mac>…", which hands off to the setup sheet).
public struct SupermuxWorktreeDeviceEntry: Identifiable, Hashable, Sendable {
    /// What choosing the entry does.
    public enum Action: Hashable, Sendable {
        /// Create the worktree in that Mac's copy of the project.
        case create(SupermuxProjectLocation)
        /// Register the project on that Mac first.
        case setUp(SupermuxProjectSetupDestination)
    }

    /// The device key of this Mac (other Macs use their machine id).
    public static let thisMacKey = "this-mac"

    /// Stable row id: the device key for create rows, `setup:<key>` for set-up rows.
    public let id: String
    /// Which Mac: ``thisMacKey`` or the device's machine id. This is what the
    /// last-device memory stores.
    public let deviceKey: String
    /// The Mac's display name.
    public let name: String
    /// Whether that Mac is reachable.
    public let availability: SupermuxWorktreeDeviceAvailability
    /// What choosing the row does.
    public let action: Action

    /// Creates an entry.
    public init(
        deviceKey: String,
        name: String,
        availability: SupermuxWorktreeDeviceAvailability,
        action: Action
    ) {
        self.deviceKey = deviceKey
        self.name = name
        self.availability = availability
        self.action = action
        switch action {
        case .create: id = deviceKey
        case .setUp: id = "setup:" + deviceKey
        }
    }

    /// The project copy a create row targets.
    public var location: SupermuxProjectLocation? {
        if case .create(let location) = action { return location }
        return nil
    }

    /// The Mac a set-up row registers the project on.
    public var setUpDestination: SupermuxProjectSetupDestination? {
        if case .setUp(let destination) = action { return destination }
        return nil
    }

    /// Whether the row is this Mac.
    public var isThisMac: Bool { deviceKey == Self.thisMacKey }

    /// Whether a worktree can be created there now.
    public var canCreate: Bool { location != nil && availability == .online }

    /// The device key of a project copy.
    public static func deviceKey(of location: SupermuxProjectLocation) -> String {
        location.machineID ?? thisMacKey
    }

    /// The device key of a set-up destination.
    public static func deviceKey(of destination: SupermuxProjectSetupDestination) -> String {
        switch destination {
        case .thisMac: return thisMacKey
        case .device(let device): return device.machineID
        }
    }
}
