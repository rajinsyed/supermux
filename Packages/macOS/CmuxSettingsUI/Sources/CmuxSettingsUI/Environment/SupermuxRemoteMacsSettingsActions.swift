import Foundation

/// SUPERMUX — the app services behind the Remote Macs settings card.
///
/// The settings section stack has no app-side injection seam and this
/// package cannot import `SupermuxKit`, so the app's settings host adopts
/// ``SupermuxRemoteMacsSettingsHosting`` in a fork-owned extension and the
/// card finds it with a dynamic cast. Without a host (previews, upstream
/// hosts) the card shows only upstream's discoverability status.
@MainActor
public struct SupermuxRemoteMacsSettingsActions {
    /// The current snapshot first, then one per change.
    public var updates: () -> AsyncStream<SupermuxRemoteMacsSettingsSnapshot>
    /// Turns auto-mirror on or off; takes effect at once (mirror reconcile).
    public var setAutoMirror: (Bool) -> Void
    /// Turns cross-Mac project sync on or off (a pass runs when turned on).
    public var setSyncProjects: (Bool) -> Void
    /// Turns phone-push setup sharing between Macs on or off.
    public var setSharePush: (Bool) -> Void
    /// Brings back every remote workspace hidden with "Hide Here".
    public var showHiddenWorkspaces: () -> Void

    public init(
        updates: @escaping () -> AsyncStream<SupermuxRemoteMacsSettingsSnapshot>,
        setAutoMirror: @escaping (Bool) -> Void,
        setSyncProjects: @escaping (Bool) -> Void,
        setSharePush: @escaping (Bool) -> Void,
        showHiddenWorkspaces: @escaping () -> Void
    ) {
        self.updates = updates
        self.setAutoMirror = setAutoMirror
        self.setSyncProjects = setSyncProjects
        self.setSharePush = setSharePush
        self.showHiddenWorkspaces = showHiddenWorkspaces
    }
}

/// SUPERMUX — adopted by the app's settings host to serve the Remote Macs card.
@MainActor
public protocol SupermuxRemoteMacsSettingsHosting {
    func supermuxRemoteMacsSettingsActions() -> SupermuxRemoteMacsSettingsActions
}
