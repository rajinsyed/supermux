import CMUXMobileCore
import CmuxMobileRPC
import Foundation
import Observation
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite struct MobileShellEventStreamPerformanceTests {
    @Test func eventLivenessTimestampUpdatesWithoutNotifyingObservers() async throws {
        let clock = TestClock()
        let router = LivenessHostRouter()
        let box = TransportBox()
        let store = try await makeConnectedStore(router: router, box: box, clock: clock)

        #expect(await router.waitForCount(of: "mobile.events.subscribe", atLeast: 1))
        let transport = try #require(box.get())
        let previousEventAt = store.lastTerminalEventAt
        clock.advance(by: 1)

        try await confirmation("liveness bookkeeping is not observable", expectedCount: 0) { didChange in
            withObservationTracking {
                _ = store.lastTerminalEventAt
            } onChange: {
                didChange()
            }

            await transport.deliver(try renderGridEventFrame(
                surfaceID: "live-terminal",
                seq: 102,
                text: "liveness"
            ))
            #expect(try await pollUntil {
                store.lastTerminalEventAt != previousEventAt
            }, "the internal liveness timestamp must still advance")
        }
    }

    @Test func backgroundedWatchdogDoesNotStartAProbe() async throws {
        let clock = TestClock()
        let router = LivenessHostRouter()
        let box = TransportBox()
        let store = try await makeConnectedStore(router: router, box: box, clock: clock)

        #expect(await router.waitForCount(of: "mobile.events.subscribe", atLeast: 1))
        let probeCount = await router.count(of: "mobile.events.probe")
        store.suspendForegroundRefresh()
        clock.advance(by: 10)
        store.debugRunRenderGridLivenessCheckForTesting()

        let startedProbe = await router.waitForCount(
            of: "mobile.events.probe",
            atLeast: probeCount + 1,
            timeoutNanoseconds: 100_000_000,
            recordIssueOnTimeout: false
        )
        #expect(!startedProbe, "expected background silence must not start a liveness probe")
    }

    @Test func probeCompletingAfterBackgroundDoesNotRecoverConnection() async throws {
        let clock = TestClock()
        let router = LivenessHostRouter()
        let box = TransportBox()
        let store = try await makeConnectedStore(router: router, box: box, clock: clock)
        defer {
            Task { await router.releaseAllHeld() }
        }

        #expect(await router.waitForCount(of: "mobile.events.subscribe", atLeast: 1))
        #expect(try await pollUntil { store.macConnectionStatus == .connected })
        await router.delayProbeRequest(number: 1)
        clock.advance(by: 10)
        store.debugRunRenderGridLivenessCheckForTesting()
        #expect(await router.waitForCount(of: "mobile.events.probe", atLeast: 1))

        store.markMacConnectionReconnecting()
        store.suspendForegroundRefresh()
        await router.releaseAllHeld()

        let recoveredWhileBackgrounded = try await pollUntil(attempts: 60) {
            store.macConnectionStatus == .connected
        }
        #expect(
            !recoveredWhileBackgrounded,
            "a probe that finishes after backgrounding must not publish recovery or trigger replay"
        )
    }
}
