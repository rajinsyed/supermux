// SUPERMUX:begin mobile-startup-parallel-secondary (regression coverage — see SUPERMUX-TOUCHPOINTS.md)
import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileRPC
import Foundation
import Testing
@testable import CmuxMobileShell

/// Field log (2026-10-04): at launch the second Mac started dialing only after
/// the first had connected and its workspace list had returned (about 0.6 s
/// later, plus its own dial), so its workspaces went live about 1 s after the
/// first Mac's.
@MainActor
@Suite(.serialized)
struct SupermuxStartupParallelSecondaryTests {
    @Test func launchDialsTheOtherMacBesideTheForegroundOne() async throws {
        let fixture = try await TwoMacFixture()
        defer { fixture.cleanUp() }
        // The foreground Mac's connect stalls on its host status.
        await fixture.foregroundRouter.delayHostStatusRequest(number: 1)

        let restore = Task { @MainActor in
            await fixture.shell.reconnectActiveMacIfAvailable(stackUserID: "user-1", hydratePairedMacs: true)
        }
        #expect(await fixture.foregroundRouter.waitForCount(of: "mobile.host.status", atLeast: 1))
        // The other Mac connects while the foreground Mac is still connecting.
        #expect(await fixture.otherRouter.waitForCount(
            of: "mobile.host.status", atLeast: 1, timeoutNanoseconds: 2_000_000_000))

        await fixture.foregroundRouter.releaseAllHeld()
        #expect(await restore.value)
        #expect(fixture.shell.foregroundMacDeviceIDForTesting() == "mac-foreground")
        #expect(try await pollUntil {
            fixture.shell.secondaryMacSubscriptions[fixture.otherKey] != nil
        })
        // The foreground Mac never got a second, secondary session.
        #expect(fixture.shell.secondaryMacSubscriptions[fixture.foregroundKey] == nil)
        fixture.shell.secondaryMacSubscriptions[fixture.otherKey]?.cancel()
    }

    /// The phone's paired-Mac store refreshes from the account backup over
    /// the network; the launch pass must not wait for it (field: the other
    /// Mac still dialed 1.5 s after launch).
    @Test func launchDialsTheOtherMacWhileTheBackupRefreshIsInFlight() async throws {
        let fixture = try await TwoMacFixture(backupBacked: true)
        defer { fixture.cleanUp() }
        let backup = try #require(fixture.backupStore)
        await backup.blockBackupRefreshForEveryCaller()
        await fixture.foregroundRouter.delayHostStatusRequest(number: 1)

        let restore = Task { @MainActor in
            await fixture.shell.reconnectActiveMacIfAvailable(stackUserID: "user-1", hydratePairedMacs: true)
        }
        #expect(await fixture.foregroundRouter.waitForCount(of: "mobile.host.status", atLeast: 1))
        #expect(await fixture.otherRouter.waitForCount(
            of: "mobile.host.status", atLeast: 1, timeoutNanoseconds: 2_000_000_000))

        await fixture.foregroundRouter.releaseAllHeld()
        await backup.releaseBackupRefresh()
        #expect(await restore.value)
        fixture.shell.secondaryMacSubscriptions[fixture.otherKey]?.cancel()
    }

    @Test func otherMacTakesOverTheForegroundWhenTheFirstIsOffline() async throws {
        // The foreground candidate is unreachable, so the reconnect falls
        // back to the Mac the launch already dialed beside it.
        let fixture = try await TwoMacFixture(foregroundReachable: false)
        defer { fixture.cleanUp() }

        #expect(await fixture.shell.reconnectActiveMacIfAvailable(stackUserID: "user-1", hydratePairedMacs: true))
        #expect(fixture.shell.connectionState == .connected)
        #expect(fixture.shell.foregroundMacDeviceIDForTesting() == "mac-other")
        #expect(fixture.shell.secondaryMacSubscriptions[fixture.otherKey] == nil)
    }

    /// A saved Mac that is offline at launch fails the launch pass's dial.
    /// That failure must not keep the pass that runs once the foreground
    /// connects from finding a Mac this phone has not saved yet.
    @Test func launchWithAnOfflineSavedMacStillFindsANewMac() async throws {
        let fixture = try await TwoMacFixture(otherReachable: false, discoversNewMac: true)
        defer { fixture.cleanUp() }

        #expect(await fixture.shell.reconnectActiveMacIfAvailable(stackUserID: "user-1", hydratePairedMacs: true))
        #expect(try await pollUntil {
            fixture.shell.secondaryMacSubscriptions[fixture.newKey] != nil
        })
        fixture.shell.secondaryMacSubscriptions[fixture.newKey]?.cancel()
    }
}

/// Two saved Macs, each served by its own scripted host, and optionally a
/// third, unsaved Mac that account discovery reports.
@MainActor
private struct TwoMacFixture {
    let directory: URL
    let foregroundRouter = LivenessHostRouter()
    let otherRouter = LivenessHostRouter()
    let newRouter = LivenessHostRouter()
    let shell: MobileShellComposite
    let foregroundKey = MacPairingKey(macDeviceID: "mac-foreground", instanceTag: "default")
    let otherKey = MacPairingKey(macDeviceID: "mac-other", instanceTag: "default")
    let newKey = MacPairingKey(macDeviceID: "mac-new", instanceTag: "default")

