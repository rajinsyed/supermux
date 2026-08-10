import Foundation
import SupermuxMobileCore
import SupermuxMobileKit
@testable import SupermuxMobileUI
import Testing

private actor PhonePushRegistrationRecorder: SupermuxPhonePushRegistering {
    private let firstRequestMutation: (@MainActor @Sendable () -> Void)?
    private var requests: [SupermuxPhonePushRegistrationRequest] = []
    private var queued: [SupermuxPhonePushRegistrationRequest] = []
    private var waiters: [CheckedContinuation<SupermuxPhonePushRegistrationRequest, Never>] = []

    init(firstRequestMutation: (@MainActor @Sendable () -> Void)? = nil) {
        self.firstRequestMutation = firstRequestMutation
    }

    func registerPhonePush(
        _ request: SupermuxPhonePushRegistrationRequest
    ) async throws -> SupermuxPhonePushRegistrationResponse {
        requests.append(request)
        if waiters.isEmpty {
            queued.append(request)
        } else {
            waiters.removeFirst().resume(returning: request)
        }
        if requests.count == 1, let firstRequestMutation {
            await firstRequestMutation()
        }
        return SupermuxPhonePushRegistrationResponse(registered: request.enabled)
    }

    func nextRequest() async -> SupermuxPhonePushRegistrationRequest {
        if !queued.isEmpty {
            return queued.removeFirst()
        }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func requestCount() -> Int {
        requests.count
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

        #expect(UUID(uuidString: request.deviceID) != nil)
        #expect(request.deviceToken == String(repeating: "ab", count: 32))
        #expect(request.previousDeviceToken == nil)
        #expect(request.bundleID == "com.supermux.ios")
        #expect(request.environment == .production)
        #expect(request.enabled == true)
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

        #expect(await recorder.requestCount() == 0)
    }

    @Test func tokenAndOptInChangesDuringInitialRPCDrainImmediately() async throws {
        let suiteName = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: "cmux.notifications.pushEnabled")
        let notificationCenter = NotificationCenter()
        let store = SupermuxMobilePushRegistrationStore(
            defaults: defaults,
            notificationCenter: notificationCenter,
            currentBundleID: SupermuxMobilePushRegistrationStore.bundleID
        )
        store.record(deviceToken: Data(repeating: 0xAB, count: 32))
        let recorder = PhonePushRegistrationRecorder(firstRequestMutation: {
            store.record(deviceToken: Data(repeating: 0xCD, count: 32))
            defaults.set(false, forKey: "cmux.notifications.pushEnabled")
            notificationCenter.post(name: UserDefaults.didChangeNotification, object: defaults)
        })
        let capabilities = SupermuxMobileCapabilities(
            hostCapabilities: [SupermuxMobileCapability.phonePushV1.rawValue]
        )
        let task = Task { await store.run(client: recorder, capabilities: capabilities) }

        let first = await recorder.nextRequest()
        let second = await recorder.nextRequest()
        task.cancel()

        #expect(first.enabled)
        #expect(first.deviceToken == String(repeating: "ab", count: 32))
        #expect(!second.enabled)
        #expect(second.deviceID == first.deviceID)
        #expect(second.deviceToken == String(repeating: "cd", count: 32))
        #expect(second.previousDeviceToken == String(repeating: "ab", count: 32))
    }

}
