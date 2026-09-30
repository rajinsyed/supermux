public import Foundation

/// Remembers, per unified project, the Mac the last worktree was created on,
/// so the New Worktree sheet preselects it next time.
///
/// Stored in this app's `UserDefaults` under ``defaultsKey`` as
/// `[unified project id: device key]` (device key =
/// ``SupermuxWorktreeDeviceEntry/thisMacKey`` or a machine id).
///
/// Isolation: a stateless value over an immutable `UserDefaults` reference,
/// whose API is documented thread-safe.
public struct SupermuxWorktreeLastDeviceStore: Sendable {
    /// The defaults key.
    public static let defaultsKey = "supermux.newWorktree.lastDevice.v1"

    private nonisolated(unsafe) let defaults: UserDefaults

    /// Creates the store over a defaults suite (injectable for tests).
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The device last used for `projectID`, if any.
    public func deviceKey(forProject projectID: UUID) -> String? {
        stored()[projectID.uuidString]
    }

    /// Records the device a worktree was just created on.
    public func record(deviceKey: String, forProject projectID: UUID) {
        var map = stored()
        map[projectID.uuidString] = deviceKey
        defaults.set(map, forKey: Self.defaultsKey)
    }

    /// The stored map, ignoring anything that is not a string entry.
    private func stored() -> [String: String] {
        guard let raw = defaults.dictionary(forKey: Self.defaultsKey) else { return [:] }
        return raw.compactMapValues { $0 as? String }
    }
}
