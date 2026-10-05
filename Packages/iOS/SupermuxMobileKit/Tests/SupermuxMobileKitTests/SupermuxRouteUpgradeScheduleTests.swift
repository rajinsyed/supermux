import Foundation
import SupermuxMobileKit
import Testing

/// When the phone probes a relayed Mac's direct lane and moves its session
/// (W8). Failure modes, listed before the code:
///
/// 1. A session already on a direct path is probed (and redialed) anyway.
/// 2. A Mac whose direct addresses are unknown is probed (every probe fails).
/// 3. Two probes for one Mac overlap.
/// 4. A Mac that cannot be reached directly is probed every 10 s forever
///    (battery): misses must slow probes to 30 s.
/// 5. A probe that works moves the session every time (a redial storm): at
///    most one move per 30 s.
/// 6. A direct session that just fell back to the relay is moved straight
///    back (flapping).
/// 7. A network change (back on home Wi-Fi) waits out the slowed or held
///    schedule instead of probing at once.
/// 8. New addresses from the Mac wait for the next interval.
/// 9. A relayed session whose dial just lost the race to the relay is
///    probed again immediately.
/// 10. Every phone probes in lockstep (no jitter).
@Suite struct SupermuxRouteUpgradeScheduleTests {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    @Test func relayedMacWithAddressesIsProbedAtOnce() {
        let schedule = SupermuxRouteUpgradeSchedule()
        #expect(schedule.probeDue(onRelay: true, hasCandidates: true, now: start))
    }

    @Test func directSessionIsNeverProbed() {
        let schedule = SupermuxRouteUpgradeSchedule()
        #expect(!schedule.probeDue(onRelay: false, hasCandidates: true, now: start))
    }

    @Test func macWithoutAddressesIsNeverProbed() {
        let schedule = SupermuxRouteUpgradeSchedule()
        #expect(!schedule.probeDue(onRelay: true, hasCandidates: false, now: start))
    }

    @Test func probesNeverOverlap() {
        var schedule = SupermuxRouteUpgradeSchedule()
        schedule.probeStarted()
        #expect(!schedule.probeDue(onRelay: true, hasCandidates: true, now: at(60)))
    }

    @Test func missedProbeWaitsTheIntervalWithJitter() {
        var schedule = SupermuxRouteUpgradeSchedule()
        schedule.probeStarted()
        let moved2204 = schedule.probeFinished(succeeded: false, now: start, jitter: 0)
        #expect(!moved2204)
        #expect(!schedule.probeDue(onRelay: true, hasCandidates: true, now: at(9.9)))
        #expect(schedule.probeDue(onRelay: true, hasCandidates: true, now: at(10)))

        var early = SupermuxRouteUpgradeSchedule()
        _ = early.probeFinished(succeeded: false, now: start, jitter: -1)
        #expect(early.nextProbeAt == at(8))
        var late = SupermuxRouteUpgradeSchedule()
        _ = late.probeFinished(succeeded: false, now: start, jitter: 1)
        #expect(late.nextProbeAt == at(12))
    }

    @Test func fiveMissesInARowSlowProbesToThirtySeconds() {
        var schedule = SupermuxRouteUpgradeSchedule()
        var now = start
        for miss in 1...5 {
            schedule.probeStarted()
            _ = schedule.probeFinished(succeeded: false, now: now, jitter: 0)
            let expected: TimeInterval = miss < 5 ? 10 : 30
            #expect(schedule.nextProbeAt == now.addingTimeInterval(expected), "after miss \(miss)")
            now = schedule.nextProbeAt ?? now
        }
        #expect(schedule.consecutiveFailures == 5)
    }

    @Test func firstProbeThatWorksMovesTheSession() {
        var schedule = SupermuxRouteUpgradeSchedule()
        schedule.probeStarted()
        let moved3494 = schedule.probeFinished(succeeded: true, now: start, jitter: 0)
        #expect(moved3494)
        #expect(schedule.lastSwitchAt == start)
        #expect(!schedule.isProbing)
    }

