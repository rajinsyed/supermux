import Foundation
import SupermuxMobileKit
import Testing

/// The phone's direct-first dial race (W8). Failure modes, listed before the
/// code:
///
/// 1. Direct works at once, but the relay dial starts anyway (two QUIC
///    sessions, the Mac admits the wrong one or both).
/// 2. Direct is blackholed (a stale LAN address): the dial waits out the
///    direct deadline, or iroh's own connect timeout, before trying the relay.
/// 3. Direct fails fast (no route): the relay still waits out the head start.
/// 4. A leg that succeeds after the race is decided is left open (never
///    closed), so the Mac holds a stray unadmitted connection.
/// 5. Both legs fail: the race hangs, or reports the direct error instead of
///    the relay's.
/// 6. A probe (no fallback) against a blackholed address hangs past its
///    deadline.
/// 7. The caller is cancelled: the race keeps waiting, or a late leg leaks.
/// 8. Direct is slow but wins while the relay is still dialing: the slow
///    direct success is thrown away.
@Suite struct SupermuxDialRaceTests {
    private struct DialFailed: Error, Equatable { let leg: String }

    /// Records which legs started and which values were discarded.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var started = false
        private var closed: [String] = []
        var fallbackStarted: Bool { lock.withLock { started } }
        var discarded: [String] { lock.withLock { closed } }
        func startFallback() { lock.withLock { started = true } }
        func discard(_ value: String) { lock.withLock { closed.append(value) } }
    }

    private let race = SupermuxDialRace(headStart: .milliseconds(80), directDeadline: .milliseconds(400))

    private func waitUntil(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func directThatWorksAtOnceWinsAndTheRelayNeverStarts() async throws {
        let recorder = Recorder()
        let result = try await race.run(
            direct: { "direct" },
            fallback: { recorder.startFallback(); return "relay" },
            discard: { recorder.discard($0) })
        #expect(result.value == "direct")
        #expect(result.lane == .direct)
        try await Task.sleep(for: .milliseconds(200))
        #expect(!recorder.fallbackStarted)
        #expect(recorder.discarded.isEmpty)
    }

    @Test func blackholedDirectFallsBackAfterTheHeadStartNotTheDeadline() async throws {
        let recorder = Recorder()
        let started = ContinuousClock.now
        let result = try await race.run(
            direct: { try? await Task.sleep(for: .seconds(5)); return "direct" },
            fallback: { "relay" },
            discard: { recorder.discard($0) })
        let elapsed = started.duration(to: .now)
        #expect(result.value == "relay")
        #expect(result.lane == .automatic)
        #expect(elapsed >= .milliseconds(80))
        #expect(elapsed < .milliseconds(350), "waited \(elapsed), past the head start")
        // The direct leg is cancelled; whatever it returns is closed.
        await waitUntil { recorder.discarded == ["direct"] }
        #expect(recorder.discarded == ["direct"])
    }

    @Test func directThatFailsFastStartsTheRelayAtOnce() async throws {
        let slowStart = SupermuxDialRace(headStart: .seconds(5), directDeadline: .seconds(10))
        let started = ContinuousClock.now
        let result = try await slowStart.run(
            direct: { throw DialFailed(leg: "direct") },
            fallback: { "relay" },
            discard: { _ in })
        #expect(result.lane == .automatic)
        #expect(started.duration(to: .now) < .seconds(1))
    }

    @Test func lateDirectSuccessAfterTheRelayWonIsClosed() async throws {
        let recorder = Recorder()
        let result = try await race.run(
            direct: {
                // Ignores cancellation, like a native connect already underway.
                let until = ContinuousClock.now.advanced(by: .milliseconds(200))
                while ContinuousClock.now < until { try? await Task.sleep(for: .milliseconds(10)) }
                return "direct"
            },
            fallback: { "relay" },
            discard: { recorder.discard($0) })
        #expect(result.value == "relay")
        await waitUntil { !recorder.discarded.isEmpty }
        #expect(recorder.discarded == ["direct"])
    }

    @Test func lateRelaySuccessAfterDirectWonIsClosed() async throws {
        let recorder = Recorder()
        let result = try await race.run(
            direct: {
                try? await Task.sleep(for: .milliseconds(150))
                return "direct"
            },
            fallback: {
                let until = ContinuousClock.now.advanced(by: .milliseconds(300))
                while ContinuousClock.now < until { try? await Task.sleep(for: .milliseconds(10)) }
                return "relay"
            },
            discard: { recorder.discard($0) })
        #expect(result.value == "direct")
        #expect(result.lane == .direct)
        await waitUntil { !recorder.discarded.isEmpty }
        #expect(recorder.discarded == ["relay"])
    }

    @Test func bothLegsFailingReportsTheRelayError() async {
        await #expect(throws: DialFailed(leg: "relay")) {
            try await race.run(
                direct: { () async throws -> String in throw DialFailed(leg: "direct") },
                fallback: { () async throws -> String in throw DialFailed(leg: "relay") },
                discard: { _ in })
        }
    }

    @Test func blackholedDirectAndFailedRelayEndAtTheDeadline() async {
        let started = ContinuousClock.now
        await #expect(throws: DialFailed(leg: "relay")) {
            try await race.run(
                direct: { () async throws -> String in try await Task.sleep(for: .seconds(5)); return "direct" },
                fallback: { () async throws -> String in throw DialFailed(leg: "relay") },
                discard: { _ in })
        }
        let elapsed = started.duration(to: .now)
        #expect(elapsed >= .milliseconds(390))
        #expect(elapsed < .seconds(1), "waited \(elapsed), past the direct deadline")
    }

    @Test func probeWithoutFallbackSucceedsOnTheDirectLane() async throws {
        let result = try await race.run(direct: { "direct" }, fallback: nil, discard: { _ in })
        #expect(result.value == "direct")
        #expect(result.lane == .direct)
    }

    @Test func probeAgainstABlackholeTimesOutAtTheDeadline() async {
        let started = ContinuousClock.now
        await #expect(throws: SupermuxDialRace.Failure.directTimedOut) {
            try await race.run(
                direct: { () async throws -> String in try await Task.sleep(for: .seconds(5)); return "direct" },
                fallback: nil,
                discard: { _ in })
        }
        #expect(started.duration(to: .now) < .seconds(1))
    }

    @Test func probeReportsTheDirectError() async {
        await #expect(throws: DialFailed(leg: "direct")) {
            try await race.run(
                direct: { () async throws -> String in throw DialFailed(leg: "direct") },
                fallback: nil,
                discard: { _ in })
        }
    }

    @Test func cancellingTheCallerEndsTheRaceAndClosesLateLegs() async throws {
        let recorder = Recorder()
        let task = Task {
            try await race.run(
                direct: {
                    let until = ContinuousClock.now.advanced(by: .milliseconds(250))
                    while ContinuousClock.now < until { try? await Task.sleep(for: .milliseconds(10)) }
                    return "direct"
                },
                fallback: {
                    let until = ContinuousClock.now.advanced(by: .milliseconds(250))
                    while ContinuousClock.now < until { try? await Task.sleep(for: .milliseconds(10)) }
                    return "relay"
                },
                discard: { recorder.discard($0) })
        }
        try await Task.sleep(for: .milliseconds(120))
        let started = ContinuousClock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(started.duration(to: .now) < .milliseconds(100))
        await waitUntil { recorder.discarded.count == 2 }
        #expect(Set(recorder.discarded) == ["direct", "relay"])
    }
}
