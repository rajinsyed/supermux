public import Foundation

/// Remembers the Mac the last worktree was created on, in any project, so
/// the New Worktree sheet preselects it next time for every project (the
/// planner falls back when that Mac lacks the project or cannot create now).
///
/// Stored in this app's `UserDefaults` under ``defaultsKey`` as one device
/// key string (``SupermuxWorktreeDeviceEntry/thisMacKey`` or a machine id).
/// The per-project map of `supermux.newWorktree.lastDevice.v1` is not read.
///
/// Isolation: a stateless value over an immutable `UserDefaults` reference,
/// whose API is documented thread-safe.
public struct SupermuxWorktreeLastDeviceStore: Sendable {
    /// The defaults key.
    public static let defaultsKey = "supermux.newWorktree.lastDevice.v2"

    private nonisolated(unsafe) let defaults: UserDefaults

    /// Creates the store over a defaults suite (injectable for tests).
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The device the last worktree was created on, if any (a stored value
    /// that is not a string reads as nothing).
    public func deviceKey() -> String? {
        defaults.object(forKey: Self.defaultsKey) as? String
    }

    /// Records the device a worktree was just created on.
    public func record(deviceKey: String) {
        defaults.set(deviceKey, forKey: Self.defaultsKey)
    }
}
