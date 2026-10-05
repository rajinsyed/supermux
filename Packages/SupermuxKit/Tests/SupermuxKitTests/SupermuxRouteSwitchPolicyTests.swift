import Foundation
import Testing
@testable import SupermuxKit

/// When a remote Mac's link moves between the direct lane and the relay.
///
/// Field evidence (2026-10-05): every Mac-to-Mac session started on the Tokyo
/// relay (~240 ms a keystroke) and left it only when iroh's own holepunch
/// moved it, with a 5–300 s block on a direct path that once stalled. The user
/// keeps Tailscale on on both Macs and wants direct, LAN or Tailscale, always.
///
/// Ways the policy could get it wrong, one test each:
/// 1. A relayed link is never tried direct again after a dial whose direct leg
///    failed, so it stays on the relay for the whole session.
/// 2. Probing too often (a QUIC handshake every sample) or never slowing down
///    while direct stays dead; probes of several links fire in step.
/// 3. A direct handshake that works does not move the link, or two moves come
///    back to back.
/// 4. A move whose redial lands on the relay again (the probe answered, the
///    race did not) is retried at once, so the link loops.
/// 5. A direct session with no relay path beside it that stops answering is
///    kept until QUIC's 30 s idle timeout.
/// 6. One lost liveness probe tears down a working direct session.
/// 7. A check is started again while one is still out.
/// 8. A direct session that has a relay path beside it (iroh's own upgrade) is
///    checked, probed or torn down; iroh fails it over itself.
/// 9. A direct path that flaps reconnects without bound: every fall back must
///    lengthen the wait before direct is tried again, up to a cap, and a direct
///    session that stays up resets it.
/// 10. A probe or liveness answer for a session that already ended (a natural
///     reconnect raced it) acts on the new session.
/// 11. A link with no live session is probed (a dial that can wake a laptop
///     asleep with its lid closed) or checked.
/// 12. "Probe now" (wake, network change) waits out the slowed cadence, or
///     skips the wait after a fall back.
/// 13. Under a path that is up 7 s and down 4 s for ten minutes, more than four
///     reconnects land in any minute.
struct SupermuxRouteSwitchPolicyTests {
    typealias Policy = SupermuxRouteSwitchPolicy
    private let t0 = Date(timeIntervalSince1970: 1_000)

    private func at(_ seconds: TimeInterval) -> Date {
        t0.addingTimeInterval(seconds)
    }

    private func relayed(startedAt seconds: TimeInterval = 0) -> Policy {
        var policy = Policy()
        policy.sessionStarted(at: at(seconds))
        _ = policy.observe(.relay, at: at(seconds))
        return policy
    }

    @Test("1. a relayed link is tried direct one interval after it connected, one probe at a time")
    func relayedLinkIsProbed() {
        var policy = relayed()
        #expect(policy.observe(.relay, at: at(1)) == .none, "the dial's own direct leg just failed")
        #expect(policy.observe(.relay, at: at(9.9)) == .none)
        #expect(policy.observe(.relay, at: at(10)) == .probe)
        #expect(policy.observe(.relay, at: at(11)) == .none, "a probe is still out")
    }

    @Test("2. failed probes keep a 10 s cadence, then 30 s after five, spread by at most 20 %")
    func failedProbesSlowDown() {
        var policy = relayed()
        var now: TimeInterval = 10
        for failure in 1...5 {
            #expect(policy.observe(.relay, at: at(now)) == .probe, "probe \(failure)")
            #expect(policy.probeFinished(session: policy.session, succeeded: false, at: at(now)) == .none)
            #expect(policy.probeFailures == failure)
            let next = failure < Policy.failuresBeforeSlowProbing ? Policy.probeInterval : Policy.slowProbeInterval
            #expect(policy.observe(.relay, at: at(now + next - 0.1)) == .none)
            now += next
        }
        #expect(policy.observe(.relay, at: at(now)) == .probe)
        #expect(Policy.interval(10, jitter: 0) == 8)
        #expect(Policy.interval(10, jitter: 1) == 12)
        #expect(Policy.interval(30, jitter: 0.5) == 30)
        #expect(Policy.interval(10, jitter: 9) == 12, "an out-of-range draw is clamped")
        _ = policy.probeFinished(session: policy.session, succeeded: false, at: at(now), jitter: 0)
        #expect(policy.observe(.relay, at: at(now + 23.9)) == .none)
        #expect(policy.observe(.relay, at: at(now + 24)) == .probe, "a slow probe spread 20 % early")
    }

