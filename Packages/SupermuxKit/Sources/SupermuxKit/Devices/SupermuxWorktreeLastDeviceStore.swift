public import Foundation

/// Remembers the Mac the user last chose for a new worktree, in any project
/// (picked in the sheet, or asked for from "New Worktree on ▸ <Mac>"), so the
/// New Worktree sheet preselects it next time for every project. The planner
/// falls back when that Mac lacks the project or cannot create now, and a
/// create on that fallback leaves it remembered (the sheet model decides).
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

    /// Records the device a worktree was just created on (the sheet model
    /// calls it only for a Mac the user chose, or when nothing is remembered).
    public func record(deviceKey: String) {
        defaults.set(deviceKey, forKey: Self.defaultsKey)
    }
}
