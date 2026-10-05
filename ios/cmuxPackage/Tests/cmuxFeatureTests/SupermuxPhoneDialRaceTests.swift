// SUPERMUX:begin phone-route-direct-race (whole file: the phone's dial race prefers direct like the Mac's — see SUPERMUX-TOUCHPOINTS.md)
import CmuxIrxTransport
import Foundation
import SupermuxMobileKit
import Testing
@testable import cmuxFeature

/// The phone's dial race (`MobileIrxRuntimeComposition.supermuxRace`), at
/// the timing the phone dials with: the direct lane starts at once, the
/// automatic (relay) dial 250 ms later, and direct may take 1.5 s.
///
/// The user's rule: "always use direct (LAN or Tailscale) whenever possible;
/// the relay at ~250 ms is awful". Ways the phone's race could break it:
///
/// 1. The relay is ready first and wins although direct answers within its
///    deadline. Over Tailscale from cellular the direct handshake takes
///    longer than the relay's 250 ms head start plus its setup, so the phone
///    lands on the relay and stays there until the 10 s prober moves it.
/// 2. Direct never answers (a stale LAN address) and the dial waits past the
///    1.5 s deadline, until iroh's own connect timeout.
/// 3. Direct never answers and a relay that was ready first is not held for
///    direct (the Mac's rule: direct gets its full deadline).
/// 4. The relay connection that lost is left open, so the Mac holds a stray
///    connection, or both reach admission.
/// 5. Direct works at once and the relay is dialed anyway.
/// 6. Direct fails fast (no route) and the relay still waits for the head
///    start or the deadline.
/// 7. A leg comes back under the wrong lane, so a relayed session is
///    treated as a direct-lane one (no NAT traversal, silence fallback).
/// 8. An automatic dial with no usable relay credential (expired after
///    30 min idle, none during an internet outage) refreshes it before the
///    race (second review #6): every such dial's lane waits an HTTPS round
///    trip, and with the LAN up and the internet down the refresh's failure
///    ends the dial before the lane is tried.
/// 9. The relay leg refreshes a credential that is still usable, or dials
///    with the expired one instead of the fresh one.
@Suite(.timeLimit(.minutes(1)))
struct SupermuxPhoneDialRaceTests {
    private struct DialFailed: Error, Equatable {}

