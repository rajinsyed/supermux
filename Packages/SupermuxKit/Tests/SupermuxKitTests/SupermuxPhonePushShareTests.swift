import CryptoKit
import Foundation
@testable import SupermuxKit
import Testing

/// Ways sharing direct-APNs credentials and phone registrations between the
/// user's Macs could go wrong. Written before the code.
///
/// Sender (``SupermuxPhonePushSharePlanner``):
/// 1. Sharing is off on this Mac, yet something is sent.
/// 2. Sharing is off on the peer (its status says so), yet something is sent.
/// 3. The peer already holds a DIFFERENT key and ours is sent anyway (it would overwrite).
/// 4. The peer already holds the SAME key and it is re-sent (pointless secret traffic).
/// 5. The peer lacks a key while this Mac has one, and the key is not sent.
/// 6. This Mac has neither a key nor registrations, yet a request is made.
/// 7. The peer serves another bundle topic, yet credentials are sent to it.
/// 8. The wire params carry a private key although the plan did not choose to send one.
///
/// Receiver (``SupermuxPhonePushShareMerger``):
/// 9. No key here, and the incoming key is not installed.
/// 10. An identical key here is rewritten instead of reported unchanged.
/// 11. A different key here (other key id, or same id with other bytes) is overwritten.
/// 12. A malformed incoming key (bad identifiers, PEM that is not a P-256 key) is accepted.
/// 13. Registrations: an unknown device is not added; a device already registered here loses
///     its own (possibly newer) token; a known token is duplicated; invalid entries (wrong
///     bundle, bad token, bad device id) are kept; the list grows without bound.
/// 13b. A phone rotated its token: a relayed registration that is NEWER than this Mac's entry
///     for the same phone is ignored (this Mac keeps pushing to a dead token), or an OLDER
///     relayed one replaces this Mac's newer entry. Direct registrations are not timestamped.
///
/// Service files (``SupermuxPhonePushService`` share extension):
/// 14. An installed key or config is readable by others (not 0600), or its directory is not 0700.
/// 15. A conflicting share changes the existing key or config bytes.
/// 16. `status()` leaks the private key, or misreports what is installed.
/// 17. A visible push omits `cmux.macInstanceTag`, so the phone cannot route the tap.
@Suite(.serialized) struct SupermuxPhonePushShareTests {
    // MARK: - Fixtures

    private static let bundleID = SupermuxPhonePushService.supportedBundleID

    private func makeCredentials(keyID: String = "ABC123DEFG") -> SupermuxPhonePushCredentials {
        SupermuxPhonePushCredentials(
            configuration: SupermuxPhonePushConfiguration(teamID: "NRGUG8GVV4", keyID: keyID),
            privateKeyPEM: P256.Signing.PrivateKey().pemRepresentation
        )
    }

    private func registration(
        device: String? = nil,
        token: String,
        bundle: String = SupermuxPhonePushService.supportedBundleID
    ) -> SupermuxPhonePushRegistration {
        SupermuxPhonePushRegistration(
            deviceID: device,
            deviceToken: token,
            bundleID: bundle,
            environment: .production
        )
    }

    private func token(_ byte: String) -> String {
        String(repeating: byte, count: 32)
    }

