public import Foundation

/// The sentence the New Worktree sheet shows when creating on another Mac
/// fails: a translation of the wire / link error code, or the other Mac's own
/// (already localized) sentence when it is specific.
public enum SupermuxRemoteWorktreeFailure {
    /// A user-facing message for a failed remote worktree operation.
    ///
    /// - Parameters:
    ///   - code: The error code (`SupermuxDeviceError.code` or the host's
    ///     wire code), if any.
    ///   - hostMessage: The message that came with it.
    ///   - deviceName: The other Mac's name.
    public static func message(code: String?, hostMessage: String?, deviceName: String) -> String {
        let host = hostMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch code {
        case "not_connected", "unknown_device", "timeout":
            return String(
                localized: "supermux.newWorktree.remoteError.offline",
                defaultValue: "\(deviceName) is not reachable right now. Choose another Mac, or try again when it reconnects."
            )
        case "dirty_worktree":
            return String(
                localized: "supermux.newWorktree.remoteError.dirty",
                defaultValue: "The worktree on \(deviceName) has uncommitted changes."
            )
        case "ai_unavailable":
            return String(
                localized: "supermux.newWorktree.remoteError.aiUnavailable",
                defaultValue: "AI naming is not set up on \(deviceName). Type a branch name, or leave it blank for a random one."
            )
        case "not_found":
            return String(
                localized: "supermux.newWorktree.remoteError.notFound",
                defaultValue: "This project is no longer registered on \(deviceName)."
            )
        case "method_not_found", "unsupported":
            return String(
                localized: "supermux.newWorktree.remoteError.outdated",
                defaultValue: "\(deviceName) runs an older Supermux that cannot do this. Update Supermux there and try again."
            )
        default:
            if !host.isEmpty { return host }
            return String(
                localized: "supermux.newWorktree.remoteError.generic",
                defaultValue: "\(deviceName) could not create the worktree."
            )
        }
    }
}
