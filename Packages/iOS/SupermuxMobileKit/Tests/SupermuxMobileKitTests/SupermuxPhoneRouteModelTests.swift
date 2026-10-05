import Foundation
import SupermuxMobileCore
import SupermuxMobileKit
import Testing

/// The per-Mac route the Projects list shows, and the address fetch that
/// feeds the phone's direct dials (W8). Failure modes, listed before the code:
///
/// 1. A session's route shows under no Mac: the directory's build tag and the
///    pairing's tag are spelled differently ("default" vs an untagged pairing).
/// 2. With two builds on one Mac, a route the tags cannot place is shown
///    under the wrong build instead of under neither.
/// 3. Device ids that differ only in case (UUID spellings) do not match.
/// 4. RTT jitter redraws the list on every sample.
/// 5. A move from the relay to a direct path waits for the RTT throttle.
/// 6. A Mac whose session ended keeps showing its last route.
/// 7. The Mac is asked for its addresses on every sample (RPC spam).
/// 8. A new connection to the same Mac is not asked again, so the phone
///    dials the addresses the Mac had before its network changed.
/// 9. A failed ask is retried on every sample.
/// 10. A Mac that does not serve its addresses is asked anyway.
/// 11. The answer reaches the dialer without the Mac it came from.
@MainActor
@Suite struct SupermuxPhoneRouteModelTests {
    private actor FakeRuntime: SupermuxPhoneRouteRuntime {
        var paths: [SupermuxPhoneLinkPath] = []
        private(set) var recorded: [(answer: SupermuxRouteCandidatesDTO, deviceID: String, tag: String?)] = []

        func set(_ paths: [SupermuxPhoneLinkPath]) { self.paths = paths }
        func supermuxLinkPaths() async -> [SupermuxPhoneLinkPath] { paths }
        func supermuxRecordRouteCandidates(_ answer: SupermuxRouteCandidatesDTO, macDeviceID: String, instanceTag: String?) async {
            recorded.append((answer, macDeviceID, instanceTag))
        }
        var recordedCount: Int { recorded.count }
    }

