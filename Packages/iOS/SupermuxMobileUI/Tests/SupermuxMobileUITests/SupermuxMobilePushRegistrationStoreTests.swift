import Foundation
import SupermuxMobileCore
import SupermuxMobileKit
@testable import SupermuxMobileUI
import Testing

private actor PhonePushRegistrationRecorder: SupermuxPhonePushRegistering {
    private var continuation: AsyncStream<SupermuxPhonePushRegistrationRequest>.Continuation?
    private let stream: AsyncStream<SupermuxPhonePushRegistrationRequest>

    init() {
        var captured: AsyncStream<SupermuxPhonePushRegistrationRequest>.Continuation?
        stream = AsyncStream { captured = $0 }
        continuation = captured
    }

    func registerPhonePush(
        _ request: SupermuxPhonePushRegistrationRequest
    ) async throws -> SupermuxPhonePushRegistrationResponse {
        continuation?.yield(request)
        return SupermuxPhonePushRegistrationResponse(registered: request.enabled)
    }

    func nextRequest() async -> SupermuxPhonePushRegistrationRequest? {
        await stream.first { _ in true }
    }
}

@Suite(.serialized) @MainActor struct SupermuxMobilePushRegistrationStoreTests {
    @Test func recordedTokenIsMirroredToACapableMac() async throws {
        let suiteName = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: "cmux.notifications.pushEnabled")
        let store = SupermuxMobilePushRegistrationStore(
            defaults: defaults,
            notificationCenter: NotificationCenter(),
            currentBundleID: SupermuxMobilePushRegistrationStore.bundleID
        )
        store.record(deviceToken: Data(repeating: 0xAB, count: 32))
        let recorder = PhonePushRegistrationRecorder()
        let capabilities = SupermuxMobileCapabilities(
            hostCapabilities: [SupermuxMobileCapability.phonePushV1.rawValue]
        )

        let task = Task { await store.run(client: recorder, capabilities: capabilities) }
        let request = await recorder.nextRequest()
        task.cancel()

        #expect(request?.deviceToken == String(repeating: "ab", count: 32))
        #expect(request?.bundleID == "com.supermux.ios")
        #expect(request?.environment == .production)
        #expect(request?.enabled == true)
    }

    @Test func unsupportedHostReturnsWithoutRegistering() async throws {
        let suiteName = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SupermuxMobilePushRegistrationStore(
            defaults: defaults,
            notificationCenter: NotificationCenter(),
            currentBundleID: SupermuxMobilePushRegistrationStore.bundleID
        )
        store.record(deviceToken: Data(repeating: 0xCD, count: 32))
        let recorder = PhonePushRegistrationRecorder()

        await store.run(
            client: recorder,
            capabilities: SupermuxMobileCapabilities(hostCapabilities: [])
        )
    }

}