    private func peerStatus(
        credentials: SupermuxPhonePushCredentials? = nil,
        registrationCount: Int = 0,
        shareEnabled: Bool = true,
        bundleID: String = SupermuxPhonePushService.supportedBundleID
    ) -> SupermuxPhonePushStatus {
        SupermuxPhonePushStatus(
            hasCredentials: credentials != nil,
            teamID: credentials?.configuration.teamID,
            keyID: credentials?.configuration.keyID,
            keyFingerprint: credentials?.fingerprint,
            bundleID: bundleID,
            registrationCount: registrationCount,
            shareEnabled: shareEnabled
        )
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("supermux-apns-share-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
        return url
    }

    private func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    // MARK: - Sender

    @Test func sharingOffHereSendsNothing() {
        let plan = SupermuxPhonePushSharePlanner.plan(
            local: makeCredentials(),
            localRegistrations: [registration(token: token("ab"))],
            peer: peerStatus(),
            shareEnabled: false
        )
        #expect(plan == nil)
    }

    @Test func sharingOffOnThePeerSendsNothing() {
        let plan = SupermuxPhonePushSharePlanner.plan(
            local: makeCredentials(),
            localRegistrations: [registration(token: token("ab"))],
            peer: peerStatus(shareEnabled: false),
            shareEnabled: true
        )
        #expect(plan == nil)
    }

    @Test func aPeerWithADifferentKeyNeverReceivesOurs() throws {
        let plan = try #require(SupermuxPhonePushSharePlanner.plan(
            local: makeCredentials(keyID: "ABC123DEFG"),
            localRegistrations: [registration(token: token("ab"))],
            peer: peerStatus(credentials: makeCredentials(keyID: "ZZZ999YYYY")),
            shareEnabled: true
        ))
        #expect(plan.credentials == nil)
        #expect(plan.registrations.count == 1)
        #expect(plan.wireParams["p8"] == nil)
        #expect(plan.wireParams["config"] == nil)
    }

    @Test func aPeerWithTheSameKeyIsNotSentItAgain() {
        let local = makeCredentials()
        let plan = SupermuxPhonePushSharePlanner.plan(
            local: local,
            localRegistrations: [],
            peer: peerStatus(credentials: local),
            shareEnabled: true
        )
        #expect(plan == nil)
    }

    @Test func aPeerWithoutAKeyReceivesOursWithItsConfig() throws {
        let local = makeCredentials()
        let plan = try #require(SupermuxPhonePushSharePlanner.plan(
            local: local,
            localRegistrations: [],
            peer: peerStatus(),
            shareEnabled: true
        ))
        #expect(plan.credentials == local)
        let config = try #require(plan.wireParams["config"] as? [String: String])
        #expect(config["team_id"] == "NRGUG8GVV4")
        #expect(config["key_id"] == "ABC123DEFG")
        #expect(plan.wireParams["p8"] as? String == local.privateKeyPEM)
    }

    @Test func nothingToShareMakesNoRequest() {
        let plan = SupermuxPhonePushSharePlanner.plan(
            local: nil,
            localRegistrations: [],
            peer: peerStatus(),
            shareEnabled: true
        )
        #expect(plan == nil)
    }

    @Test func aPeerOnAnotherBundleTopicReceivesNothing() {
        let plan = SupermuxPhonePushSharePlanner.plan(
            local: makeCredentials(),
            localRegistrations: [registration(token: token("ab"))],
            peer: peerStatus(bundleID: "com.example.other"),
            shareEnabled: true
        )
        #expect(plan == nil)
    }

    @Test func registrationsAloneTravelWithoutAKey() throws {
        let plan = try #require(SupermuxPhonePushSharePlanner.plan(
            local: nil,
            localRegistrations: [registration(device: "00000000-0000-0000-0000-000000000001", token: token("ab"))],
            peer: peerStatus(),
            shareEnabled: true
        ))
        #expect(plan.credentials == nil)
        #expect(plan.wireParams["p8"] == nil)
        let wire = try #require(plan.wireParams["registrations"] as? [[String: Any]])
        #expect(wire.count == 1)
        #expect(wire.first?["device_token"] as? String == token("ab"))
        #expect(wire.first?["bundle_id"] as? String == Self.bundleID)
        #expect(wire.first?["environment"] as? String == "production")
    }

    // MARK: - Receiver

    @Test func noKeyHereInstallsTheIncomingKey() {
        let incoming = makeCredentials()
        #expect(SupermuxPhonePushShareMerger.credentialOutcome(existing: nil, incoming: incoming) == .install)
    }

    @Test func anIdenticalKeyIsUnchanged() {
        let existing = makeCredentials()
        #expect(SupermuxPhonePushShareMerger.credentialOutcome(existing: existing, incoming: existing) == .unchanged)
    }

    @Test func aDifferentKeyIsAConflictNeverAnOverwrite() {
        let existing = makeCredentials(keyID: "ABC123DEFG")
        #expect(SupermuxPhonePushShareMerger.credentialOutcome(
            existing: existing,
            incoming: makeCredentials(keyID: "ZZZ999YYYY")
        ) == .conflict)
        // Same key id, different key bytes: still a conflict.
        #expect(SupermuxPhonePushShareMerger.credentialOutcome(
            existing: existing,
            incoming: makeCredentials(keyID: "ABC123DEFG")
        ) == .conflict)
    }

    @Test func malformedIncomingKeysAreRejected() {
        let badIdentifiers = SupermuxPhonePushCredentials(
            configuration: SupermuxPhonePushConfiguration(teamID: "x", keyID: "not valid!"),
            privateKeyPEM: P256.Signing.PrivateKey().pemRepresentation
        )
        #expect(SupermuxPhonePushShareMerger.credentialOutcome(existing: nil, incoming: badIdentifiers) == .invalid)
        let notAKey = SupermuxPhonePushCredentials(
            configuration: SupermuxPhonePushConfiguration(teamID: "NRGUG8GVV4", keyID: "ABC123DEFG"),
            privateKeyPEM: "-----BEGIN PRIVATE KEY-----\nbm90IGEga2V5\n-----END PRIVATE KEY-----"
        )
        #expect(SupermuxPhonePushShareMerger.credentialOutcome(existing: nil, incoming: notAKey) == .invalid)
    }

    @Test func registrationsMergeWithoutLosingLocalTruth() {
        let device = "00000000-0000-0000-0000-00000000000a"
        let existing = [registration(device: device, token: token("aa"))]
        let incoming = [
            // Same device, other token: this Mac's own (direct) registration wins.
            registration(device: device, token: token("bb")),
            // Unknown device: added.
            registration(device: "00000000-0000-0000-0000-00000000000b", token: token("cc")),
            // Already-known token without a device id: not duplicated.
            registration(token: token("aa")),
            // Invalid entries: dropped.
            registration(token: token("dd"), bundle: "com.example.other"),
            registration(token: "zz"),
            registration(device: "not-a-uuid", token: token("ee")),
        ]
        let result = SupermuxPhonePushShareMerger.mergeRegistrations(existing: existing, incoming: incoming)
        #expect(result.added == 1)
        #expect(result.merged.map(\.deviceToken) == [token("aa"), token("cc")])
    }

    @Test func aNewerRelayedTokenReplacesAnOlderOneForTheSamePhone() {
        let device = "00000000-0000-0000-0000-00000000000a"
        var existing = registration(device: device, token: token("aa"))
        existing.registeredAt = 1_000
        var newer = registration(device: device, token: token("bb"))
        newer.registeredAt = 2_000
        var older = registration(device: device, token: token("cc"))
        older.registeredAt = 500

        let replaced = SupermuxPhonePushShareMerger.mergeRegistrations(existing: [existing], incoming: [newer])
        #expect(replaced.merged.map(\.deviceToken) == [token("bb")])
        #expect(replaced.added == 1)

        let kept = SupermuxPhonePushShareMerger.mergeRegistrations(existing: [existing], incoming: [older])
        #expect(kept.merged.map(\.deviceToken) == [token("aa")])
        #expect(kept.added == 0)
    }

    @Test func directRegistrationsAreTimestamped() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = SupermuxPhonePushService(
            baseDirectory: directory,
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
        _ = try await service.register(
            deviceID: "00000000-0000-0000-0000-000000000001",
            deviceToken: token("ab"),
            bundleID: Self.bundleID,
            environment: .production,
            enabled: true
        )
        let stored = await service.shareSnapshot().registrations
        #expect(stored.first?.registeredAt == 1_800_000_000)
    }

    @Test func mergedRegistrationsAreCapped() {
        let incoming = (0 ..< 40).map { index in
            registration(token: String(format: "%064x", index + 1))
        }
        let result = SupermuxPhonePushShareMerger.mergeRegistrations(existing: [], incoming: incoming)
        #expect(result.merged.count == SupermuxPhonePushShareMerger.registrationLimit)
        #expect(result.added == SupermuxPhonePushShareMerger.registrationLimit)
    }

    // MARK: - Service files

    @Test func installingWritesPrivateFilesInAPrivateDirectory() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = SupermuxPhonePushService(baseDirectory: directory)
        let credentials = makeCredentials()

        let result = try await service.acceptShare(SupermuxPhonePushShareRequest(
            credentials: credentials,
            registrations: [registration(token: token("ab"))]
        ))

        #expect(result.credentials == .install)
        #expect(result.registrationsAdded == 1)
        #expect(try permissions(directory) == 0o700)
        let key = directory.appendingPathComponent(SupermuxPhonePushService.privateKeyFileName)
        let config = directory.appendingPathComponent(SupermuxPhonePushService.configurationFileName)
        let devices = directory.appendingPathComponent(SupermuxPhonePushService.registrationsFileName)
        #expect(try permissions(key) == 0o600)
        #expect(try permissions(config) == 0o600)
        #expect(try permissions(devices) == 0o600)
        #expect(await service.isConfigured())
        let snapshot = await service.shareSnapshot()
        #expect(snapshot.credentials == credentials)
        #expect(snapshot.registrations.count == 1)
    }

    @Test func aConflictingShareLeavesExistingFilesUntouched() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = SupermuxPhonePushService(baseDirectory: directory)
        _ = try await service.acceptShare(SupermuxPhonePushShareRequest(credentials: makeCredentials(keyID: "ABC123DEFG")))
        let key = directory.appendingPathComponent(SupermuxPhonePushService.privateKeyFileName)
        let config = directory.appendingPathComponent(SupermuxPhonePushService.configurationFileName)
        let keyBefore = try Data(contentsOf: key)
        let configBefore = try Data(contentsOf: config)

        let result = try await service.acceptShare(SupermuxPhonePushShareRequest(
            credentials: makeCredentials(keyID: "ZZZ999YYYY")
        ))

        #expect(result.credentials == .conflict)
        #expect(try Data(contentsOf: key) == keyBefore)
        #expect(try Data(contentsOf: config) == configBefore)
    }

    @Test func statusNeverCarriesTheKey() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = SupermuxPhonePushService(baseDirectory: directory)
        let empty = await service.status(shareEnabled: true)
        #expect(!empty.hasCredentials)
        #expect(empty.keyID == nil)
        #expect(empty.registrationCount == 0)
        #expect(empty.bundleID == Self.bundleID)

        let credentials = makeCredentials()
        _ = try await service.acceptShare(SupermuxPhonePushShareRequest(
            credentials: credentials,
            registrations: [registration(token: token("ab")), registration(token: token("cd"))]
        ))
        let status = await service.status(shareEnabled: false)
        #expect(status.hasCredentials)
        #expect(status.teamID == "NRGUG8GVV4")
        #expect(status.keyID == "ABC123DEFG")
        #expect(status.keyFingerprint == credentials.fingerprint)
        #expect(status.registrationCount == 2)
        #expect(!status.shareEnabled)

        let encoded = try JSONEncoder().encode(status)
        let text = String(decoding: encoded, as: UTF8.self)
        #expect(!text.contains("PRIVATE KEY"))
        #expect(text.contains("\"has_credentials\""))
        #expect(text.contains("\"registration_count\""))
        #expect(!String(describing: credentials).contains("PRIVATE KEY"))
    }

    @Test func shareRequestsRoundTripThroughTheWire() throws {
        let credentials = makeCredentials()
        let plan = try #require(SupermuxPhonePushSharePlanner.plan(
            local: credentials,
            localRegistrations: [registration(device: "00000000-0000-0000-0000-000000000001", token: token("ab"))],
            peer: peerStatus(),
            shareEnabled: true
        ))
        let request = try SupermuxPhonePushShareRequest(wireParams: plan.wireParams)
        #expect(request.credentials == credentials)
        #expect(request.registrations == plan.registrations)
    }

    // MARK: - Payload

    @Test func visiblePushesCarryTheMacInstanceTag() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bodies = PayloadRecorder()
        let service = SupermuxPhonePushService(
            baseDirectory: directory,
            transport: { request in
                await bodies.record(request.httpBody ?? Data())
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/2", headerFields: nil)!
                return (Data(), response)
            }
        )
        _ = try await service.acceptShare(SupermuxPhonePushShareRequest(
            credentials: makeCredentials(),
            registrations: [registration(token: token("ab"))]
        ))

        await service.forward(SupermuxPhonePushMessage(
            kind: .notify, title: "t", workspaceID: "w", macDeviceID: "mac-1",
            macInstanceTag: "default", notificationID: "n-1", badgeCount: 1
        ))
        await service.forward(SupermuxPhonePushMessage(
            kind: .notify, title: "t", workspaceID: "w", macDeviceID: "mac-1",
            notificationID: "n-2", badgeCount: 1
        ))

        let recorded = await bodies.snapshot()
        #expect(recorded.count == 2)
        let tagged = try #require(recorded.first.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect((tagged["cmux"] as? [String: Any])?["macInstanceTag"] as? String == "default")
        let untagged = try #require(recorded.last.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect((untagged["cmux"] as? [String: Any])?["macInstanceTag"] == nil)
    }
}

private actor PayloadRecorder {
    private var bodies: [Data] = []

    func record(_ body: Data) {
        bodies.append(body)
    }

    func snapshot() -> [Data] {
        bodies
    }
}