    private final class FakeCandidates: SupermuxRouteCandidatesCalling, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        let fails: Bool
        init(fails: Bool = false) { self.fails = fails }
        var calls: Int { lock.withLock { count } }
        func routeCandidates() async throws -> SupermuxRouteCandidatesDTO {
            lock.withLock { count += 1 }
            if fails { throw URLError(.timedOut) }
            return SupermuxRouteCandidatesDTO(endpointID: "abc", addresses: ["192.168.1.5:58465"])
        }
    }

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Date(timeIntervalSince1970: 1_000_000)
        var now: Date { lock.withLock { value } }
        func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
    }

    private final class Connection {}

    private static let device = "7E2D1C3B-AAAA-BBBB-CCCC-000000000001"

    private func mac(
        tag: String?,
        device: String = Self.device,
        connection: Connection,
        candidates: (any SupermuxRouteCandidatesCalling)? = nil
    ) -> SupermuxPhoneRouteMac {
        SupermuxPhoneRouteMac(
            pairingID: SupermuxMacSeam.pairingID(macDeviceID: device, instanceTag: tag),
            macDeviceID: device,
            instanceTag: tag,
            connectionID: ObjectIdentifier(connection),
            candidates: candidates)
    }

    private func path(tag: String?, device: String = Self.device, relay: Bool = false, rtt: UInt64? = 6) -> SupermuxPhoneLinkPath {
        SupermuxPhoneLinkPath(
            macDeviceID: device, instanceTag: tag, isRelay: relay,
            remoteAddress: relay ? "https://apne1.relay.cmux.dev/" : "192.168.1.5:58465", rttMs: rtt)
    }

    @Test func routeShowsUnderItsPairing() async {
        let runtime = FakeRuntime()
        let connection = Connection()
        let laptop = mac(tag: "nightly", connection: connection)
        await runtime.set([path(tag: "nightly")])
        let model = SupermuxPhoneRouteModel(runtime: runtime)
        await model.refresh(macs: [laptop])
        #expect(model.routes[laptop.pairingID]?.kind == .direct(.lan))
        #expect(model.routes[laptop.pairingID]?.rttMs == 6)
    }

    @Test func untaggedPairingTakesTheOnlyRecordOnItsDevice() async {
        let runtime = FakeRuntime()
        let connection = Connection()
        let laptop = mac(tag: nil, connection: connection)
        await runtime.set([path(tag: "default", relay: true, rtt: 241)])
        let model = SupermuxPhoneRouteModel(runtime: runtime)
        await model.refresh(macs: [laptop])
        #expect(model.routes[laptop.pairingID]?.kind == .relay(id: "apne1"))
    }

    @Test func twoBuildsOnOneMacNeverGuess() async {
        let runtime = FakeRuntime()
        let first = Connection()
        let second = Connection()
        let nightly = mac(tag: "nightly", connection: first)
        let stable = mac(tag: "stable", connection: second)
        await runtime.set([path(tag: "dev-branch")])
        let model = SupermuxPhoneRouteModel(runtime: runtime)
        await model.refresh(macs: [nightly, stable])
        #expect(model.routes.isEmpty)
    }

    @Test func deviceIDCaseDoesNotMatter() async {
        let runtime = FakeRuntime()
        let connection = Connection()
        let laptop = mac(tag: "nightly", connection: connection)
        await runtime.set([path(tag: "nightly", device: Self.device.lowercased())])
        let model = SupermuxPhoneRouteModel(runtime: runtime)
        await model.refresh(macs: [laptop])
        #expect(model.routes[laptop.pairingID] != nil)
    }

    @Test func rttJitterKeepsThePublishedRoute() async {
        let runtime = FakeRuntime()
        let clock = Clock()
        let connection = Connection()
        let laptop = mac(tag: "nightly", connection: connection)
        let model = SupermuxPhoneRouteModel(runtime: runtime, now: { clock.now })
        await runtime.set([path(tag: "nightly", rtt: 100)])
        await model.refresh(macs: [laptop])
        clock.advance(6)
        await runtime.set([path(tag: "nightly", rtt: 104)])
        await model.refresh(macs: [laptop])
        #expect(model.routes[laptop.pairingID]?.rttMs == 100)
        clock.advance(6)
        await runtime.set([path(tag: "nightly", rtt: 140)])
        await model.refresh(macs: [laptop])
        #expect(model.routes[laptop.pairingID]?.rttMs == 140)
    }

    @Test func relayToDirectIsPublishedAtOnce() async {
        let runtime = FakeRuntime()
        let clock = Clock()
        let connection = Connection()
        let laptop = mac(tag: "nightly", connection: connection)
        let model = SupermuxPhoneRouteModel(runtime: runtime, now: { clock.now })
        await runtime.set([path(tag: "nightly", relay: true, rtt: 241)])
        await model.refresh(macs: [laptop])
        clock.advance(1)
        await runtime.set([path(tag: "nightly", relay: false, rtt: 7)])
        await model.refresh(macs: [laptop])
        #expect(model.routes[laptop.pairingID]?.kind == .direct(.lan))
        #expect(model.routes[laptop.pairingID]?.rttMs == 7)
    }

    @Test func endedSessionDropsItsRoute() async {
        let runtime = FakeRuntime()
        let connection = Connection()
        let laptop = mac(tag: "nightly", connection: connection)
        let model = SupermuxPhoneRouteModel(runtime: runtime)
        await runtime.set([path(tag: "nightly")])
        await model.refresh(macs: [laptop])
        await runtime.set([])
        await model.refresh(macs: [laptop])
        #expect(model.routes.isEmpty)
    }

    @Test func addressesAreAskedForOncePerConnectionAndReachTheDialer() async throws {
        let runtime = FakeRuntime()
        let candidates = FakeCandidates()
        let connection = Connection()
        let laptop = mac(tag: "nightly", connection: connection, candidates: candidates)
        let model = SupermuxPhoneRouteModel(runtime: runtime)
        await model.refresh(macs: [laptop])
        try await TestWait().until { candidates.calls == 1 && !model.isFetchingCandidates(pairingID: laptop.pairingID) }
        await model.refresh(macs: [laptop])
        await model.refresh(macs: [laptop])
        try await Task.sleep(for: .milliseconds(50))
        #expect(candidates.calls == 1)
        let recorded = await runtime.recorded
        #expect(recorded.count == 1)
        #expect(recorded.first?.deviceID == Self.device)
        #expect(recorded.first?.tag == "nightly")
        #expect(recorded.first?.answer.addresses == ["192.168.1.5:58465"])
    }

    @Test func aNewConnectionIsAskedAgain() async throws {
        let runtime = FakeRuntime()
        let candidates = FakeCandidates()
        let first = Connection()
        let second = Connection()
        let model = SupermuxPhoneRouteModel(runtime: runtime)
        await model.refresh(macs: [mac(tag: "nightly", connection: first, candidates: candidates)])
        try await TestWait().until { candidates.calls == 1 }
        let reconnected = mac(tag: "nightly", connection: second, candidates: candidates)
        try await TestWait().until { !model.isFetchingCandidates(pairingID: reconnected.pairingID) }
        await model.refresh(macs: [reconnected])
        try await TestWait().until { candidates.calls == 2 }
    }

    @Test func aConnectedMacIsAskedAgainAfterTenMinutes() async throws {
        let runtime = FakeRuntime()
        let clock = Clock()
        let candidates = FakeCandidates()
        let connection = Connection()
        let laptop = mac(tag: "nightly", connection: connection, candidates: candidates)
        let model = SupermuxPhoneRouteModel(runtime: runtime, now: { clock.now })
        await model.refresh(macs: [laptop])
        try await TestWait().until { candidates.calls == 1 && !model.isFetchingCandidates(pairingID: laptop.pairingID) }
        clock.advance(599)
        await model.refresh(macs: [laptop])
        try await Task.sleep(for: .milliseconds(30))
        #expect(candidates.calls == 1)
        clock.advance(2)
        await model.refresh(macs: [laptop])
        try await TestWait().until { candidates.calls == 2 }
    }

    @Test func aFailedAskWaitsAMinute() async throws {
        let runtime = FakeRuntime()
        let clock = Clock()
        let candidates = FakeCandidates(fails: true)
        let connection = Connection()
        let laptop = mac(tag: "nightly", connection: connection, candidates: candidates)
        let model = SupermuxPhoneRouteModel(runtime: runtime, now: { clock.now })
        await model.refresh(macs: [laptop])
        try await TestWait().until { candidates.calls == 1 && !model.isFetchingCandidates(pairingID: laptop.pairingID) }
        clock.advance(30)
        await model.refresh(macs: [laptop])
        try await Task.sleep(for: .milliseconds(30))
        #expect(candidates.calls == 1)
        clock.advance(31)
        await model.refresh(macs: [laptop])
        try await TestWait().until { candidates.calls == 2 }
        #expect(await runtime.recordedCount == 0)
    }

    @Test func aMacThatDoesNotServeAddressesIsNotAsked() async throws {
        let runtime = FakeRuntime()
        let connection = Connection()
        let laptop = mac(tag: "nightly", connection: connection, candidates: nil)
        let model = SupermuxPhoneRouteModel(runtime: runtime)
        await model.refresh(macs: [laptop])
        try await Task.sleep(for: .milliseconds(30))
        #expect(await runtime.recordedCount == 0)
        #expect(!model.isFetchingCandidates(pairingID: laptop.pairingID))
    }
}
