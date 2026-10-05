import Foundation
import Testing
@testable import SupermuxMobileCore

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
///
/// Review findings (2026-10-06), written before the fixes:
/// 14. (T4) A wake or a network change keeps the hold-off of a flap that the
///     old network caused, so direct stays off up to 10 min on the new one.
/// 15. (T4) The direct session dying because the network changed counts as a
///     flap and holds direct off 30 s, although the change was the cause.
/// 16. (T5) A recovery while the link is down is forgotten: the session that
///     starts right after it waits the 10 s cadence for its first probe.
/// 17. (T8) A move the owner could not make (its redial did nothing) is later
///     counted as a flap, or blocks the next move for 30 s.
/// 18. (T7) A direct-lane handshake whose admission then fails makes the next
///     dial race the lane again, so a link can loop without the relay.
/// 19. (T13) Where direct cannot work (cellular or a hotel without Tailscale)
///     every dial holds a ready relay connection up to the 1.5 s direct deadline.
/// 20. (H3) A relayed session whose peer's direct addresses are unknown is
///     probed (a failure each time), and new addresses wait out the cadence.
///
/// Second review (2026-10-06), written before the fix:
/// 21. (#9) A network change (or new addresses) while a probe is out is
///     lost: the probe's answer, from the old network, sets the next probe
///     10 s out.
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
        policy.upgradeStarted(at: at(10.2))
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
        policy.upgradeStarted(at: at(10))
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
                    policy.upgradeStarted(at: at(now))
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

    // MARK: - Review findings

    /// A direct session that misses two liveness checks at `seconds`.
    private func fallBack(_ policy: inout Policy, at seconds: TimeInterval) -> Policy.Action {
        var last = Policy.Action.none
        for _ in 0..<2 {
            _ = policy.observe(.direct(backedUp: false), at: at(seconds))
            last = policy.livenessChecked(session: policy.session, answered: false, at: at(seconds))
        }
        return last
    }

    @Test("14. a network change or wake clears the hold-off and the flap count")
    func networkChangeClearsHoldOff() {
        var policy = Policy()
        var now: TimeInterval = 0
        for _ in 1...3 {
            policy.sessionStarted(at: at(now))
            #expect(fallBack(&policy, at: now + 5) == .fallBack)
            policy.sessionEnded()
            now += 5
        }
        #expect(policy.flaps == 3)
        #expect(!policy.allowsDirect(at: at(now + 60)), "two minutes held after three flaps")
        policy.sessionStarted(at: at(now + 1))
        _ = policy.observe(.relay, at: at(now + 1))
        policy.networkChanged(at: at(now + 2))
        #expect(policy.flaps == 0)
        #expect(policy.holdOffUntil == nil)
        #expect(policy.allowsDirect(at: at(now + 2)))
        #expect(policy.observe(.relay, at: at(now + 2)) == .probe, "probed at the next sample")
    }

    @Test("15. the first fall back within 30 s of a network change is not a flap; the next one is")
    func fallBackRightAfterNetworkChangeIsNotAFlap() {
        var policy = Policy()
        policy.sessionStarted(at: at(0))
        _ = policy.observe(.direct(backedUp: false), at: at(0))
        _ = policy.livenessChecked(session: policy.session, answered: true, at: at(0))
        policy.networkChanged(at: at(100))
        #expect(fallBack(&policy, at: 106) == .fallBack, "the old path died with the change")
        #expect(policy.flaps == 0)
        #expect(policy.allowsDirect(at: at(106)), "the redial races direct on the new network")
        policy.sessionEnded()
        policy.sessionStarted(at: at(107))
        #expect(fallBack(&policy, at: 115) == .fallBack)
        #expect(policy.flaps == 1, "a second fall back is the new path flapping")
        #expect(!policy.allowsDirect(at: at(115)))

        var late = Policy()
        late.sessionStarted(at: at(0))
        late.networkChanged(at: at(0))
        #expect(fallBack(&late, at: 31) == .fallBack)
        #expect(late.flaps == 1, "a fall back after the window counts")
    }

    @Test("16. a session that starts within 30 s of a recovery probes at its first sample")
    func recoveryWhileDownProbesTheNextSession() {
        var policy = Policy()
        policy.sessionStarted(at: at(0))
        policy.sessionEnded()
        policy.networkChanged(at: at(100))
        policy.sessionStarted(at: at(103))
        #expect(policy.observe(.relay, at: at(103)) == .probe, "not the 10 s cadence")
        _ = policy.probeFinished(session: policy.session, succeeded: false, at: at(104), jitter: 0.5)
        policy.sessionEnded()
        policy.sessionStarted(at: at(105))
        #expect(policy.observe(.relay, at: at(105)) == .none, "one session per recovery")

        var foreground = Policy()
        foreground.probeSoon(at: at(0))
        foreground.sessionStarted(at: at(20))
        #expect(foreground.observe(.relay, at: at(20)) == .probe)

        var stale = Policy()
        stale.networkChanged(at: at(0))
        stale.sessionStarted(at: at(31))
        #expect(stale.observe(.relay, at: at(31)) == .none, "a recovery 31 s ago is old news")
    }

    @Test("17. a move counts only once its redial happened")
    func unmadeMoveIsNotAFlap() {
        var policy = relayed()
        _ = policy.observe(.relay, at: at(10))
        #expect(policy.probeFinished(session: policy.session, succeeded: true, at: at(10), jitter: 0.5) == .upgrade)
        // The owner's redial did nothing (a directory precondition): the session stays on the relay.
        #expect(policy.observe(.relay, at: at(11)) == .none)
        #expect(policy.flaps == 0, "nothing moved, nothing flapped")
        #expect(policy.allowsDirect(at: at(11)))
        #expect(policy.observe(.relay, at: at(20)) == .probe)
        #expect(policy.probeFinished(session: policy.session, succeeded: true, at: at(20), jitter: 0.5) == .upgrade,
                "an unmade move does not start the 30 s spacing")
    }

    @Test("18. a direct-lane admission that failed sends the next dial to the relay alone, once")
    func failedDirectAdmissionSkipsTheLaneOnce() {
        var policy = Policy()
        var dials: [Bool] = []
        dials.append(policy.dialUsesDirect(at: at(0)))
        policy.directAdmissionFailed()
        dials.append(policy.dialUsesDirect(at: at(1)))
        dials.append(policy.dialUsesDirect(at: at(2)))
        #expect(dials == [true, false, true], "the dial after the failure skips the lane, only once")
        policy.directAdmissionFailed()
        policy.sessionStarted(at: at(3))
        _ = fallBack(&policy, at: 4)
        let afterBoth = [policy.dialUsesDirect(at: at(5)), policy.dialUsesDirect(at: at(6))]
        #expect(afterBoth == [false, false], "a skip and a hold-off both keep the lane out")
    }

    @Test("19. after two lost races on this network the race stops holding a ready relay")
    func lostRacesStopHoldingTheRelay() {
        var policy = Policy()
        #expect(policy.holdsRelayInRace)
        policy.raceFinished(directWon: false)
        #expect(policy.holdsRelayInRace, "one lost race proves little")
        policy.raceFinished(directWon: false)
        #expect(!policy.holdsRelayInRace)
        policy.networkChanged(at: at(0))
        #expect(policy.holdsRelayInRace, "a new network gets the full direct deadline again")
        policy.raceFinished(directWon: false)
        policy.raceFinished(directWon: false)
        policy.raceFinished(directWon: true)
        #expect(policy.holdsRelayInRace, "a direct win resets it")
        policy.raceFinished(directWon: false)
        policy.raceFinished(directWon: false)
        policy.sessionStarted(at: at(1))
        _ = policy.observe(.relay, at: at(11))
        _ = policy.probeFinished(session: policy.session, succeeded: true, at: at(11), jitter: 0.5)
        #expect(policy.holdsRelayInRace, "a direct handshake that works restores it for the move")
    }

    @Test("20. no probe without direct addresses, and no failure counted; new addresses probe at once")
    func noCandidatesNoProbe() {
        var policy = relayed()
        #expect(policy.observe(.relay, hasCandidates: false, at: at(10)) == .none)
        #expect(policy.observe(.relay, hasCandidates: false, at: at(40)) == .none)
        #expect(policy.probeFailures == 0)
        policy.candidatesChanged(at: at(41))
        #expect(policy.observe(.relay, hasCandidates: true, at: at(41)) == .probe)
    }

    @Test("21. a network change or new addresses while a probe is out: the next probe goes right after it")
    func probeSoonDuringAProbe() {
        var policy = relayed()
        #expect(policy.observe(.relay, at: at(10)) == .probe)
        policy.networkChanged(at: at(10.5))
        #expect(policy.probeFinished(session: policy.session, succeeded: false, at: at(11), jitter: 0.5) == .none)
        #expect(policy.observe(.relay, at: at(11)) == .probe, "the change came after this probe left")

        var addresses = relayed()
        #expect(addresses.observe(.relay, at: at(10)) == .probe)
        addresses.candidatesChanged(at: at(10.5))
        _ = addresses.probeFinished(session: addresses.session, succeeded: false, at: at(11), jitter: 0.5)
        #expect(addresses.observe(.relay, at: at(11)) == .probe, "the new addresses were not in this probe")

        var quiet = relayed()
        #expect(quiet.observe(.relay, at: at(10)) == .probe)
        _ = quiet.probeFinished(session: quiet.session, succeeded: false, at: at(11), jitter: 0.5)
        #expect(quiet.observe(.relay, at: at(12)) == .none, "without a change the cadence holds")
        #expect(quiet.observe(.relay, at: at(19)) == .none)
        #expect(quiet.observe(.relay, at: at(21)) == .probe)
    }
}
