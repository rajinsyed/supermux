import CryptoKit
import Foundation
import SupermuxMobileCore
@testable import SupermuxKit
import Testing

private enum ProjectPushTestError: Error {
    case invalidResponse
}

private actor ProjectPushRecorder {
    private(set) var requests: [URLRequest] = []

    func record(_ request: URLRequest) {
        requests.append(request)
    }

    func snapshot() -> [URLRequest] {
        requests
    }
}

/// Coverage for the project identity carried in the APNs payload, and for the
/// budget rule that protects terminal output from it.
@Suite(.serialized) struct SupermuxPhonePushProjectPayloadTests {

    @Test func visiblePushCarriesProjectIdentityAndThreadID() async throws {
        let payload = try await sendPayload(
            project: SupermuxNotificationProject(
                id: "project-1",
                name: "supermux",
                colorHex: "#3b82f6",
                iconSymbol: "hammer",
                iconETag: "etag-1"
            ),
            tabName: "fix-notifications"
        )
        let cmux = try #require(payload["cmux"] as? [String: Any])
        let project = try #require(cmux["project"] as? [String: Any])
        #expect(project["id"] as? String == "project-1")
        #expect(project["name"] as? String == "supermux")
        #expect(project["colorHex"] as? String == "#3b82f6")
        #expect(project["iconSymbol"] as? String == "hammer")
        #expect(project["hasIcon"] as? Bool == true)
        #expect(cmux["tabName"] as? String == "fix-notifications")

        let aps = try #require(payload["aps"] as? [String: Any])
        // Grouping keys off the STABLE id, never the name — renaming a project
        // must not split its notification group.
        #expect(aps["thread-id"] as? String == "supermux.project.project-1")
    }

    @Test func projectWithoutAnIconOmitsTheIconFlag() async throws {
        let payload = try await sendPayload(
            project: SupermuxNotificationProject(id: "project-1", name: "supermux"),
            tabName: nil
        )
        let cmux = try #require(payload["cmux"] as? [String: Any])
        let project = try #require(cmux["project"] as? [String: Any])
        #expect(project["hasIcon"] == nil)
        #expect(project["colorHex"] == nil)
    }

    @Test func projectlessPushCarriesNoProjectKeysAtAll() async throws {
        let payload = try await sendPayload(project: nil, tabName: nil)
        let cmux = try #require(payload["cmux"] as? [String: Any])
        #expect(cmux["project"] == nil)
        #expect(cmux["tabName"] == nil)
        let aps = try #require(payload["aps"] as? [String: Any])
        #expect(aps["thread-id"] == nil)
    }

    /// Hide-content exists so a glance at the lock screen reveals nothing about
    /// what is being worked on. A project name is exactly that, so it must be
    /// suppressed along with the terminal text.
    @Test func hideContentSuppressesProjectIdentity() async throws {
        let payload = try await sendPayload(
            project: SupermuxNotificationProject(id: "project-1", name: "secret-repo"),
            tabName: "secret-branch",
            hideContent: true
        )
        let cmux = try #require(payload["cmux"] as? [String: Any])
        #expect(cmux["project"] == nil)
        #expect(cmux["tabName"] == nil)
        let aps = try #require(payload["aps"] as? [String: Any])
        #expect(aps["thread-id"] == nil)
        // Routing must still work — only the human-readable parts are hidden.
        #expect(cmux["workspaceId"] as? String == "workspace-1")
        let alert = try #require(aps["alert"] as? [String: String])
        #expect(alert["title-loc-key"] == "push.generic.title")
    }

