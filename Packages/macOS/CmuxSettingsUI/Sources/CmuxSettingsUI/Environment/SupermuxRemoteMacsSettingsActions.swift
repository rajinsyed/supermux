import Foundation

/// SUPERMUX — what the Remote Macs card's Ports… menu does with one of another Mac's ports.
public enum SupermuxRemoteMacPortAction: String, Sendable {
    /// Its local URL in the default browser.
    case openInBrowser
    case copyLocalURL
    case stopForwarding
    /// Forward to This Mac.
    case forward
}

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
    /// Turns automatic port forwarding from other Macs on or off.
    public var setForwardPorts: (Bool) -> Void
    /// Runs a Ports… menu item: `(Mac id, its port, action)`.
    public var portAction: (String, Int, SupermuxRemoteMacPortAction) -> Void
    /// Asks for a port of the Mac (by id) to forward by hand.
    public var forwardPort: (String) -> Void
    /// Brings back every remote workspace hidden with "Hide Here".
    public var showHiddenWorkspaces: () -> Void

    public init(
        updates: @escaping () -> AsyncStream<SupermuxRemoteMacsSettingsSnapshot>,
        setAutoMirror: @escaping (Bool) -> Void,
        setSyncProjects: @escaping (Bool) -> Void,
        setSharePush: @escaping (Bool) -> Void,
        showHiddenWorkspaces: @escaping () -> Void,
        setForwardPorts: @escaping (Bool) -> Void = { _ in },
        portAction: @escaping (String, Int, SupermuxRemoteMacPortAction) -> Void = { _, _, _ in },
        forwardPort: @escaping (String) -> Void = { _ in }
    ) {
        self.updates = updates
        self.setAutoMirror = setAutoMirror
        self.setSyncProjects = setSyncProjects
        self.setSharePush = setSharePush
        self.showHiddenWorkspaces = showHiddenWorkspaces
        self.setForwardPorts = setForwardPorts
        self.portAction = portAction
        self.forwardPort = forwardPort
    }
}

/// SUPERMUX — adopted by the app's settings host to serve the Remote Macs card.
@MainActor
public protocol SupermuxRemoteMacsSettingsHosting {
    func supermuxRemoteMacsSettingsActions() -> SupermuxRemoteMacsSettingsActions
}
