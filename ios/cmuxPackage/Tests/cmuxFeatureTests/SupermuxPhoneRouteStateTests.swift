// SUPERMUX:begin phone-route-direct-race (whole file: the phone's route state across sign-in, sign-out and backups — see SUPERMUX-TOUCHPOINTS.md)
import CmuxAuthRuntime
import CmuxMobileShellModel
import Foundation
import SupermuxMobileCore
import SupermuxMobileKit
import Testing
@testable import CmuxIrxTransport
@testable import cmuxFeature

/// Where the phone keeps its route state, and what happens to it at
/// sign-in and sign-out (review findings I5 and I10). Failure modes, listed
/// before the code:
///
/// 1. The file of each Mac's direct (LAN, Tailscale) addresses sits beside
///    the Iroh state with no backup exclusion and default permissions, so the
///    user's home network layout goes into device backups.
/// 2. Sign-out keeps the signed-out account's per-Mac route state (a skip or
///    hold-off of the direct lane) and its Macs' direct addresses.
/// 3. A cold launch never races the direct lane: dials under the warmed
///    cached identity, before sign-in finishes, find no direct lane.
/// 4. Sign-in finishing for the account the runtime warmed for shuts down
///    the direct lane a launch dial raced on, dropping its sessions; or keeps
///    it for another account.
@Suite(.timeLimit(.minutes(1)))
struct SupermuxPhoneRouteStateTests {
    private let mac = String(repeating: "b", count: 64)

    @Test("1. the address file is in its own directory, private and excluded from backups")
    func theAddressFileIsPrivateAndNotBackedUp() async throws {
        let composition = await makeComposition()
        let store = await composition.supermuxRouteCandidates
        let file = try #require(store.fileURL)
        let directory = file.deletingLastPathComponent()
        #expect(directory.standardizedFileURL != composition.configuration.stateDirectory.standardizedFileURL,
                "the address file sits beside the Iroh state")
        let values = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
        let permissions = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int
        #expect(permissions == 0o700)
    }

    @Test("2. sign-out forgets every Mac's route state and direct addresses")
    func signOutForgetsRouteState() async throws {
        let composition = await makeComposition()
        let key = SupermuxRoutePeerKey(deviceID: "mac-device", tag: "default", endpointID: mac)
        let store = await composition.supermuxRouteCandidates
        await store.recordFetched(["192.168.1.5:58465"], for: key)
        await composition.supermuxAdmissionFailed(peerHex: mac, lane: .direct)

        await composition.handleSignOut(ifCurrent: nil)

        #expect(await composition.supermuxTestDialPlan(mac).racesDirect, "the signed-out account's lane skip survived")
        #expect(await store.dialAddresses(for: key).isEmpty,
                "the signed-out account's Mac addresses survived")
    }

    @Test("3. a launch dial can race before sign-in finishes")
    func launchDialHasADirectLane() async throws {
        let composition = await makeComposition()
        await composition.supermuxTestInstallWarmedRuntime(user: "user", team: "team")
        #expect(await composition.supermuxDirectLane() != nil, "no direct lane under the warmed identity")
    }

    @Test("4. sign-in for the warmed account keeps the direct lane; another account's drops it")
    func signInKeepsTheWarmedDirectLane() async throws {
        let composition = await makeComposition()
        await composition.supermuxTestInstallWarmedRuntime(user: "user", team: "team")
        let lane = try #require(await composition.supermuxDirectLane())
        await composition.activate(scope(user: "user", team: "team", generation: 1))
        #expect(await composition.directEndpointSupervisor === lane, "sign-in shut down the launch's direct lane")

        let other = await makeComposition()
        await other.supermuxTestInstallWarmedRuntime(user: "user", team: "team")
        _ = try #require(await other.supermuxDirectLane())
        await other.activate(scope(user: "someone-else", team: "team", generation: 1))
        #expect(await other.directEndpointSupervisor == nil)
    }

    // MARK: - Helpers

    private func scope(user: String, team: String, generation: UInt64) -> AuthenticatedTeamScope {
        AuthenticatedTeamScope(
            session: AuthenticatedSessionIdentity(generation: generation, accountID: user),
            teamID: team, generation: generation)
    }

    @MainActor
    private func makeComposition() -> MobileIrxRuntimeComposition {
        MobileIrxRuntimeComposition(
            configuration: MobileIrohV2Configuration(
                baseURL: URL(string: "https://example.test")!,
                environment: "test",
                projectID: "test-project",
                appNamespace: "dev.cmux.tests",
                buildTag: "test",
                appVersion: "1.0",
                displayName: "Test",
                stateDirectory: FileManager.default.temporaryDirectory
                    .appendingPathComponent("cmux-supermux-route-tests-\(UUID().uuidString)")
            ),
            macListAuthState: MobileMacListAuthState()
        )
    }
}

private extension MobileIrxRuntimeComposition {
    /// How a dial to `mac` would run now.
    func supermuxTestDialPlan(_ mac: String) -> SupermuxPhoneRoutePolicies.DialPlan {
        supermuxRoutePolicies.dialPlan(for: mac, at: Date())
    }

    /// The runtime a launch warms from the cached state before sign-in finishes.
    func supermuxTestInstallWarmedRuntime(user: String, team: String) {
        let key = V2IdentityKey()
        let tuple = V2Identity(
            appNamespace: configuration.appNamespace, buildTag: tag, deviceID: "phone",
            environment: configuration.environment, projectID: configuration.projectID,
            teamID: team, userID: user)
        let identity = IrxIdentity(privateKeyData: key.secretKey, deviceID: "phone", appInstanceID: key.endpointID)
        let supervisor = IrxEndpointSupervisor(
            configuration: IrxEndpointConfiguration(
                identity: identity, pathMode: .automatic, initialRemoteBiStreams: 0, initialRemoteUniStreams: 0),
            journal: journal, diagnosticLog: nil)
        preparedCachedRuntime = PreparedCachedRuntime(
            identity: identity, key: key, tuple: tuple,
            stateStore: V2FileStateStore(
                rootDirectory: configuration.stateDirectory, fileManager: FileManager(), identityKey: key),
            restored: nil, supervisor: supervisor)
    }
}
// SUPERMUX:end phone-route-direct-race
