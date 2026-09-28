import Foundation
import Testing
@testable import SupermuxKit

/// Ways the auto-mirror reconcile decision could fail (written before the code):
///
/// Opening
/// 1. Opens while the device is still connecting / its records are not fetched
///    since the connect (stale records would resurrect closed workspaces).
/// 2. Opens a second mirror for a remote workspace that already has one (bound
///    or only projected, e.g. a restored placeholder still waiting for the link).
/// 3. Opens a workspace with zero terminals (nothing to mirror).
/// 4. Opens a hidden ("Hide Here") workspace.
/// 5. Opens a ref whose open is already in flight or backing off.
/// 6. Opens in an order other than the remote's sort order.
/// 7. Opens anything with auto-mirror off.
///
/// Closing a mirror whose remote workspace disappeared
/// 8. Closes on the first observation (one transient delta would kill a mirror).
/// 9. Closes when the second observation is less than the interval later.
/// 10. Keeps the suspicion after the workspace reappeared (a later blip closes at once).
/// 11. Closes while the device is offline / reconnecting / not fetched.
/// 12. Closes a mirror of a device that is not registered at all.
/// 13. Stops closing dead mirrors when auto-mirror is off (they stay full of dead panes).
///
/// Orphans (bound mirror whose projections were dropped)
/// 14. Treats an unbound or still-projected mirror as an orphan.
/// 15. Closes an orphan without confirmation, or while its reopen is in flight.
/// 16. Closes orphans when auto-mirror is off (nothing would reopen them).
///
/// Hidden set
/// 17. Keeps hidden refs forever after their remote workspace is gone.
/// 18. Prunes a hidden ref on a single (unconfirmed) or non-authoritative absence.
///
/// Scheduling
/// 19. Reports no follow-up while a suspicion waits for confirmation (it would never confirm).
struct SupermuxMirrorReconcilerTests {
    private typealias Reconciler = SupermuxMirrorReconciler
    private let machine = "device:5E1F10B0-0000-4000-8000-000000000001@dev"
    private let other = "device:AAAAAAAA-0000-4000-8000-000000000002@dev"
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func ref(_ id: String, on machine: String? = nil) -> SupermuxRemoteWorkspaceRef {
        SupermuxRemoteWorkspaceRef(machineID: machine ?? self.machine, workspaceID: id)
    }

    private func remote(_ id: String, terminals: Int = 1, sort: Int = 0) -> Reconciler.RemoteWorkspace {
        Reconciler.RemoteWorkspace(workspaceID: id, terminalCount: terminals, sortIndex: sort)
    }

    private func device(
        _ workspaces: [Reconciler.RemoteWorkspace],
        authoritative: Bool = true,
        machine: String? = nil
    ) -> Reconciler.Device {
        Reconciler.Device(machineID: machine ?? self.machine, isAuthoritative: authoritative, workspaces: workspaces)
    }

    private func mirror(
        _ id: String,
        local: UUID = UUID(),
        bound: Bool = true,
        projected: Bool = true,
        on machine: String? = nil
    ) -> Reconciler.Mirror {
        Reconciler.Mirror(ref: ref(id, on: machine), localWorkspaceID: local, isBound: bound, isProjected: projected)
    }

    private func input(
        autoMirror: Bool = true,
        devices: [Reconciler.Device],
        mirrors: [Reconciler.Mirror] = [],
        hidden: Set<SupermuxRemoteWorkspaceRef> = [],
        busy: Set<SupermuxRemoteWorkspaceRef> = [],
        at seconds: TimeInterval = 0
    ) -> Reconciler.Input {
        Reconciler.Input(
            autoMirror: autoMirror,
            devices: devices,
            mirrors: mirrors,
            hidden: hidden,
            busy: busy,
            now: t0.addingTimeInterval(seconds)
        )
    }

    // MARK: - Opening

    @Test func opensNothingUntilTheDeviceIsAuthoritative() {
        var reconciler = Reconciler()
        let plan = reconciler.plan(input(devices: [device([remote("A")], authoritative: false)]))
        #expect(plan.opens.isEmpty)
    }

