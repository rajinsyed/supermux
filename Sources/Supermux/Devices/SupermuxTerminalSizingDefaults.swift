import CmuxCloud
import CmuxSurfaceCatalogModel
import CmuxTerminalSharing
import CmuxTerminalSizing
import Foundation
import SwiftUI

/// How this Mac sizes the terminals it shows: one choice for every terminal.
///
/// `priority` may hold ``selfToken``, which stands for the terminal's own
/// view on this Mac: the Mac pane of a local terminal, this Mac's mirror of
/// another Mac's terminal. One stored order is then right for both.
struct SupermuxTerminalSizingPreference: Codable, Equatable {
    static let selfToken = "self"
    /// The default: Priority with this Mac first, so a terminal fills the
    /// Mac it is looked at from.
    static let standard = SupermuxTerminalSizingPreference()

    var mode: TerminalSizingMode = .priority
    var priority: [String] = [SupermuxTerminalSizingPreference.selfToken]
    var fixed: TerminalGridSize?

    /// The policy for one terminal, ``selfToken`` resolved to `selfKey`.
    func policy(selfKey: String) -> TerminalSizingPolicy {
        var seen = Set<String>()
        let keys = priority.map { $0 == Self.selfToken ? selfKey : $0 }.filter { seen.insert($0).inserted }
        return TerminalSizingPolicy(mode: mode, priority: keys, fixed: fixed)
    }
}

/// Whether a device mirror holds its terminal's grid for this Mac.
///
/// A mirror claims the terminal when it is shown, or first attaches while
/// shown, and pushes this Mac's preference to the other Mac once per
/// connection: again after a reconnect, never in answer to the other Mac's
/// size events or replays, so two Macs cannot push each other in a loop.
/// Hiding the mirror gives the claim up. The Mac that showed it last wins.
struct SupermuxTerminalSizingClaim: Equatable {
    var claimed = false
    var pushed = false
    var hasAttached = false
}

/// This Mac's terminal size preference (`supermux.terminalSizing.preference`).
///
/// Upstream creates every terminal as "Fit everyone" and keeps the policy in
/// memory per terminal, so a phone or a small pane elsewhere shrank a
/// terminal viewed full screen, and a mode chosen in the size panel changed
/// one terminal until the next relaunch. Here the preference (default:
/// Priority with this Mac first) applies to every local terminal as its
/// sizing host is created (`sizing-default-policy`), to every device mirror
/// through its claim (`device-mirror-sizing-claim`), and is replaced by a
/// mode, fixed size or priority order chosen in the size panel or the tab
/// menu, which re-applies it everywhere (`sizing-sticky-preference`).
///
/// Per terminal, as upstream: Cloud terminals, `terminal.size_policy.set`,
/// a phone's or another Mac's choice, Size to My Window, and the counts
/// override ("Don't Resize from This Mac").
@MainActor
final class SupermuxTerminalSizingDefaults {
    static let shared = SupermuxTerminalSizingDefaults()
    static let defaultsKey = "supermux.terminalSizing.preference"