    @Test("3. a direct handshake that works moves the link once; the next move waits 30 s")
    func probeSuccessUpgradesOnce() {
        var policy = relayed()
        #expect(policy.observe(.relay, at: at(10)) == .probe)
        #expect(policy.probeFinished(session: policy.session, succeeded: true, at: at(10.2)) == .upgrade)
        #expect(policy.probeFailures == 0)
        // The planned redial lands direct; later that session is lost and the
        // natural redial lands on the relay (its direct leg failed then).
        policy.sessionEnded()
        policy.sessionStarted(at: at(11))
        #expect(policy.observe(.direct(backedUp: false), at: at(11)) == .checkLiveness)
        #expect(policy.livenessChecked(session: policy.session, answered: true, at: at(11)) == .none)
        policy.sessionEnded()
        policy.sessionStarted(at: at(15))
        #expect(policy.observe(.relay, at: at(15)) == .none)
        #expect(policy.flaps == 0, "a session lost for another reason is not a flap")
        #expect(policy.observe(.relay, at: at(25)) == .probe)
        #expect(policy.probeFinished(session: policy.session, succeeded: true, at: at(25)) == .none,
                "15 s after the last move")
        #expect(policy.observe(.relay, at: at(35)) == .probe)
        #expect(policy.probeFinished(session: policy.session, succeeded: true, at: at(35)) == .none)
        #expect(policy.observe(.relay, at: at(45)) == .probe)
        #expect(policy.probeFinished(session: policy.session, succeeded: true, at: at(45)) == .upgrade,
                "35 s after the last move")
    }

    @Test("4. a move whose redial lands on the relay counts as a flap and waits")
    func upgradeLandingOnRelayWaits() {
        var policy = relayed()
        _ = policy.observe(.relay, at: at(10))
        #expect(policy.probeFinished(session: policy.session, succeeded: true, at: at(10)) == .upgrade)
        policy.sessionEnded()
        policy.sessionStarted(at: at(11))
        #expect(policy.observe(.relay, at: at(11)) == .none)
        #expect(policy.flaps == 1)
        #expect(policy.holdOffUntil == at(11 + 30))
        #expect(!policy.allowsDirect(at: at(40.9)), "the next dial goes to the relay alone")
        #expect(policy.observe(.relay, at: at(40.9)) == .none, "no probe during the wait")
        #expect(policy.allowsDirect(at: at(41)))
        #expect(policy.observe(.relay, at: at(41)) == .probe)
    }

    @Test("5. a direct session without a relay path that stops answering falls back after two misses")
    func silentDirectSessionFallsBack() {
        var policy = Policy()
        policy.sessionStarted(at: at(0))
        #expect(policy.observe(.direct(backedUp: false), at: at(0)) == .checkLiveness)
        #expect(policy.livenessChecked(session: policy.session, answered: true, at: at(0.1)) == .none)
        #expect(policy.observe(.direct(backedUp: false), at: at(60)) == .checkLiveness)
        #expect(policy.livenessChecked(session: policy.session, answered: false, at: at(61)) == .none)
        #expect(policy.observe(.direct(backedUp: false), at: at(62)) == .checkLiveness)
        #expect(policy.livenessChecked(session: policy.session, answered: false, at: at(63)) == .fallBack)
        #expect(policy.flaps == 1)
        #expect(!policy.allowsDirect(at: at(63)), "the redial goes to the relay alone")
        #expect(policy.allowsDirect(at: at(63 + 30)))
    }

    @Test("6. one lost liveness probe between answers is not a fall back")
    func oneMissIsForgiven() {
        var policy = Policy()
        policy.sessionStarted(at: at(0))
        for (second, answered) in [(1.0, false), (2.0, true), (3.0, false), (4.0, true), (5.0, false)] {
            #expect(policy.observe(.direct(backedUp: false), at: at(second)) == .checkLiveness)
            #expect(policy.livenessChecked(session: policy.session, answered: answered, at: at(second)) == .none)
        }
        #expect(policy.allowsDirect(at: at(5)))
    }

    @Test("7. a liveness check is not started again while one is out")
    func oneCheckAtATime() {
        var policy = Policy()
        policy.sessionStarted(at: at(0))
        #expect(policy.observe(.direct(backedUp: false), at: at(1)) == .checkLiveness)
        #expect(policy.observe(.direct(backedUp: false), at: at(2)) == .none)
        _ = policy.livenessChecked(session: policy.session, answered: true, at: at(2.5))
        #expect(policy.observe(.direct(backedUp: false), at: at(3)) == .checkLiveness)
    }

    @Test("8. a direct path with a relay path beside it is left to iroh")
    func backedUpDirectIsLeftAlone() {
        var policy = Policy()
        policy.sessionStarted(at: at(0))
        for second in stride(from: 0.0, through: 120, by: 1) {
            #expect(policy.observe(.direct(backedUp: true), at: at(second)) == .none)
        }
    }

    @Test("9. each flap doubles the wait before direct is tried again, to 10 min; a lasting direct session resets it")
    func flapsDoubleTheHoldOff() {
        #expect(Policy.holdOff(afterFlaps: 1) == 30)
        #expect(Policy.holdOff(afterFlaps: 2) == 60)
        #expect(Policy.holdOff(afterFlaps: 3) == 120)
        #expect(Policy.holdOff(afterFlaps: 5) == 480)
        #expect(Policy.holdOff(afterFlaps: 6) == 600)
        #expect(Policy.holdOff(afterFlaps: Int.max) == 600, "a long streak must not overflow")

        var policy = Policy()
        var now: TimeInterval = 0
        for flap in 1...3 {
            policy.sessionStarted(at: at(now))
            for _ in 0..<2 {
                _ = policy.observe(.direct(backedUp: false), at: at(now + 5))
                _ = policy.livenessChecked(session: policy.session, answered: false, at: at(now + 5))
            }
            #expect(policy.flaps == flap)
            #expect(policy.holdOffUntil == at(now + 5 + Policy.holdOff(afterFlaps: flap)))
            policy.sessionEnded()
            now += 5 + Policy.holdOff(afterFlaps: flap)
        }
        policy.sessionStarted(at: at(now))
        _ = policy.observe(.direct(backedUp: false), at: at(now + Policy.stableDirectLifetime))
        #expect(policy.flaps == 0, "two minutes direct proves the path")
        _ = policy.livenessChecked(session: policy.session, answered: false, at: at(now + 121))
        _ = policy.observe(.direct(backedUp: false), at: at(now + 122))
        #expect(policy.livenessChecked(session: policy.session, answered: false, at: at(now + 122)) == .fallBack)
        #expect(policy.holdOffUntil == at(now + 122 + 30), "the wait starts over")
    }

    @Test("10. answers for a session that already ended are ignored")
    func staleAnswersAreIgnored() {
        var policy = relayed()
        #expect(policy.observe(.relay, at: at(10)) == .probe)
        let probed = policy.session
        policy.sessionEnded()
        policy.sessionStarted(at: at(11))
        _ = policy.observe(.relay, at: at(11))
        #expect(policy.probeFinished(session: probed, succeeded: true, at: at(11.5)) == .none)
        #expect(policy.observe(.relay, at: at(21)) == .probe, "the new session keeps its own cadence")

        var direct = Policy()
        direct.sessionStarted(at: at(0))
        _ = direct.observe(.direct(backedUp: false), at: at(1))
        let checked = direct.session
        _ = direct.livenessChecked(session: checked, answered: false, at: at(1))
        _ = direct.observe(.direct(backedUp: false), at: at(2))
        direct.sessionEnded()
        direct.sessionStarted(at: at(3))
        #expect(direct.livenessChecked(session: checked, answered: false, at: at(3)) == .none)
        #expect(direct.allowsDirect(at: at(3)))
    }

    @Test("11. a link with no live session is never probed or checked")
    func noSessionNoWork() {
        var policy = Policy()
        #expect(policy.observe(.relay, at: at(100)) == .none)
        #expect(policy.observe(.direct(backedUp: false), at: at(100)) == .none)
        policy.sessionStarted(at: at(0))
        policy.sessionEnded()
        #expect(policy.observe(.relay, at: at(100)) == .none)
        policy.probeSoon(at: at(100))
        #expect(policy.observe(.relay, at: at(100)) == .none)
    }

    @Test("12. probe now skips the slowed cadence but not the wait after a fall back")
    func probeSoonRespectsHoldOff() {
        var policy = relayed()
        var now: TimeInterval = 10
        for _ in 1...5 {
            _ = policy.observe(.relay, at: at(now))
            _ = policy.probeFinished(session: policy.session, succeeded: false, at: at(now))
            now += 10
        }
        #expect(policy.observe(.relay, at: at(now)) == .none, "30 s cadence now")
        policy.probeSoon(at: at(now))
        #expect(policy.probeFailures == 0)
        #expect(policy.observe(.relay, at: at(now)) == .probe)

        var flapped = Policy()
        flapped.sessionStarted(at: at(0))
        for _ in 0..<2 {
            _ = flapped.observe(.direct(backedUp: false), at: at(1))
            _ = flapped.livenessChecked(session: flapped.session, answered: false, at: at(1))
        }
        flapped.sessionEnded()
        flapped.sessionStarted(at: at(3))
        _ = flapped.observe(.relay, at: at(3))
        flapped.probeSoon(at: at(4))
        #expect(flapped.observe(.relay, at: at(4)) == .none, "still inside the 30 s wait")
        #expect(flapped.observe(.relay, at: at(31)) == .probe)
    }

    @Test("13. a path up 7 s and down 4 s for ten minutes reconnects at most four times in any minute")
    func flappingPathIsBounded() {
        var policy = Policy()
        let isUp: (TimeInterval) -> Bool = { Int($0) % 11 < 7 }
        var seed: UInt64 = 7
        func draw() -> Double {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(seed >> 11) / Double(1 << 53)
        }
        var reconnects: [TimeInterval] = []
        var probe: (session: Int, at: TimeInterval)?
        var check: (session: Int, at: TimeInterval)?
        var path = Policy.Path.direct(backedUp: false)
        var redialAt: TimeInterval?

        func connect(_ now: TimeInterval) {
            // The race: direct when the dial may use it and the path is up.
            path = policy.allowsDirect(at: at(now)) && isUp(now) ? .direct(backedUp: false) : .relay
            policy.sessionStarted(at: at(now), jitter: draw())
        }

        connect(0)
        for tick in 1...600 {
            let now = TimeInterval(tick)
            if let pending = redialAt, now >= pending {
                redialAt = nil
                connect(now)
            }
            guard redialAt == nil else { continue }
            if let out = probe, now >= out.at + 1 {
                probe = nil
                if policy.probeFinished(session: out.session, succeeded: isUp(out.at), at: at(now), jitter: draw()) == .upgrade {
                    reconnects.append(now)
                    policy.sessionEnded()
                    redialAt = now + 1
                    continue
                }
            }
            if let out = check, now >= out.at + 1 {
                check = nil
                if policy.livenessChecked(session: out.session, answered: isUp(out.at), at: at(now)) == .fallBack {
                    reconnects.append(now)
                    policy.sessionEnded()
                    redialAt = now + 1
                    continue
                }
            }
            switch policy.observe(path, at: at(now)) {
            case .probe: probe = (policy.session, now)
            case .checkLiveness: check = (policy.session, now)
            case .none, .upgrade, .fallBack: break
            }
        }
        let worst = reconnects.map { start in reconnects.filter { $0 >= start && $0 < start + 60 }.count }.max() ?? 0
        print("flapping path: \(reconnects.count) reconnects in 10 min at \(reconnects), at most \(worst) in a minute")
        #expect(reconnects.count >= 4, "the path must actually flap the link: \(reconnects)")
        #expect(worst <= 4, "reconnects at \(reconnects)")
        #expect(reconnects.count <= 14, "ten minutes of flapping: \(reconnects)")
    }
}