    @Test func opensEachUnmirroredWorkspaceOnceInRemoteSortOrder() {
        var reconciler = Reconciler()
        let plan = reconciler.plan(input(
            devices: [device([remote("C", sort: 2), remote("A", sort: 0), remote("B", sort: 1)])],
            mirrors: [mirror("B")]
        ))
        #expect(plan.opens == [ref("A"), ref("C")])
    }

    @Test func aProjectedButUnboundMirrorCountsAsShowingItsWorkspace() {
        var reconciler = Reconciler()
        let plan = reconciler.plan(input(
            devices: [device([remote("A")])],
            mirrors: [mirror("A", bound: false, projected: true)]
        ))
        #expect(plan.opens.isEmpty)
    }

    @Test func skipsEmptyHiddenAndBusyWorkspaces() {
        var reconciler = Reconciler()
        let plan = reconciler.plan(input(
            devices: [device([remote("empty", terminals: 0), remote("hidden"), remote("busy"), remote("ok")])],
            hidden: [ref("hidden")],
            busy: [ref("busy")]
        ))
        #expect(plan.opens == [ref("ok")])
    }

    @Test func refsCompareCaseInsensitivelyForUUIDs() {
        var reconciler = Reconciler()
        let id = "0B3A6F1E-0000-4000-8000-00000000000A"
        let plan = reconciler.plan(input(
            devices: [device([remote(id.lowercased())])],
            mirrors: [mirror(id)]
        ))
        #expect(plan.opens.isEmpty)
    }

    @Test func opensNothingWithAutoMirrorOff() {
        var reconciler = Reconciler()
        let plan = reconciler.plan(input(autoMirror: false, devices: [device([remote("A")])]))
        #expect(plan.opens.isEmpty)
    }

    // MARK: - Remote workspace gone

    @Test func closesAGoneWorkspaceOnlyAfterTwoObservationsAnIntervalApart() {
        var reconciler = Reconciler()
        let local = UUID()
        let dead = mirror("A", local: local)
        let first = reconciler.plan(input(devices: [device([])], mirrors: [dead], at: 0))
        #expect(first.closes.isEmpty)
        let tooSoon = reconciler.plan(input(devices: [device([])], mirrors: [dead], at: 0.4))
        #expect(tooSoon.closes.isEmpty)
        let confirmed = reconciler.plan(input(devices: [device([])], mirrors: [dead], at: 1.2))
        #expect(confirmed.closes == [Reconciler.Close(localWorkspaceID: local, ref: ref("A"), reason: .remoteGone)])
    }

    @Test func aReappearingWorkspaceClearsTheSuspicion() {
        var reconciler = Reconciler()
        let dead = mirror("A")
        _ = reconciler.plan(input(devices: [device([])], mirrors: [dead], at: 0))
        _ = reconciler.plan(input(devices: [device([remote("A")])], mirrors: [dead], at: 0.5))
        let blip = reconciler.plan(input(devices: [device([])], mirrors: [dead], at: 5))
        #expect(blip.closes.isEmpty, "a fresh absence needs its own confirmation")
    }

    @Test func neverClosesWhileTheDeviceIsNotAuthoritative() {
        var reconciler = Reconciler()
        let dead = mirror("A")
        _ = reconciler.plan(input(devices: [device([], authoritative: false)], mirrors: [dead], at: 0))
        let later = reconciler.plan(input(devices: [device([], authoritative: false)], mirrors: [dead], at: 10))
        #expect(later.closes.isEmpty)
    }

    @Test func losingAuthorityResetsTheSuspicion() {
        var reconciler = Reconciler()
        let dead = mirror("A")
        _ = reconciler.plan(input(devices: [device([])], mirrors: [dead], at: 0))
        _ = reconciler.plan(input(devices: [device([], authoritative: false)], mirrors: [dead], at: 1))
        let reconnected = reconciler.plan(input(devices: [device([])], mirrors: [dead], at: 2))
        #expect(reconnected.closes.isEmpty, "the first absence after a reconnect is a new observation")
    }