    @Test func atMostOneMoveEveryThirtySeconds() {
        var schedule = SupermuxRouteUpgradeSchedule()
        let moved3771 = schedule.probeFinished(succeeded: true, now: start, jitter: 0)
        #expect(moved3771)
        // The redial landed on the relay again; the next probe works at once.
        schedule.sessionAdmitted(direct: false, directTried: false, now: at(1))
        let moved4010 = schedule.probeFinished(succeeded: true, now: at(12), jitter: 0)
        #expect(!moved4010)
        #expect(schedule.nextProbeAt == at(30))
        let moved4140 = schedule.probeFinished(succeeded: true, now: at(30), jitter: 0)
        #expect(moved4140)
    }

    @Test func directSessionThatFellBackIsNotMovedBackForThirtySeconds() {
        var schedule = SupermuxRouteUpgradeSchedule()
        schedule.sessionAdmitted(direct: true, directTried: true, now: start)
        schedule.sessionAdmitted(direct: false, directTried: true, now: at(100))
        #expect(schedule.lastFallbackAt == at(100))
        let moved4568 = schedule.probeFinished(succeeded: true, now: at(115), jitter: 0)
        #expect(!moved4568)
        #expect(schedule.nextProbeAt == at(130))
        let moved4700 = schedule.probeFinished(succeeded: true, now: at(130), jitter: 0)
        #expect(moved4700)
    }

    @Test func relayAdmittedAfterLosingTheRaceWaitsOneInterval() {
        var schedule = SupermuxRouteUpgradeSchedule()
        schedule.sessionAdmitted(direct: false, directTried: true, now: start)
        #expect(!schedule.probeDue(onRelay: true, hasCandidates: true, now: at(5)))
        #expect(schedule.probeDue(onRelay: true, hasCandidates: true, now: at(10)))
        // Not a fallback: it was never direct.
        #expect(schedule.lastFallbackAt == nil)
    }

    @Test func relayAdmittedWithoutARaceIsProbedAtOnce() {
        var schedule = SupermuxRouteUpgradeSchedule()
        schedule.sessionAdmitted(direct: false, directTried: false, now: start)
        #expect(schedule.probeDue(onRelay: true, hasCandidates: true, now: start))
    }

    @Test func networkChangeProbesAtOnceAtTheNormalPaceAndLiftsTheFallbackHold() {
        var schedule = SupermuxRouteUpgradeSchedule()
        schedule.sessionAdmitted(direct: true, directTried: true, now: start)
        schedule.sessionAdmitted(direct: false, directTried: true, now: at(1))
        for second in 2...6 {
            _ = schedule.probeFinished(succeeded: false, now: at(TimeInterval(second)), jitter: 0)
        }
        schedule.networkChanged()
        #expect(schedule.consecutiveFailures == 0)
        #expect(schedule.probeDue(onRelay: true, hasCandidates: true, now: at(7)))
        let moved6144 = schedule.probeFinished(succeeded: true, now: at(7), jitter: 0)
        #expect(moved6144)
    }

    @Test func networkChangeKeepsTheOneMovePerThirtySecondsLimit() {
        var schedule = SupermuxRouteUpgradeSchedule()
        let moved6354 = schedule.probeFinished(succeeded: true, now: start, jitter: 0)
        #expect(moved6354)
        schedule.networkChanged()
        let moved6468 = schedule.probeFinished(succeeded: true, now: at(5), jitter: 0)
        #expect(!moved6468)
    }

    @Test func newAddressesProbeAtOnce() {
        var schedule = SupermuxRouteUpgradeSchedule()
        _ = schedule.probeFinished(succeeded: false, now: start, jitter: 0)
        schedule.candidatesChanged()
        #expect(schedule.probeDue(onRelay: true, hasCandidates: true, now: at(1)))
    }

    @Test func directAdmissionClearsTheMisses() {
        var schedule = SupermuxRouteUpgradeSchedule()
        for second in 0..<5 {
            _ = schedule.probeFinished(succeeded: false, now: at(TimeInterval(second)), jitter: 0)
        }
        schedule.sessionAdmitted(direct: true, directTried: true, now: at(10))
        #expect(schedule.consecutiveFailures == 0)
        #expect(schedule.nextProbeAt == nil)
    }
}
