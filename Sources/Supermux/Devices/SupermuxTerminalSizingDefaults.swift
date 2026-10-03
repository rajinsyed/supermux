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
    /// The default: Auto (`latest`, ``SupermuxTerminalSizingAuto``), so the
    /// device the user is viewing a terminal from (this Mac, a phone, another
    /// Mac) sets its grid. The order keeps this Mac first for when Priority
    /// is chosen.
    static let standard = SupermuxTerminalSizingPreference()

    var mode: TerminalSizingMode = .latest
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
/// shown, once per connection: again after a reconnect, never in answer to
/// the other Mac's size events or replays, so two Macs cannot push each other
/// in a loop. The claim only puts this Mac first in the terminal's Priority
/// order (``SupermuxTerminalSizingDefaults/claimPolicy(_:selfKey:)``): the
/// mode, the fixed size and the rest of the order stay what was chosen on
/// that terminal. Hiding the mirror gives the claim up. The Mac that showed
/// it last wins.
struct SupermuxTerminalSizingClaim: Equatable {
    var claimed = false
    var pushed = false
    var hasAttached = false
    /// A choice made on this mirror's terminal (its size panel or tab menu)
    /// while the mirror was not attached, so it could not be sent: it goes
    /// on the next attach that sticks, before any claim, then is cleared.
    var pendingChoice: SupermuxTerminalSizingPreference?
}