    let backupStore: DelayedTeamPairedMacStore?

    init(
        foregroundReachable: Bool = true,
        otherReachable: Bool = true,
        backupBacked: Bool = false,
        discoversNewMac: Bool = false
    ) async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let foregroundRoute = try Self.irohRoute(endpointID: Self.foregroundEndpoint)
        let otherRoute = try Self.irohRoute(endpointID: Self.otherEndpoint)
        let now = Date()
        let store: any MobilePairedMacStoring
        if backupBacked {
            let backup = DelayedTeamPairedMacStore(recordsByTeam: ["": [
                MobilePairedMac(macDeviceID: "mac-foreground", displayName: "Foreground Mac",
                    routes: [foregroundRoute], createdAt: now, lastSeenAt: now, isActive: true,
                    stackUserID: "user-1", instanceTag: "default"),
                MobilePairedMac(macDeviceID: "mac-other", displayName: "Other Mac",
                    routes: [otherRoute], createdAt: now, lastSeenAt: now.addingTimeInterval(-60), isActive: false,
                    stackUserID: "user-1", instanceTag: "default"),
            ]], blockedTeams: [])
            backupStore = backup
            store = backup
        } else {
            let local = try MobilePairedMacStore(databaseURL: directory.appendingPathComponent("paired.sqlite3"))
            try await local.upsert(
                macDeviceID: "mac-other", displayName: "Other Mac", routes: [otherRoute], instanceTag: "default",
                markActive: false, stackUserID: "user-1", teamID: nil, now: now.addingTimeInterval(-60))
            try await local.upsert(
                macDeviceID: "mac-foreground", displayName: "Foreground Mac", routes: [foregroundRoute],
                instanceTag: "default", markActive: true, stackUserID: "user-1", teamID: nil, now: now)
            backupStore = nil
            store = local
        }
        await foregroundRouter.setHostIdentity(
            deviceID: "mac-foreground", instanceTag: "default", displayName: "Foreground Mac")
        await otherRouter.setHostIdentity(deviceID: "mac-other", instanceTag: "default", displayName: "Other Mac")
        await foregroundRouter.setAttachTicketMac(deviceID: "mac-foreground", displayName: "Foreground Mac", port: 56_701)
        await otherRouter.setAttachTicketMac(deviceID: "mac-other", displayName: "Other Mac", port: 56_702)
        await newRouter.setHostIdentity(deviceID: "mac-new", instanceTag: "default", displayName: "New Mac")
        await newRouter.setAttachTicketMac(deviceID: "mac-new", displayName: "New Mac", port: 56_703)
        var routers = [Self.newEndpoint: newRouter]
        if foregroundReachable { routers[Self.foregroundEndpoint] = foregroundRouter }
        if otherReachable { routers[Self.otherEndpoint] = otherRouter }
        let discovered = discoversNewMac ? [MobileDiscoveredIrohMac(
            deviceID: "mac-new", displayName: "New Mac", instanceTag: "default",
            routes: [try Self.irohRoute(endpointID: Self.newEndpoint)], lastSeenAt: now)] : []
        shell = MobileShellComposite(
            runtime: LivenessTestRuntime(
                transportFactory: PerRouteTransportFactory(routers: routers),
                now: { Date() },
                supportedRouteKinds: [.iroh]
            ),
            isSignedIn: true,
            pairedMacStore: store,
            personalIrohDiscovery: ScriptedIrohDiscovery(snapshots: [discovered]),
            // With presence, a failed dial arms the shared retry. Its clock
            // never advances, so the retry stays armed for the whole test.
            presence: discoversNewMac ? IdlePresence() : nil,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            reachability: AlwaysOnlineReachability(),
            controlPlaneSchedulingClock: ControlPoolManualClock()
        )
    }

    static let foregroundEndpoint = String(repeating: "a", count: 64)
    static let otherEndpoint = String(repeating: "b", count: 64)
    static let newEndpoint = String(repeating: "c", count: 64)

    static func irohRoute(endpointID: String) throws -> CmxAttachRoute {
        try CmxAttachRoute(
            id: "iroh-personal",
            kind: .iroh,
            endpoint: .peer(identity: CmxIrohPeerIdentity(endpointID: endpointID), pathHints: []),
            priority: -10_000
        )
    }

    func cleanUp() {
        Task {
            await foregroundRouter.releaseAllHeld()
            await otherRouter.releaseAllHeld()
            await newRouter.releaseAllHeld()
        }
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Serves each Mac's Iroh route, by endpoint, from its own scripted host.
private struct PerRouteTransportFactory: CmxByteTransportFactory {
    let routers: [String: LivenessHostRouter]

    func makeTransport(for route: CmxAttachRoute) throws -> any CmxByteTransport {
        guard case let .peer(identity, _) = route.endpoint, let router = routers[identity.endpointID] else {
            throw MobileShellConnectionError.connectionClosed
        }
        return LivenessTransport(router: router)
    }
}
// SUPERMUX:end mobile-startup-parallel-secondary
