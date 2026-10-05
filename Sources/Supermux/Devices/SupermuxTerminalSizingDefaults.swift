import CmuxCloud
import CmuxSurfaceCatalogModel
import CmuxTerminalSharing
import CmuxTerminalSizing
import Foundation
import SupermuxMobileCore
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

    init(
        mode: TerminalSizingMode = .latest,
        priority: [String] = [SupermuxTerminalSizingPreference.selfToken],
        fixed: TerminalGridSize? = nil
    ) {
        self.mode = mode
        self.priority = priority
        self.fixed = fixed
    }

    /// A policy picked on one terminal, its own view on this Mac (`selfKey`)
    /// stored as ``selfToken``.
    init(policy: TerminalSizingPolicy, selfKey: String) {
        self.init(
            mode: policy.mode,
            priority: policy.priority.map { $0 == selfKey ? Self.selfToken : $0 },
            fixed: policy.fixed
        )
    }

    /// The policy for one terminal, ``selfToken`` resolved to `selfKey`.
    func policy(selfKey: String) -> TerminalSizingPolicy {
        var seen = Set<String>()
        let keys = priority.map { $0 == Self.selfToken ? selfKey : $0 }.filter { seen.insert($0).inserted }
        return TerminalSizingPolicy(mode: mode, priority: keys, fixed: fixed)
    }

    /// As JSON for `supermux_preference` (`{mode, priority, fixed}`).
    var wireObject: [String: Any]? {
        (try? JSONEncoder().encode(self)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    /// From `supermux_preference`; nil when malformed or its fixed size is too large.
    init?(wire: Any?) {
        guard let wire, JSONSerialization.isValidJSONObject(wire),
              let data = try? JSONSerialization.data(withJSONObject: wire),
              let decoded = try? JSONDecoder().decode(Self.self, from: data),
              decoded.policy(selfKey: Self.selfToken).fixedSizeIsWithinLimit else { return nil }
        self = decoded
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
/// One setting, wherever it is picked (`sizing-one-setting`, 2026-10-04): a
/// mode the phone's size sheet sends (`mobile.terminal.size_policy.set` from
/// a handheld client) is this Mac's preference too, and a mode picked on a
/// mirror of another Mac's terminal also becomes that Mac's preference: the
/// mirror sends it once, on the pick, with `supermux_preference` to a Mac
/// that advertises `supermux.terminal_sizing_preference.v1` (an older Mac
/// keeps it on that one terminal). A preference that arrives is stored and
/// applied to this Mac's terminals and never sent on, and nothing is sent on
/// a show, a reconnect or a size event, so two Macs cannot bounce it.
///
/// A mirror's claim (`device-mirror-sizing-claim`) is no pick: it only puts
/// this Mac first in one terminal's Priority order. Before 2026-10-03 every
/// mirror pushed this Mac's whole preference whenever it was shown,
/// reconnected or the preference changed, so one "Fit Everyone" picked once
/// on one Mac became the mode of every terminal of the Macs it mirrors, again
/// after each show, and any small pane then shrank them.
///
/// Fixed keeps its size in the one setting (picking Fixed or a fixed size
/// sizes every terminal of this Mac alike, as the panel always did here).
/// Per terminal, as upstream: Cloud terminals, `terminal.size_policy.set`
/// (socket and CLI), Size to My Window, and the counts override ("Don't
/// Resize from This Mac", a device's own "Counts toward size").
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
        if mode == .fixed, next.fixed == nil { next.fixed = Self.fixedSeed(snapshot) }
        choose(next, surfaceID: surfaceID)
        return true
    }

    /// The grid Fixed takes when no fixed size was chosen yet: this window's
    /// own (the Mac pane, or this Mac's mirror pane), not the shared grid,
    /// which may be a phone's. The shared grid when this view has no row
    /// (its view is disconnected). Clamped to the largest fixed grid, which a
    /// full-screen pane on a big display can exceed.
    static func fixedSeed(_ snapshot: TerminalSharingSnapshot) -> TerminalGridSize {
        let seed = snapshot.selfParticipant?.participant.viewport ?? snapshot.state.size
        let limit = TerminalSizingPolicy.maximumFixedSize
        return TerminalGridSize(cols: min(seed.cols, limit.cols), rows: min(seed.rows, limit.rows))
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
        store(next)
        apply(to: surfaceID)
    }

    /// Stores a new preference and applies it to every local terminal when it changed.
    private func store(_ next: SupermuxTerminalSizingPreference) {
        let changed = next != preference
        preference = next
        if let data = try? JSONEncoder().encode(next) { defaults.set(data, forKey: Self.defaultsKey) }
        if changed { applyToLocalTerminals() }
    }

    /// The preference on the one terminal the user acted on: a device mirror
    /// pushes it to the other Mac's terminal (a choice made on that terminal),
    /// with the whole preference for a Mac that adopts it; a local terminal's
    /// sizing host takes it.
    private func apply(to surfaceID: UUID) {
        let controller = TerminalController.shared
        if let session = SupermuxTerminalSizingVisibility.shared.trackedMirrorSessions()[surfaceID] {
            guard let viewer = session.viewer else { return }
            // A Mac that adopts the pick always gets it: its other terminals may differ.
            guard session.supermuxHostTakesSizingPreference()
                || viewer.state?.policy != preference.policy(selfKey: Self.selfKey(of: viewer)) else {
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
        return session.supermuxSendSizingChoice(
            choice.policy(selfKey: Self.selfKey(of: viewer)),
            preference: session.supermuxHostTakesSizingPreference() ? choice.wireObject : nil
        )
    }

    // MARK: - A pick made elsewhere (the phone, another Mac's mirror)

    /// The `mobile.terminal.size_policy.set` field that carries another Mac's
    /// whole setting, as that Mac stores it.
    nonisolated static let preferenceParam = "supermux_preference"

    /// Mirror picks this Mac adopted (DEBUG drivers report it).
    private(set) var adoptedRemoteChoices = 0

    /// Whether `machine` adopts a pick made on its mirror as its own setting.
    static func hostTakesPreference(on machine: SurfaceMachineID) -> Bool {
        SupermuxComposition.devices.cachedHostCapabilities(on: machine)?
            .contains(SupermuxMobileCapability.terminalSizingPreferenceV1.rawValue) == true
    }

    /// `mobile.terminal.size_policy.set` on a terminal of this Mac. Another
    /// Mac's pick (with ``preferenceParam``) or the phone's (a handheld client)
    /// becomes this Mac's preference, applied to every local terminal, and the
    /// terminal it was picked on takes `policy` as sent. False leaves the
    /// request to upstream's per-terminal path: a claim, an older Mac, a Cloud
    /// terminal or a caller that is not a phone.
    func remoteChose(_ policy: TerminalSizingPolicy, params: [String: Any], surfaceID: UUID) -> Bool {
        let controller = TerminalController.shared
        guard let host = controller.localSizingHost(surfaceID: surfaceID, create: true) else { return false }
        if let shared = SupermuxTerminalSizingPreference(wire: params[Self.preferenceParam]) {
            adoptedRemoteChoices += 1
            store(shared)
        } else if Self.isPhone(params["client_id"] as? String, host: host, surfaceID: surfaceID) {
            store(SupermuxTerminalSizingPreference(policy: policy, selfKey: Self.selfKey(of: host)))
        } else {
            return false
        }
        if controller.localSizingHostsBySurfaceID[surfaceID]?.state.policy != policy {
            _ = controller.localSizingSetPolicy(surfaceID: surfaceID, policy: policy)
        }
        return true
    }

    /// A phone or iPad by the device kind it attached (or last reported) with.
    private static func isPhone(_ clientID: String?, host: LocalTerminalSizingHost, surfaceID: UUID) -> Bool {
        guard let clientID else { return false }
        let id = LocalTerminalSizingHost.phoneParticipantID(clientID: clientID)
        let kind = host.state.participant(id)?.participant.deviceKind
            ?? TerminalController.shared.mobileViewportReportsBySurfaceID[surfaceID]?[clientID]?.deviceKind
        return kind?.isHandheld == true
    }

    /// Whether a pick on this terminal's panel reaches another Mac's terminals
    /// too: a mirror of a Mac that adopts it.
    static func reachesOtherMac(surfaceID: UUID) -> Bool {
        SupermuxTerminalSizingVisibility.shared.trackedMirrorSessions()[surfaceID]?
            .supermuxHostTakesSizingPreference() == true
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
/// mode is one choice for every terminal (on both Macs, picked on a mirror of
/// a Mac that adopts it), not this terminal's alone.
struct SupermuxTerminalSizingScopeNote: View {
    var mode: TerminalSizingMode
    var surfaceID: UUID

    /// Upstream's "Follow Latest" (`latest`), named for what it does here.
    nonisolated static var autoTitle: String {
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
            if SupermuxTerminalSizingDefaults.reachesOtherMac(surfaceID: surfaceID) {
                Text(String(
                    localized: "supermux.terminalSizing.appliesToBothMacs",
                    defaultValue: "Applies to all terminals on both Macs."
                ))
            } else {
                Text(String(
                    localized: "supermux.terminalSizing.appliesToAll",
                    defaultValue: "Applies to all terminals on this Mac."
                ))
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}