    @Test func projectNameIsClampedBeforeItReachesThePayload() async throws {
        let payload = try await sendPayload(
            project: SupermuxNotificationProject(
                id: "project-1",
                name: String(repeating: "n", count: 500)
            ),
            tabName: String(repeating: "t", count: 500)
        )
        let cmux = try #require(payload["cmux"] as? [String: Any])
        let project = try #require(cmux["project"] as? [String: Any])
        let name = try #require(project["name"] as? String)
        let tabName = try #require(cmux["tabName"] as? String)
        #expect(name.utf8.count <= SupermuxPhonePushMessage.projectNameByteLimit)
        #expect(tabName.utf8.count <= SupermuxPhonePushMessage.tabNameByteLimit)
    }

    /// The rule sol's review corrected: project decoration is chrome, terminal
    /// output is the thing the user wants. A body that fits WITHOUT the
    /// decoration must survive intact rather than being truncated to make room
    /// for a project name.
    @Test func oversizePayloadDropsProjectDecorationBeforeTruncatingTheBody() async throws {
        // Sized so the payload fits WITHOUT decoration but not with it, which
        // is the only window where the priority question is observable.
        let body = String(repeating: "x", count: 3_800)
        let payload = try await sendPayload(
            project: SupermuxNotificationProject(id: "project-1", name: "supermux"),
            tabName: "fix-notifications",
            body: body
        )
        let cmux = try #require(payload["cmux"] as? [String: Any])
        let aps = try #require(payload["aps"] as? [String: Any])
        let alert = try #require(aps["alert"] as? [String: String])
        #expect(cmux["project"] == nil, "Project decoration should be dropped first.")
        #expect(
            alert["body"] == body,
            "The body was truncated to make room for project decoration; that priority is inverted."
        )
    }

    @Test func decoratedPayloadStaysWithinTheApnsLimit() async throws {
        let request = try await sendRequest(
            project: SupermuxNotificationProject(
                id: UUID().uuidString,
                name: String(repeating: "p", count: 64),
                colorHex: "#3b82f6",
                iconSymbol: "hammer.circle.fill",
                iconETag: "etag"
            ),
            tabName: String(repeating: "t", count: 64),
            body: String(repeating: "y", count: 8_000)
        )
        let body = try #require(request.httpBody)
        #expect(body.count <= SupermuxPhonePushService.maximumPayloadBytes)
    }

    // MARK: - Harness

    private func sendPayload(
        project: SupermuxNotificationProject?,
        tabName: String?,
        body: String = "Task finished",
        hideContent: Bool = false
    ) async throws -> [String: Any] {
        let request = try await sendRequest(
            project: project, tabName: tabName, body: body, hideContent: hideContent
        )
        let data = try #require(request.httpBody)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func sendRequest(
        project: SupermuxNotificationProject?,
        tabName: String?,
        body: String = "Task finished",
        hideContent: Bool = false
    ) async throws -> URLRequest {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeCredentials(to: directory)
        let recorder = ProjectPushRecorder()
        let service = SupermuxPhonePushService(
            baseDirectory: directory,
            now: { Date(timeIntervalSince1970: 1_800_000_000) },
            transport: { request in
                await recorder.record(request)
                guard let url = request.url,
                      let response = HTTPURLResponse(
                          url: url, statusCode: 200, httpVersion: "HTTP/2", headerFields: nil
                      ) else { throw ProjectPushTestError.invalidResponse }
                return (Data(), response)
            }
        )
        _ = try await service.register(
            deviceID: "00000000-0000-0000-0000-000000000001",
            deviceToken: String(repeating: "ab", count: 32),
            bundleID: SupermuxPhonePushService.supportedBundleID,
            environment: .production,
            enabled: true
        )
        await service.forward(SupermuxPhonePushMessage(
            kind: .notify,
            title: "Claude Code",
            subtitle: "",
            body: body,
            workspaceID: "workspace-1",
            surfaceID: "surface-1",
            macDeviceID: "mac-1",
            notificationID: "notification-1",
            badgeCount: 1,
            hideContent: hideContent,
            project: project,
            tabName: tabName
        ))
        return try #require(await recorder.snapshot().first)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("supermux-apns-project-tests-\(UUID().uuidString)", isDirectory: true)
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
