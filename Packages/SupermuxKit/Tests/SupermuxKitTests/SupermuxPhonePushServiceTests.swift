import CryptoKit
import Foundation
@testable import SupermuxKit
import Testing

private enum PhonePushTestError: Error {
    case invalidResponse
}

private actor APNsRequestRecorder {
    private(set) var requests: [URLRequest] = []

    func record(_ request: URLRequest) {
        requests.append(request)
    }

    func snapshot() -> [URLRequest] {
        requests
    }
}

@Suite(.serialized) struct SupermuxPhonePushServiceTests {
    @Test func visibleNotificationUsesSandboxTopicAndCmuxDeepLinkPayload() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeCredentials(to: directory)
        let recorder = APNsRequestRecorder()
        let service = SupermuxPhonePushService(
            baseDirectory: directory,
            now: { Date(timeIntervalSince1970: 1_800_000_000) },
            transport: { request in
                await recorder.record(request)
                guard let url = request.url,
                      let response = HTTPURLResponse(
                          url: url,
                          statusCode: 200,
                          httpVersion: "HTTP/2",
                          headerFields: nil
                      ) else { throw PhonePushTestError.invalidResponse }
                return (Data(), response)
            }
        )
        let token = String(repeating: "ab", count: 32)
        _ = try await service.register(
            deviceID: "00000000-0000-0000-0000-000000000001",
            deviceToken: token,
            bundleID: SupermuxPhonePushService.supportedBundleID,
            environment: .sandbox,
            enabled: true
        )

        await service.forward(SupermuxPhonePushMessage(
            kind: .notify,
            title: "Claude Code",
            subtitle: "Completed",
            body: "Task finished",
            acceptsTextReply: true,
            workspaceID: "workspace-1",
            surfaceID: "surface-1",
            macDeviceID: "mac-1",
            notificationID: "notification-1",
            badgeCount: 3
        ))

        let request = try #require(await recorder.snapshot().first)
        #expect(request.url?.host == "api.sandbox.push.apple.com")
        #expect(request.url?.path == "/3/device/\(token)")
        #expect(request.value(forHTTPHeaderField: "apns-topic") == "com.supermux.ios")
        #expect(request.value(forHTTPHeaderField: "apns-push-type") == "alert")
        #expect(request.value(forHTTPHeaderField: "apns-priority") == "10")
        #expect(request.value(forHTTPHeaderField: "apns-collapse-id") == "notification-1")
        let authorization = try #require(request.value(forHTTPHeaderField: "authorization"))
        #expect(authorization.hasPrefix("bearer "))
        #expect(authorization.dropFirst("bearer ".count).split(separator: ".").count == 3)

