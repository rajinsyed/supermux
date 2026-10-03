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

    /// The phone registers with EVERY connected Mac, so what each Mac was last
    /// told must be tracked per Mac: a Mac that registered the rotated token
    /// first must not erase another Mac's record of the old one, or that Mac
    /// is never told to drop it.
    @Test func eachMacTracksTheTokenItRegisteredOnItsOwn() async throws {
        let suiteName = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: "cmux.notifications.pushEnabled")
        let store = SupermuxMobilePushRegistrationStore(
            defaults: defaults,
            notificationCenter: NotificationCenter(),
            currentBundleID: SupermuxMobilePushRegistrationStore.bundleID
        )
        let capabilities = SupermuxMobileCapabilities(
            hostCapabilities: [SupermuxMobileCapability.phonePushV1.rawValue]
        )
        store.record(deviceToken: Data(repeating: 0xAB, count: 32))
        let macA = PhonePushRegistrationRecorder()
        let taskA = Task { await store.run(client: macA, capabilities: capabilities, pairingID: "mac-a") }
        _ = await macA.nextRequest()
        taskA.cancel()
        await taskA.value

        store.record(deviceToken: Data(repeating: 0xCD, count: 32))
        let macB = PhonePushRegistrationRecorder()
        let taskB = Task { await store.run(client: macB, capabilities: capabilities, pairingID: "mac-b") }
        let bookFirst = await macB.nextRequest()
        taskB.cancel()
        await taskB.value

        let macAAgain = PhonePushRegistrationRecorder()
        let taskAAgain = Task { await store.run(client: macAAgain, capabilities: capabilities, pairingID: "mac-a") }
        let studioRotation = await macAAgain.nextRequest()
        taskAAgain.cancel()

        #expect(bookFirst.previousDeviceToken == nil)
        #expect(studioRotation.deviceToken == String(repeating: "cd", count: 32))
        #expect(studioRotation.previousDeviceToken == String(repeating: "ab", count: 32))
    }

    /// An upgraded install still holds the single-Mac key from before per-Mac
    /// registration. After APNs rotates the token and every Mac has the new
    /// one, turning push off must tell each Mac ONCE: a disabled send must not
    /// re-expose that stale key as a "previous" token, or the loop re-sends
    /// back-to-back forever (each call rewriting the Mac's registry file).
    @Test func disablingPushWithAStaleSingleMacKeySendsOnce() async throws {
        let suiteName = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let rotated = String(repeating: "cd", count: 32)
        defaults.set(String(repeating: "ab", count: 32), forKey: "supermux.apns.registeredDeviceToken")
        defaults.set(rotated, forKey: "supermux.apns.registeredDeviceToken.mac-a")
        defaults.set(false, forKey: "cmux.notifications.pushEnabled")
        let notificationCenter = NotificationCenter()
        let store = SupermuxMobilePushRegistrationStore(
            defaults: defaults,
            notificationCenter: notificationCenter,
            currentBundleID: SupermuxMobilePushRegistrationStore.bundleID
        )
        store.record(deviceToken: Data(repeating: 0xCD, count: 32))
        let recorder = PhonePushRegistrationRecorder()
        let capabilities = SupermuxMobileCapabilities(
            hostCapabilities: [SupermuxMobileCapability.phonePushV1.rawValue]
        )
        let task = Task { await store.run(client: recorder, capabilities: capabilities, pairingID: "mac-a") }

        let disabled = await recorder.nextRequest()
        // The next registration must be the one THIS change causes, not a
        // repeat of the disabled send.
        store.record(deviceToken: Data(repeating: 0xEF, count: 32))
        notificationCenter.post(name: UserDefaults.didChangeNotification, object: defaults)
        let next = await recorder.nextRequest()
        task.cancel()

        #expect(!disabled.enabled)
        #expect(disabled.deviceToken == rotated)
        #expect(disabled.previousDeviceToken == nil)
        #expect(next.deviceToken == String(repeating: "ef", count: 32))
        #expect(next.previousDeviceToken == rotated)
    }
}
