// SUPERMUX:begin v2-directory-refresh-floor (the directory refresh does not loop near the ticket's renewal — see SUPERMUX-TOUCHPOINTS.md)
import Foundation
import Testing
@testable import CmuxIrxTransport

/// The control plane's directory refresh must not loop.
///
/// Field evidence (2026-10-05 04:55:30Z, the always-awake M4): the directory's
/// permissions ended 300 s out while the ticket had 29 s left before its own
/// renewal. Maintenance refreshes the directory 300 s before its permissions
/// end, the server cannot extend them past the ticket, so every refresh came
/// back with the same expiry and was due again at once: 485
/// `directory.request.v1` in 31 s (`sleep_s 0`), each re-running endpoint
/// readiness and the relay-hint publish on the main actor, until the ticket
/// renewed.
///
/// Ways it could go wrong, one test each:
/// 1. A directory whose permissions end inside the 300 s margin is refreshed
///    again at once after every refresh (the loop).
/// 2. The spacing outlives a ticket renewal, so the refresh that can finally
///    extend the permissions waits out the spacing.
@Suite(.timeLimit(.minutes(1))) struct SupermuxV2DirectoryRefreshFloorTests {
    private let now = 1_789_000_000

    private func service(backend: V2TestBackend, journal: IrxJournal) throws -> V2ControlService {
        let fixedNow = now
        let device = V2DeviceDescriptor(
            endpointID: String(repeating: "a", count: 64),
            identity: V2Identity(appNamespace: "com.cmux.test", buildTag: "test", deviceID: "device", environment: "test", projectID: "project", teamID: "team", userID: "user"),
            identityGeneration: 0,
            metadata: V2DeviceMetadata(appVersion: "2.0", capabilities: ["terminal"], displayName: "Test Mac", pairingEnabled: true, platform: .mac, relayURLs: ["https://relay.example.com/"])
        )
        return V2ControlService(
            configuration: try V2ControlConfiguration(baseURL: URL(string: "https://control.example.com")!, device: device),
            dependencies: V2ControlDependencies(
                connect: { try await backend.connect($0) },
                http: { try await backend.http($0) },
                stackAccessToken: { _ in "existing-stack-session" },
                sign: { _ in Data(repeating: 1, count: 64) },
                now: { Date(timeIntervalSince1970: Double(fixedNow)) },
                // The clock never moves: a zero wait returns at once, any real wait parks.
                sleep: { seconds in
                    if seconds > 0 { try await Task.sleep(for: .seconds(3_600)) }
                    await Task.yield()
                },
                jitter: { 0.5 },
                journal: journal),
            store: V2TestStateStore()
        )
    }

    private func ready(_ service: V2ControlService) async throws {
        for await snapshot in await service.events() {
            if snapshot.status == .ready { return }
            if snapshot.status == .stopped, let failure = snapshot.failure { throw failure }
        }
        throw V2ControlFailure.stopped
    }

    private func directoryRequests(_ backend: V2TestBackend) async -> Int {
        await backend.currentSocket().sentSchemas.filter { $0 == "directory.request.v1" }.count
    }

    @Test("1. permissions ending inside the refresh margin do not refresh the directory in a loop")
    func expiringPermissionsDoNotLoop() async throws {
        let backend = V2TestBackend(now: now)
        await backend.supermuxSetDirectoryPermissionTTL(200)
        let journal = IrxJournal(subsystem: "com.cmux.test", category: "v2-directory-floor-loop")
        let service = try service(backend: backend, journal: journal)
        await service.start()
        try await ready(service)
        try await Task.sleep(for: .milliseconds(500))
        let requests = await directoryRequests(backend)
        let plans = journal.tail(IrxJournal.ringCapacity).filter { $0.event == "maintenance-planned" }
        await service.stop()
        #expect(requests <= 3, "\(requests) directory refreshes in 0.5 s with the clock stopped")
        #expect(plans.last?.attributes["sleep_s"] != "0", "maintenance still plans a zero wait: \(plans.last?.attributes ?? [:])")
    }

    @Test("2. a ticket renewal lets the next directory refresh go at once; otherwise refreshes are spaced")
    func ticketRenewalLiftsTheSpacing() {
        let spacing = V2ControlService.supermuxDirectoryRefreshSpacing
        #expect(spacing >= 15 && spacing <= 60, "short enough to follow a renewal, long enough to stop a loop")
        let t: TimeInterval = 1_000
        #expect(V2ControlService.supermuxDirectoryFloor(0, refreshedDirectory: true, triedTicket: false, now: t) == t + spacing)
        #expect(V2ControlService.supermuxDirectoryFloor(t + spacing, refreshedDirectory: false, triedTicket: false, now: t + 5) == t + spacing,
                "a pass that refreshed nothing keeps the floor")
        #expect(V2ControlService.supermuxDirectoryFloor(t + spacing, refreshedDirectory: false, triedTicket: true, now: t + 5) == 0,
                "the refresh that can extend the permissions follows the ticket at once")
        #expect(V2ControlService.supermuxDirectoryFloor(0, refreshedDirectory: true, triedTicket: true, now: t) == 0,
                "a directory refreshed beside the ticket may have raced it: one more goes at once")
    }
}
// SUPERMUX:end v2-directory-refresh-floor
