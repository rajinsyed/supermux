public import Foundation

/// Fork-owned preferences for remote Macs ("devices").
///
/// ```swift
/// let settings = SupermuxDevicesSettings(defaults: .standard)
/// if settings.autoMirror { … }
/// ```
public struct SupermuxDevicesSettings {
    /// Whether every workspace on every connected Mac automatically gets a
    /// local mirror workspace. Defaults to on.
    public static let autoMirrorKey = "supermux.devices.autoMirror"
    /// Whether this Mac shares its direct-APNs credentials and known phone
    /// registrations with the user's other Macs over the device link (and
    /// accepts theirs). Defaults to on.
    public static let sharePushKey = "supermux.devices.sharePush"

    private let defaults: UserDefaults

    /// Creates an accessor over a defaults domain.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Auto-mirror remote workspaces into the local sidebar (default `true`).
    public var autoMirror: Bool {
        get { defaults.object(forKey: Self.autoMirrorKey) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Self.autoMirrorKey) }
    }

    /// Share phone-push credentials and registrations between Macs (default `true`).
    public var sharePush: Bool {
        get { defaults.object(forKey: Self.sharePushKey) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Self.sharePushKey) }
    }

    /// Whether each Mac registers the other Macs' projects whose repo it
    /// already has at the same path (never clones, never deletes).
    public static let syncProjectsKey = "supermux.devices.syncProjects"

    /// Cross-Mac project sync (default `true`).
    public var syncProjects: Bool {
        get { defaults.object(forKey: Self.syncProjectsKey) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Self.syncProjectsKey) }
    }
}