    private let defaults: UserDefaults
    private(set) var preference: SupermuxTerminalSizingPreference

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        preference = defaults.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode(SupermuxTerminalSizingPreference.self, from: $0) }
            ?? .standard
    }

    /// Whether the user chose a preference (else ``SupermuxTerminalSizingPreference/standard`` applies).
    var isStored: Bool { defaults.data(forKey: Self.defaultsKey) != nil }

    // MARK: - Local terminals

    /// Called as a local terminal's sizing host is created, before its first grid.
    func prepareHost(_ host: inout LocalTerminalSizingHost) {
        host.setPolicy(preference.policy(selfKey: Self.selfKey(of: host)))
    }

    /// The Mac pane's priority key in a local terminal.
    static func selfKey(of host: LocalTerminalSizingHost) -> String {
        if let row = host.state.participant(host.macParticipantID) { return row.priorityKey }
        // The pane's view is disconnected: the same identity it attached with.
        return TerminalController.shared.localSizingIdentity()
            .participant(id: host.macParticipantID, deviceKind: .mac)
            .priorityKey
    }

    // MARK: - The user's choice (size panel, tab menu)

    /// The size panel's mode picker and the tab menu's size modes.
    @discardableResult
    func userChoseMode(_ mode: TerminalSizingMode, surfaceID: UUID, store: TerminalSharingStore) -> Bool {
        guard let snapshot = store.snapshot(for: surfaceID), !snapshot.isCloud else {
            return store.setMode(mode, surfaceID: surfaceID)
        }
        var next = preference
        next.mode = mode
        if mode == .fixed, next.fixed == nil { next.fixed = snapshot.state.size }
        choose(next)
        return true
    }

    /// The size panel's fixed-size editor.
    @discardableResult
    func userChoseFixedSize(_ size: TerminalGridSize, surfaceID: UUID, store: TerminalSharingStore) -> Bool {
        guard let snapshot = store.snapshot(for: surfaceID), !snapshot.isCloud else {
            return store.setFixedSize(size, surfaceID: surfaceID)
        }
        var next = preference
        next.mode = .fixed
        next.fixed = size
        choose(next)
        return true
    }

    /// The size panel's priority drag. This terminal's own view on this Mac
    /// is stored as ``SupermuxTerminalSizingPreference/selfToken``.
    @discardableResult
    func userChosePriority(_ keys: [String], surfaceID: UUID, store: TerminalSharingStore) -> Bool {
        guard let snapshot = store.snapshot(for: surfaceID), !snapshot.isCloud else {
            return store.setPriority(keys, surfaceID: surfaceID)
        }
        let selfKey = snapshot.selfParticipant?.priorityKey
        var next = preference
        next.priority = keys.map { $0 == selfKey ? SupermuxTerminalSizingPreference.selfToken : $0 }
        choose(next)
        return true
    }

    /// Forgets the user's choice and applies the default everywhere.
    func reset() {
        defaults.removeObject(forKey: Self.defaultsKey)
        preference = .standard
        applyEverywhere()
    }

    private func choose(_ next: SupermuxTerminalSizingPreference) {
        preference = next
        if let data = try? JSONEncoder().encode(next) { defaults.set(data, forKey: Self.defaultsKey) }
        applyEverywhere()
    }

    /// Local terminals first, then device mirrors: in the loopback a source
    /// terminal is both, and the mirror's claim lands last.
    private func applyEverywhere() {
        let controller = TerminalController.shared
        for (surfaceID, host) in controller.localSizingHostsBySurfaceID {
            let policy = preference.policy(selfKey: Self.selfKey(of: host))
            guard host.state.policy != policy else { continue }
            _ = controller.localSizingSetPolicy(surfaceID: surfaceID, policy: policy)
        }
        for (_, session) in SupermuxTerminalSizingVisibility.shared.trackedMirrorSessions() {
            session.supermuxSizingClaim.claimed = !session.supermuxHidden
            session.supermuxSizingClaim.pushed = push(session)
        }
    }

    // MARK: - Device mirrors

    /// The mirror's pane came on screen or went off it.
    func mirrorVisibilityChanged(_ session: DeviceTerminalMirrorSession) {
        guard !session.supermuxHidden else {
            session.supermuxSizingClaim.claimed = false
            return
        }
        session.supermuxSizingClaim.claimed = true
        session.supermuxSizingClaim.pushed = false
        pushClaim(session)
    }

    /// An attach stuck: the first one claims if the pane is shown, and a
    /// claim not yet pushed on this connection is pushed now.
    func mirrorAttached(_ session: DeviceTerminalMirrorSession) {
        if !session.supermuxSizingClaim.hasAttached {
            session.supermuxSizingClaim.hasAttached = true
            if !session.supermuxHidden { session.supermuxSizingClaim.claimed = true }
        }
        pushClaim(session)
    }

    /// The link dropped: the other Mac may come back with its own default.
    func connectionDropped(_ session: DeviceTerminalMirrorSession) {
        session.supermuxSizingClaim.pushed = false
    }

    private func pushClaim(_ session: DeviceTerminalMirrorSession) {
        guard session.supermuxSizingClaim.claimed, !session.supermuxSizingClaim.pushed else { return }
        session.supermuxSizingClaim.pushed = push(session)
    }

    /// Sends this Mac's preference for the mirror's terminal. Unconditional:
    /// after the other Mac restarts, the state this Mac last saw can be stale,
    /// and the other Mac ignores a policy it already has.
    private func push(_ session: DeviceTerminalMirrorSession) -> Bool {
        guard session.phase == .attached, let viewer = session.viewer, viewer.detachment == nil else { return false }
        return session.sharingSetPolicy(preference.policy(selfKey: Self.selfKey(of: viewer)))
    }

    /// This Mac's priority key in another Mac's terminal: as that Mac
    /// published it, else as it builds it (same account on both Macs).
    static func selfKey(of viewer: RemoteMacTerminalViewer) -> String {
        if let row = viewer.snapshot?.selfParticipant { return row.priorityKey }
        return TerminalSizingParticipant(
            id: LocalTerminalSizingHost.phoneParticipantID(clientID: viewer.clientID),
            userID: viewer.identity.userID,
            deviceKind: .mac,
            deviceID: viewer.identity.deviceID
        ).priorityKey
    }

    // MARK: - Viewer identity

    /// This Mac's sizing identity as a viewer of `instance`'s terminals.
    ///
    /// DEBUG: the loopback device's host is this very app, so its mirrors
    /// would share the source pane's priority key. They get a distinct
    /// device id instead, as a second real Mac has. Release builds always
    /// use this Mac's own identity.
    static func viewerIdentity(for instance: SurfaceDeviceInstanceID) -> TerminalSharingIdentity {
        var identity = TerminalController.shared.localSizingIdentity()
        #if DEBUG
        if instance.deviceID == SupermuxDeviceLoopbackIdentity.deviceID {
            identity.deviceID = TerminalSharingIdentity.sizingDeviceID(
                installID: "loopback-viewer:" + MobileHostIdentity.deviceID()
            )
        }
        #endif
        return identity
    }
}

/// The size panel's note under the mode picker: the mode is this Mac's
/// choice for every terminal, not this terminal's alone.
struct SupermuxTerminalSizingScopeNote: View {
    var body: some View {
        Text(String(
            localized: "supermux.terminalSizing.appliesToAll",
            defaultValue: "Applies to all terminals on this Mac."
        ))
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}