    /// Records which legs started and which values were closed.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var started: [String] = []
        private var closed: [String] = []
        var startedLegs: [String] { lock.withLock { started } }
        var discarded: [String] { lock.withLock { closed } }
        func start(_ leg: String) { lock.withLock { started.append(leg) } }
        func discard(_ value: String) { lock.withLock { closed.append(value) } }
    }

    private static func race(
        direct: @escaping @Sendable () async throws -> String,
        automatic: @escaping @Sendable () async throws -> String,
        recorder: Recorder
    ) async throws -> (value: String, lane: SupermuxDialLane, journalFields: [String: String]) {
        try await MobileIrxRuntimeComposition.supermuxRace(
            direct: { recorder.start("direct"); return try await direct() },
            automatic: { recorder.start("relay"); return try await automatic() },
            discard: { recorder.discard($0) })
    }

    /// Counts calls.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.withLock { count } }
        func increment() { lock.withLock { count += 1 } }
    }

    private static func credential(_ token: String, expiresIn seconds: TimeInterval) -> IrxRelayCredential {
        IrxRelayCredential(
            relayURL: "https://relay.example.test", token: token,
            expiresAt: Date().addingTimeInterval(seconds), refreshAfter: Date().addingTimeInterval(seconds - 300))
    }

    private static func waitUntil(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("1, 4, 7. relay ready at 300 ms, direct at 900 ms: direct wins and the relay is closed")
    func directWithinDeadlineBeatsAReadyRelay() async throws {
        let recorder = Recorder()
        let started = ContinuousClock.now
        let result = try await Self.race(
            direct: { try await Task.sleep(for: .milliseconds(900)); return "direct" },
            automatic: { try await Task.sleep(for: .milliseconds(50)); return "relay" },
            recorder: recorder)
        let elapsed = started.duration(to: .now)
        #expect(result.value == "direct")
        #expect(result.lane == .direct)
        #expect(elapsed >= .milliseconds(850) && elapsed < .milliseconds(1400), "decided after \(elapsed)")
        await Self.waitUntil { recorder.discarded == ["relay"] }
        #expect(recorder.discarded == ["relay"])
    }

    @Test("2, 3, 7. direct never answers: the relay wins at the 1.5 s deadline, not before and not after")
    func blackholedDirectFallsBackAtTheDeadline() async throws {
        let recorder = Recorder()
        let started = ContinuousClock.now
        let result = try await Self.race(
            direct: { try await Task.sleep(for: .seconds(30)); return "direct" },
            automatic: { try await Task.sleep(for: .milliseconds(50)); return "relay" },
            recorder: recorder)
        let elapsed = started.duration(to: .now)
        #expect(result.value == "relay")
        #expect(result.lane == .automatic)
        #expect(elapsed >= .milliseconds(1400), "the ready relay was not held for direct: \(elapsed)")
        #expect(elapsed < .milliseconds(2200), "waited \(elapsed), past the direct deadline")
    }

    @Test("5. direct works at once: the relay is never dialed")
    func directAtOnceNeverDialsTheRelay() async throws {
        let recorder = Recorder()
        let result = try await Self.race(
            direct: { "direct" },
            automatic: { "relay" },
            recorder: recorder)
        #expect(result.value == "direct")
        #expect(result.lane == .direct)
        try await Task.sleep(for: .milliseconds(400))
        #expect(recorder.startedLegs == ["direct"])
        #expect(recorder.discarded.isEmpty)
    }

    @Test("6. direct fails fast: the relay starts at once and wins")
    func directFailingFastUsesTheRelayAtOnce() async throws {
        let recorder = Recorder()
        let started = ContinuousClock.now
        let result = try await Self.race(
            direct: { throw DialFailed() },
            automatic: { "relay" },
            recorder: recorder)
        #expect(result.value == "relay")
        #expect(result.lane == .automatic)
        #expect(started.duration(to: .now) < .milliseconds(200))
    }

    @Test("8. an expired relay credential is refreshed in the relay leg: the lane races at once, and wins although the refresh fails")
    func anExpiredCredentialIsRefreshedBesideTheLane() async throws {
        let recorder = Recorder()
        let refreshes = Counter()
        let relay = MobileIrxRuntimeComposition.supermuxRelayLeg(
            cached: [Self.credential("expired", expiresIn: -60)],
            refresh: {
                // The internet is down: the refresh fails after its round trip.
                refreshes.increment()
                try await Task.sleep(for: .milliseconds(100))
                throw DialFailed()
            },
            dial: { _ in "relay" })
        let started = ContinuousClock.now
        let result = try await Self.race(
            direct: { try await Task.sleep(for: .milliseconds(600)); return "direct" },
            automatic: relay,
            recorder: recorder)
        let elapsed = started.duration(to: .now)
        #expect(result.value == "direct", "the refresh's failure ended the dial before the lane")
        #expect(result.lane == .direct)
        #expect(elapsed < .milliseconds(1000), "the lane waited for the refresh: \(elapsed)")
        #expect(recorder.startedLegs == ["direct", "relay"])
        #expect(refreshes.value == 1)

        // A lane that wins inside the relay's head start never refreshes.
        let quiet = Counter()
        let quick = try await Self.race(
            direct: { "direct" },
            automatic: MobileIrxRuntimeComposition.supermuxRelayLeg(
                cached: [], refresh: { quiet.increment(); return [] }, dial: { _ in "relay" }),
            recorder: Recorder())
        try await Task.sleep(for: .milliseconds(400))
        #expect(quick.lane == .direct)
        #expect(quiet.value == 0, "a dial direct won still refreshed the relay credential")
    }

    @Test("9. the relay leg dials with a usable credential as it is, and with the fresh one after a refresh")
    func theRelayLegDialsWithTheRightCredential() async throws {
        let usable = Self.credential("usable", expiresIn: 3600)
        let expired = Self.credential("expired", expiresIn: -60)
        let fresh = Self.credential("fresh", expiresIn: 1800)
        let refreshes = Counter()
        let refresh: @Sendable () async throws -> [IrxRelayCredential] = {
            refreshes.increment()
            return [fresh]
        }
        let kept = try await MobileIrxRuntimeComposition.supermuxRelayLeg(
            cached: [expired, usable], refresh: refresh, dial: { $0 })()
        #expect(kept == [expired, usable])
        #expect(refreshes.value == 0, "a usable credential was refreshed")
        let renewed = try await MobileIrxRuntimeComposition.supermuxRelayLeg(
            cached: [expired], refresh: refresh, dial: { $0 })()
        #expect(renewed == [fresh])
        #expect(refreshes.value == 1)
        // A dial that may not refresh (no control service) dials with what it has.
        let asIs = try await MobileIrxRuntimeComposition.supermuxRelayLeg(
            cached: [expired], refresh: nil, dial: { $0 })()
        #expect(asIs == [expired])
    }
}
// SUPERMUX:end phone-route-direct-race