    @Test func neverClosesMirrorsOfAnUnregisteredDevice() {
        var reconciler = Reconciler()
        let foreign = mirror("A", on: other)
        _ = reconciler.plan(input(devices: [device([])], mirrors: [foreign], at: 0))
        let later = reconciler.plan(input(devices: [device([])], mirrors: [foreign], at: 5))
        #expect(later.closes.isEmpty)
    }

    @Test func closesDeadMirrorsEvenWithAutoMirrorOff() {
        var reconciler = Reconciler()
        let local = UUID()
        let dead = mirror("A", local: local)
        _ = reconciler.plan(input(autoMirror: false, devices: [device([])], mirrors: [dead], at: 0))
        let confirmed = reconciler.plan(input(autoMirror: false, devices: [device([])], mirrors: [dead], at: 2))
        #expect(confirmed.closes.map(\.localWorkspaceID) == [local])
    }

    // MARK: - Orphans

    @Test func closesAConfirmedOrphanSoItCanBeReopened() {
        var reconciler = Reconciler()
        let local = UUID()
        let orphan = mirror("A", local: local, bound: true, projected: false)
        let first = reconciler.plan(input(devices: [device([remote("A")])], mirrors: [orphan], at: 0))
        #expect(first.closes.isEmpty)
        #expect(first.opens.isEmpty, "the orphan still counts as showing its workspace")
        let confirmed = reconciler.plan(input(devices: [device([remote("A")])], mirrors: [orphan], at: 1.5))
        #expect(confirmed.closes == [Reconciler.Close(localWorkspaceID: local, ref: ref("A"), reason: .orphaned)])
    }

    @Test func unboundOrProjectedOrBusyMirrorsAreNotOrphans() {
        var reconciler = Reconciler()
        let mirrors = [
            mirror("A", bound: false, projected: false),
            mirror("B", bound: true, projected: true),
            mirror("C", bound: true, projected: false),
        ]
        let devices = [device([remote("A"), remote("B"), remote("C")])]
        _ = reconciler.plan(input(devices: devices, mirrors: mirrors, busy: [ref("C")], at: 0))
        let later = reconciler.plan(input(devices: devices, mirrors: mirrors, busy: [ref("C")], at: 5))
        #expect(later.closes.isEmpty)
    }

    @Test func orphansStayWithAutoMirrorOff() {
        var reconciler = Reconciler()
        let orphan = mirror("A", bound: true, projected: false)
        _ = reconciler.plan(input(autoMirror: false, devices: [device([remote("A")])], mirrors: [orphan], at: 0))
        let later = reconciler.plan(input(autoMirror: false, devices: [device([remote("A")])], mirrors: [orphan], at: 5))
        #expect(later.closes.isEmpty)
    }

    // MARK: - Hidden set

    @Test func prunesHiddenRefsOnlyAfterAConfirmedAuthoritativeAbsence() {
        var reconciler = Reconciler()
        let hidden: Set = [ref("gone"), ref("here")]
        let devices = [device([remote("here")])]
        let first = reconciler.plan(input(devices: devices, hidden: hidden, at: 0))
        #expect(first.unhide.isEmpty)
        let offline = reconciler.plan(input(devices: [device([], authoritative: false)], hidden: hidden, at: 3))
        #expect(offline.unhide.isEmpty)
        _ = reconciler.plan(input(devices: devices, hidden: hidden, at: 4))
        let confirmed = reconciler.plan(input(devices: devices, hidden: hidden, at: 5.5))
        #expect(confirmed.unhide == [ref("gone")])
    }

    // MARK: - Scheduling

    @Test func asksForAFollowUpWhileASuspicionWaits() {
        var reconciler = Reconciler()
        let plan = reconciler.plan(input(devices: [device([])], mirrors: [mirror("A")], at: 0))
        let followUp = try? #require(plan.followUpAfter)
        #expect((followUp ?? 0) >= reconciler.confirmationInterval)
        var fresh = Reconciler()
        let idle = fresh.plan(input(devices: [device([remote("A")])], mirrors: [mirror("A")]))
        #expect(idle.followUpAfter == nil)
    }
}