        let body = try #require(request.httpBody)
        let object = try JSONSerialization.jsonObject(with: body)
        let payload = try #require(object as? [String: Any])
        let aps = try #require(payload["aps"] as? [String: Any])
        let alert = try #require(aps["alert"] as? [String: String])
        let cmux = try #require(payload["cmux"] as? [String: Any])
        #expect(alert["title"] == "Claude Code")
        #expect(alert["subtitle"] == "Completed")
        #expect(alert["body"] == "Task finished")
        #expect(aps["category"] as? String == "cmux.terminal.reply")
        #expect(aps["badge"] as? Int == 3)
        // Agent-completion pushes matter precisely when the user is away from
        // the Mac, so they must break through Focus and Scheduled Summary.
        #expect(aps["interruption-level"] as? String == "time-sensitive")
        #expect(cmux["workspaceId"] as? String == "workspace-1")
        #expect(cmux["surfaceId"] as? String == "surface-1")
        #expect(cmux["macDeviceId"] as? String == "mac-1")
        #expect(cmux["notificationId"] as? String == "notification-1")
    }

    @Test func providerRejectsAnyBundleOutsideTheFixedSupermuxTopic() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = SupermuxPhonePushService(
            baseDirectory: directory,
            transport: { request in
                guard let url = request.url,
                      let response = HTTPURLResponse(
                          url: url,
                          statusCode: 200,
                          httpVersion: nil,
                          headerFields: nil
                      ) else { throw PhonePushTestError.invalidResponse }
                return (Data(), response)
            }
        )

        await #expect(throws: SupermuxPhonePushService.RegistrationError.invalidRegistration) {
            _ = try await service.register(
                deviceID: "00000000-0000-0000-0000-000000000001",
                deviceToken: String(repeating: "cd", count: 32),
                bundleID: "com.ryne.ryne",
                environment: .sandbox,
                enabled: true
            )
        }
    }

    @Test func permanentlyInvalidDeviceTokenIsPrunedAfterOneAttempt() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeCredentials(to: directory)
        let recorder = APNsRequestRecorder()
        let service = SupermuxPhonePushService(
            baseDirectory: directory,
            transport: { request in
                await recorder.record(request)
                guard let url = request.url,
                      let response = HTTPURLResponse(
                          url: url,
                          statusCode: 410,
                          httpVersion: "HTTP/2",
                          headerFields: nil
                      ) else { throw PhonePushTestError.invalidResponse }
                return (Data(#"{"reason":"Unregistered"}"#.utf8), response)
            }
        )
        _ = try await service.register(
            deviceID: "00000000-0000-0000-0000-000000000001",
            deviceToken: String(repeating: "ef", count: 32),
            bundleID: SupermuxPhonePushService.supportedBundleID,
            environment: .sandbox,
            enabled: true
        )
        let message = SupermuxPhonePushMessage(kind: .dismiss, dismissedIDs: ["id"], badgeCount: 0)

        await service.forward(message)
        await service.forward(message)

        #expect(await recorder.snapshot().count == 1)
    }

    @Test func tokenRotationReplacesALegacyRegistrationForTheSameDevice() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeCredentials(to: directory)
        let recorder = APNsRequestRecorder()
        let service = SupermuxPhonePushService(
            baseDirectory: directory,
            transport: { request in
                await recorder.record(request)
                guard let url = request.url,
                      let response = HTTPURLResponse(
                          url: url,
                          statusCode: 200,
                          httpVersion: "HTTP/2",
                          headerFields: nil
                      ) else { throw PhonePushTestError.invalidResponse }
                return (Data(), response)
            }
        )
        let deviceID = "00000000-0000-0000-0000-000000000002"
        let oldToken = String(repeating: "ab", count: 32)
        let newToken = String(repeating: "cd", count: 32)
        _ = try await service.register(
            deviceToken: oldToken,
            bundleID: SupermuxPhonePushService.supportedBundleID,
            environment: .production,
            enabled: true
        )
        _ = try await service.register(
            deviceID: deviceID,
            deviceToken: newToken,
            previousDeviceToken: oldToken,
            bundleID: SupermuxPhonePushService.supportedBundleID,
            environment: .production,
            enabled: true
        )

        await service.forward(SupermuxPhonePushMessage(kind: .dismiss, badgeCount: 0))

        let requests = await recorder.snapshot()
        #expect(requests.count == 1)
        #expect(requests.first?.url?.path == "/3/device/\(newToken)")
    }

    @Test func oversizedVisibleContentIsTruncatedBelowTheAPNsLimit() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeCredentials(to: directory)
        let recorder = APNsRequestRecorder()
        let service = SupermuxPhonePushService(
            baseDirectory: directory,
            transport: { request in
                await recorder.record(request)
                guard let url = request.url,
                      let response = HTTPURLResponse(
                          url: url,
                          statusCode: 200,
                          httpVersion: "HTTP/2",
                          headerFields: nil
                      ) else { throw PhonePushTestError.invalidResponse }
                return (Data(), response)
            }
        )
        _ = try await service.register(
            deviceID: "00000000-0000-0000-0000-000000000003",
            deviceToken: String(repeating: "ef", count: 32),
            bundleID: SupermuxPhonePushService.supportedBundleID,
            environment: .production,
            enabled: true
        )
        let originalBody = String(repeating: "terminal output ", count: 1_000)

        await service.forward(SupermuxPhonePushMessage(
            kind: .notify,
            title: "Agent finished",
            body: originalBody,
            badgeCount: 1
        ))

        let request = try #require(await recorder.snapshot().first)
        let data = try #require(request.httpBody)
        #expect(data.count <= SupermuxPhonePushService.maximumPayloadBytes)
        let payload = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let aps = try #require(payload["aps"] as? [String: Any])
        let alert = try #require(aps["alert"] as? [String: String])
        let deliveredBody = try #require(alert["body"])
        #expect(deliveredBody.count < originalBody.count)
    }

    @Test func largeDismissBatchesAreChunkedWithoutDroppingIdentifiers() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeCredentials(to: directory)
        let recorder = APNsRequestRecorder()
        let service = SupermuxPhonePushService(
            baseDirectory: directory,
            transport: { request in
                await recorder.record(request)
                guard let url = request.url,
                      let response = HTTPURLResponse(
                          url: url,
                          statusCode: 200,
                          httpVersion: "HTTP/2",
                          headerFields: nil
                      ) else { throw PhonePushTestError.invalidResponse }
                return (Data(), response)
            }
        )
        _ = try await service.register(
            deviceID: "00000000-0000-0000-0000-000000000004",
            deviceToken: String(repeating: "12", count: 32),
            bundleID: SupermuxPhonePushService.supportedBundleID,
            environment: .production,
            enabled: true
        )
        let dismissedIDs = (0 ..< 300).map { "notification-\($0)-\(String(repeating: "x", count: 48))" }

        await service.forward(SupermuxPhonePushMessage(
            kind: .dismiss,
            dismissedIDs: dismissedIDs,
            badgeCount: 2
        ))

        let requests = await recorder.snapshot()
        #expect(requests.count > 1)
        var deliveredIDs: [String] = []
        for request in requests {
            let data = try #require(request.httpBody)
            #expect(data.count <= SupermuxPhonePushService.maximumPayloadBytes)
            let payload = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            let cmux = try #require(payload["cmux"] as? [String: Any])
            deliveredIDs.append(contentsOf: try #require(cmux["dismissedIds"] as? [String]))
        }
        #expect(deliveredIDs == dismissedIDs)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("supermux-apns-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeCredentials(to directory: URL) throws {
        let configuration = Data(#"{"team_id":"NRGUG8GVV4","key_id":"ABC123DEFG"}"#.utf8)
        try configuration.write(
            to: directory.appendingPathComponent(SupermuxPhonePushService.configurationFileName)
        )
        let privateKey = P256.Signing.PrivateKey()
        try Data(privateKey.pemRepresentation.utf8).write(
            to: directory.appendingPathComponent(SupermuxPhonePushService.privateKeyFileName)
        )
    }
}
