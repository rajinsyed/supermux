import Foundation
import Testing
@testable import SupermuxKit

/// When a device link dials the other Mac again after losing it.
///
/// Field evidence (2026-10-05): on a congested relay every session lived about
/// 31 s (a 20 s reply deadline, then a 10 s probe that missed), just past the
/// old 30 s "stable" bar, so each loss redialed at once: 132 sessions in under
/// three hours. While a MacBook Pro slept with its lid closed, this Mac's
/// sessions were made inside its DarkWakes and redialed at once again, and
/// half of its DarkWakes came 0–6 s after one of these dials; with nobody
/// answering, the 30 s cap redialed it every 40 s all night.
///
/// Ways the policy could get it wrong, one test each:
/// 1. A session lost to a missed deadline with no sign of life redials at once.
/// 2. A session that never carried an exchange beyond the handshake counts as
///    stable because it stayed up a while.
/// 3. A session that answered early and was lost later than the old bar (a
///    DarkWake connection after the laptop slept again) counts as stable.
/// 4. Consecutive unproven sessions do not grow the wait, so the loop redials
///    at a constant rate.
/// 5. The wait stops at 30 s, so a sleeping Mac is dialed every 40 s all night.
/// 6. The wait grows without a cap (or overflows), so a Mac that comes back
///    waits too long.
/// 7. The wait is never spread, or is spread past ±20 % or below zero, so links
///    that failed together redial in step.
/// 8. A healthy session that the other Mac closed (a restart of its app, a
///    network blip) waits before redialing.
/// 9. A healthy session that then went silent starts its backoff where an old
///    failure streak left it instead of at the first step.
struct SupermuxDeviceLinkBackoffTests {
    private let connected = Date(timeIntervalSince1970: 1_000)

    private func session(attempt: Int = 1, exchanged: Bool) -> SupermuxDeviceLinkSession {
        var session = SupermuxDeviceLinkSession(connectedAt: connected, attempt: attempt)
        if exchanged { session.noteExchange() }
        return session
    }

    private func after(_ seconds: TimeInterval) -> Date {
        connected.addingTimeInterval(seconds)
    }

    @Test("1. a session lost to a missed deadline with no sign of life never redials at once")
    func unresponsiveSessionBacksOff() {
        // The field's sessions: replies at first, then a missed deadline and a failed probe at 30.8 s.
        #expect(session(exchanged: true).redial(endedAt: after(30.8), unresponsive: true) == .after(attempt: 1, delay: .seconds(1)))
    }

    @Test("2. a session without an exchange beyond the handshake is not stable, however long it lived")
    func sessionWithoutExchangeIsNotStable() {
        #expect(session(exchanged: false).redial(endedAt: after(31), unresponsive: false) == .after(attempt: 1, delay: .seconds(1)))
        #expect(session(exchanged: false).redial(endedAt: after(600), unresponsive: false) == .after(attempt: 1, delay: .seconds(1)))
    }

    @Test("3. a DarkWake session (answered, then closed by the idle timeout) is not stable")
    func darkWakeSessionIsNotStable() {
        // Answered inside a DarkWake of up to 35 s, then QUIC's 30 s idle timeout.
        #expect(session(exchanged: true).redial(endedAt: after(65), unresponsive: false) == .after(attempt: 1, delay: .seconds(1)))
    }

    @Test("4. consecutive unproven sessions double the wait")
    func consecutiveUnprovenSessionsGrowTheWait() {
        // The dial that opened each session continues the streak: attempt k waits 2^(k-1) s.
        let redials = (1...8).map { attempt in
            session(attempt: attempt, exchanged: true).redial(endedAt: after(31), unresponsive: false)
        }
        let expected: [SupermuxDeviceLinkSession.Redial] = [1, 2, 4, 8, 16, 32, 64, 120].enumerated().map {
            .after(attempt: $0.offset + 1, delay: .seconds($0.element))
        }
        #expect(redials == expected)
    }

    @Test("5 and 6. the wait grows past 30 s and stops at two minutes")
    func waitIsExponentialAndCapped() {
        let delay = SupermuxDeviceLinkBackoff.delay(afterFailures:)
        #expect(delay(0) == .seconds(1), "a count below one still waits the first step")
        #expect(delay(1) == .seconds(1))
        #expect(delay(2) == .seconds(2))
        #expect(delay(5) == .seconds(16))
        #expect(delay(6) == .seconds(32))
        #expect(delay(8) == .seconds(120))
        #expect(delay(50) == .seconds(120))
        #expect(delay(Int.max) == .seconds(120), "a long streak must not overflow")
        #expect(SupermuxDeviceLinkBackoff.cap == .seconds(120))
    }

    @Test("7. the wait is spread by at most 20 % either way")
    func jitterStaysWithinTwentyPercent() {
        let jittered = SupermuxDeviceLinkBackoff.jittered(_:unit:)
        #expect(jittered(.seconds(10), 0) == .seconds(8))
        #expect(jittered(.seconds(10), 0.5) == .seconds(10))
        #expect(jittered(.seconds(10), 1) == .seconds(12))
        #expect(jittered(.seconds(120), 1) == .seconds(144))
        #expect(jittered(.seconds(10), -3) == .seconds(8), "an out-of-range draw is clamped")
        #expect(jittered(.seconds(10), 7) == .seconds(12), "an out-of-range draw is clamped")
        for _ in 0..<100 {
            let spread = SupermuxDeviceLinkBackoff.jittered(.seconds(30))
            #expect(spread >= .seconds(24) && spread <= .seconds(36))
        }
    }

    @Test("8. a healthy session the other Mac closed redials at once")
    func healthySessionRedialsAtOnce() {
        let healthy = SupermuxDeviceLinkSession.provenLifetime
        #expect(session(attempt: 6, exchanged: true).redial(endedAt: after(healthy), unresponsive: false) == .now)
        #expect(session(exchanged: true).redial(endedAt: after(86_400), unresponsive: false) == .now)
    }

    @Test("9. a healthy session that went silent backs off from the first step")
    func healthySessionThatWentSilentStartsOver() {
        #expect(session(attempt: 6, exchanged: true).redial(endedAt: after(3_600), unresponsive: true) == .after(attempt: 1, delay: .seconds(1)))
    }
}