/// This Mac's terminal size preference (`supermux.terminalSizing.preference`).
///
/// Upstream keeps the policy in memory per terminal, so a mode chosen in the
/// size panel changed one terminal until the next relaunch. Here the
/// preference (default: Auto, where the device the user is viewing from sets
/// the grid, ``SupermuxTerminalSizingAuto``; it was Fit everyone until
/// 2026-10-04, and Priority with this Mac first until 2026-10-03, so a
/// terminal opened from the phone did not fit the phone) applies to every
/// local terminal as its
/// sizing host is created (`sizing-default-policy`), and is replaced by a
/// mode, fixed size or priority order chosen in the size panel or the tab
/// menu, which re-applies it to every local terminal and to the terminal it
/// was chosen on (`sizing-sticky-preference`).
///
/// Another Mac's terminal changes policy only by a choice made on it: the
/// size panel or tab menu of the mirror that shows it. A sticky choice made
/// here never reaches the other terminals this Mac mirrors, and a mirror's
/// claim (`device-mirror-sizing-claim`) only puts this Mac first in a
/// Priority order. Before, every mirror pushed this Mac's whole preference
/// whenever it was shown, reconnected or the preference changed, so one
/// "Fit Everyone" picked on one Mac became the mode of every terminal of the
/// Macs it mirrors, again after each show, and any small pane then shrank them.
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
        SupermuxTerminalSizingAuto.shared.start()
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
        choose(next, surfaceID: surfaceID)
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
        choose(next, surfaceID: surfaceID)
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
        choose(next, surfaceID: surfaceID)
        return true
    }

    /// Forgets the user's choice and applies the default to this Mac's terminals.
    func reset() {
        defaults.removeObject(forKey: Self.defaultsKey)
        preference = .standard
        applyToLocalTerminals()
    }

    /// A new preference applies to every local terminal. The terminal the user
    /// acted on (`surfaceID`, a mirror's included) takes it whenever its own
    /// policy differs, also when the preference did not change, as upstream's
    /// `setMode` compares against the terminal's own policy: another Mac, a
    /// phone, `terminal.size_policy.set` or Size to My Window may have changed
    /// it. No other terminal of another Mac is touched, and re-choosing the
    /// current preference leaves every other terminal alone, so the tab menu's
    /// Priority and Fixed (which mostly open the panel) never take back
    /// terminals other Macs claimed.
    private func choose(_ next: SupermuxTerminalSizingPreference, surfaceID: UUID) {
        let changed = next != preference
        preference = next
        if let data = try? JSONEncoder().encode(next) { defaults.set(data, forKey: Self.defaultsKey) }
        if changed { applyToLocalTerminals() }
        apply(to: surfaceID)
    }

    /// The preference on the one terminal the user acted on: a device mirror
    /// pushes it to the other Mac's terminal (a choice made on that terminal);
    /// a local terminal's sizing host takes it.
    private func apply(to surfaceID: UUID) {
        let controller = TerminalController.shared
        if let session = SupermuxTerminalSizingVisibility.shared.trackedMirrorSessions()[surfaceID] {
            guard let viewer = session.viewer else { return }
            guard viewer.state?.policy != preference.policy(selfKey: Self.selfKey(of: viewer)) else {
                // The terminal already has it: an earlier pick still waiting is outdated.
                session.supermuxSizingClaim.pendingChoice = nil
                return
            }
            session.supermuxSizingClaim.claimed = !session.supermuxHidden
            let sent = pushChoice(session, preference)
            session.supermuxSizingClaim.pushed = sent
            session.supermuxSizingClaim.pendingChoice = sent ? nil : preference
        } else if let host = controller.localSizingHostsBySurfaceID[surfaceID] {
            let policy = preference.policy(selfKey: Self.selfKey(of: host))
            guard host.state.policy != policy else { return }
            _ = controller.localSizingSetPolicy(surfaceID: surfaceID, policy: policy)
        }
    }

    /// Every terminal of this Mac. In the loopback a source terminal is also
    /// the mirror's terminal: a choice made on the mirror lands after this.
    private func applyToLocalTerminals() {
        let controller = TerminalController.shared
        for (surfaceID, host) in controller.localSizingHostsBySurfaceID {
            let policy = preference.policy(selfKey: Self.selfKey(of: host))
            guard host.state.policy != policy else { continue }
            _ = controller.localSizingSetPolicy(surfaceID: surfaceID, policy: policy)
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

    /// A choice made on this terminal while the mirror was detached goes
    /// first (a reconnect's claim alone would only reorder Priority and lose
    /// it); otherwise the claim, once per connection.
    private func pushClaim(_ session: DeviceTerminalMirrorSession) {
        if let choice = session.supermuxSizingClaim.pendingChoice {
            guard pushChoice(session, choice) else { return }
            session.supermuxSizingClaim.pendingChoice = nil
            session.supermuxSizingClaim.pushed = true
            return
        }
        guard session.supermuxSizingClaim.claimed, !session.supermuxSizingClaim.pushed else { return }
        session.supermuxSizingClaim.pushed = claim(session)
    }

    /// Puts this Mac first in the other Mac's Priority order, as that Mac
    /// published it (the replay that attached the mirror carried it). Any other
    /// mode was chosen on that terminal: nothing to claim, and the claim counts
    /// as made for this connection.
    private func claim(_ session: DeviceTerminalMirrorSession) -> Bool {
        guard session.phase == .attached, let viewer = session.viewer, viewer.detachment == nil,
              let current = viewer.state?.policy else { return false }
        guard let policy = Self.claimPolicy(current, selfKey: Self.selfKey(of: viewer)) else { return true }
        return session.sharingSetPolicy(policy)
    }

    /// What a shown mirror asks of another Mac's terminal: under Priority,
    /// this Mac's view first and the rest of that Mac's order after it, the
    /// fixed size kept. Nil when there is nothing to claim: another mode, or
    /// this Mac already first.
    static func claimPolicy(_ current: TerminalSizingPolicy, selfKey: String) -> TerminalSizingPolicy? {
        guard current.mode == .priority, current.priority.first != selfKey else { return nil }
        return TerminalSizingPolicy(
            mode: .priority,
            priority: [selfKey] + current.priority.filter { $0 != selfKey },
            fixed: current.fixed
        )
    }

    /// Sends a choice made on the terminal the user acted on through its
    /// mirror. False while the mirror is not attached (the caller keeps it
    /// pending). Unconditional otherwise: after the other Mac restarts, the
    /// state this Mac last saw can be stale, and the other Mac ignores a
    /// policy it already has.
    private func pushChoice(_ session: DeviceTerminalMirrorSession, _ choice: SupermuxTerminalSizingPreference) -> Bool {
        guard session.phase == .attached, let viewer = session.viewer, viewer.detachment == nil else { return false }
        return session.sharingSetPolicy(choice.policy(selfKey: Self.selfKey(of: viewer)))
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

    /// The largest viewport this Mac takes from a viewer
    /// (`device-mirror-viewport-limit`): upstream's 300 x 120 for a phone, and
    /// the largest fixed grid (500 x 200) for a viewing Mac, whose full-screen
    /// pane on a big display is larger than 300 x 120 and was letterboxed.
    static func viewportLimit(deviceKind: TerminalDeviceKind?) -> TerminalGridSize {
        deviceKind == .mac ? TerminalSizingPolicy.maximumFixedSize : TerminalGridSize(cols: 300, rows: 120)
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

/// The size panel's note under the mode picker: what Auto does, and that the
/// mode is this Mac's choice for every terminal, not this terminal's alone.
struct SupermuxTerminalSizingScopeNote: View {
    var mode: TerminalSizingMode

    /// Upstream's "Follow Latest" (`latest`), named for what it does here.
    static var autoTitle: String {
        String(localized: "supermux.terminalSizing.mode.auto", defaultValue: "Auto")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if mode == .latest {
                Text(String(
                    localized: "supermux.terminalSizing.autoDescription",
                    defaultValue: "The device you're using sets the size."
                ))
            }
            Text(String(
                localized: "supermux.terminalSizing.appliesToAll",
                defaultValue: "Applies to all terminals on this Mac."
            ))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}
