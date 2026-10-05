import Foundation
import Testing
@testable import SupermuxKit

/// What this Mac does about its own sleep, wake and network changes.
///
/// Field evidence (2026-10-05): a MacBook Pro asleep with its lid closed
/// DarkWoke 90–165 times an hour (Wi-Fi TCP keepalive offload); its app dialed
/// and accepted links inside those 2–35 s wakes, and every one was a zombie
/// (~31 s, both sides "connected", nothing flowing). macOS posts no wake
/// notification for a DarkWake. After real wakes, direct took up to minutes to
/// come back: iroh's clock stops in sleep, nothing on macOS told it the network
/// changed, and its sessions and per-peer path blocks outlived the sleep.
///
/// Ways the policy could get it wrong, one test each:
/// 1. A short sleep (under a minute, sessions may still be live) rebuilds the
///    main endpoint and drops every phone and inbound link for nothing.
/// 2. A long sleep does not rebuild it (zombie sessions, stale relay socket and
///    path blocks survive the night).
/// 3. The sleep is measured on a clock that stops while asleep, so every sleep
///    reads ~0 s; or a wall clock set backwards reads as a negative or huge sleep.
/// 4. One wake (didWake, then the screens waking) recovers twice.
/// 5. A wake whose willSleep this app never saw (an unknown sleep) rebuilds.
/// 6. A DarkWake counts as a wake: the Mac stays dark until a full wake.
/// 7. A willSleep again while dark (back to sleep from a DarkWake) restarts the
///    sleep clock, so a whole night reads as the last few minutes.
/// 8. A network change while dark (Wi-Fi drops as the lid closes, or changes in
///    a DarkWake) recovers: probes and lane rebuilds out of a sleeping laptop.
/// 9. The screens waking without a system sleep (display sleep only) runs a
///    recovery; only a screens wake that ends a sleep is a full wake.
/// 10. A network change while awake does not recover (Tailscale up, a new LAN).
/// 11. A stuck dark state (a lost wake notification) can never be left: a
///     display that is awake ends it.
struct SupermuxWakePolicyTests {
    typealias Policy = SupermuxWakePolicy
    private let t0 = Date(timeIntervalSince1970: 1_000)

    private func at(_ seconds: TimeInterval) -> Date {
        t0.addingTimeInterval(seconds)
    }

    private func asleep(at seconds: TimeInterval = 0) -> Policy {
        var policy = Policy()
        policy.willSleep(at: at(seconds))
        return policy
    }

    @Test("1. a sleep under a minute recovers without rebuilding the main endpoint")
    func shortSleepKeepsTheEndpoint() {
        var policy = asleep()
        let recovery = policy.woke(.wake, at: at(59))
        #expect(recovery == .init(reason: .wake, sleptSeconds: 59, rebuildsMainEndpoint: false))
        #expect(!policy.isDark)
    }

    @Test("2. a sleep of a minute or more rebuilds the main endpoint")
    func longSleepRebuildsTheEndpoint() {
        var policy = asleep()
        #expect(policy.woke(.wake, at: at(60))?.rebuildsMainEndpoint == true)
        var night = asleep()
        #expect(night.woke(.wake, at: at(8 * 3600)) == .init(reason: .wake, sleptSeconds: 8 * 3600, rebuildsMainEndpoint: true))
    }

    @Test("3. the sleep is the wall-clock gap; a clock set backwards is an unknown sleep, never a rebuild")
    func wallClockMeasuresTheSleep() {
        var policy = asleep(at: 100)
        #expect(policy.woke(.wake, at: at(100 + 3_600))?.sleptSeconds == 3_600)
        var skewed = asleep(at: 100)
        let recovery = skewed.woke(.wake, at: at(40))
        #expect(recovery == .init(reason: .wake, sleptSeconds: nil, rebuildsMainEndpoint: false))
    }

    @Test("4. didWake and the screens waking after it are one recovery")
    func oneWakeRecoversOnce() {
        var policy = asleep()
        #expect(policy.woke(.wake, at: at(300)) != nil)
        #expect(policy.woke(.screensWake, at: at(301)) == nil)
        #expect(policy.woke(.wake, at: at(305)) == nil, "a repeated didWake of the same wake")
        var screensFirst = asleep()
        #expect(screensFirst.woke(.screensWake, at: at(300))?.rebuildsMainEndpoint == true)
        #expect(screensFirst.woke(.wake, at: at(300.5)) == nil)
    }

    @Test("5. a didWake with no willSleep seen recovers without a rebuild")
    func unknownSleepNeverRebuilds() {
        var policy = Policy()
        #expect(policy.woke(.wake, at: at(10)) == .init(reason: .wake, sleptSeconds: nil, rebuildsMainEndpoint: false))
        #expect(policy.woke(.wake, at: at(11)) == nil, "the same wake again")
        #expect(policy.woke(.wake, at: at(600)) != nil, "a later wake recovers again")
    }

    @Test("6. between willSleep and a full wake the Mac is dark, however long the process runs")
    func darkUntilAFullWake() {
        var policy = Policy()
        #expect(!policy.isDark)
        policy.willSleep(at: at(0))
        #expect(policy.isDark)
        // DarkWakes post nothing; time alone never ends the dark state.
        #expect(policy.networkChanged(at: at(40)) == nil)
        #expect(policy.isDark)
        _ = policy.woke(.wake, at: at(3_000))
        #expect(!policy.isDark)
    }

    @Test("7. a second willSleep while dark keeps the first: the night is measured whole")
    func reSleepKeepsTheSleepClock() {
        var policy = asleep(at: 0)
        policy.willSleep(at: at(7_000))
        #expect(policy.woke(.wake, at: at(7_030))?.sleptSeconds == 7_030)
    }

    @Test("8. a network change while dark does nothing; the full wake recovers")
    func networkChangeWhileDarkIsIgnored() {
        var policy = asleep()
        #expect(policy.networkChanged(at: at(1)) == nil)
        #expect(policy.networkChanged(at: at(500)) == nil)
        #expect(policy.woke(.wake, at: at(900))?.rebuildsMainEndpoint == true)
    }

    @Test("9. the screens waking without a system sleep is not a recovery")
    func displayWakeAloneIsNotARecovery() {
        var policy = Policy()
        #expect(policy.woke(.screensWake, at: at(10)) == nil)
        #expect(policy.woke(.displayAwake, at: at(20)) == nil)
        #expect(!policy.isDark)
    }

    @Test("10. a network change while awake recovers without a rebuild")
    func networkChangeWhileAwakeRecovers() {
        var policy = Policy()
        #expect(policy.networkChanged(at: at(10)) == .init(reason: .networkChange, sleptSeconds: nil, rebuildsMainEndpoint: false))
        #expect(policy.networkChanged(at: at(11)) != nil, "a later change is a new path; the caller debounces bursts")
    }

    @Test("11. an awake display ends a dark state whose wake notification was lost")
    func awakeDisplayEndsTheDarkState() {
        var policy = asleep()
        let recovery = policy.woke(.displayAwake, at: at(120))
        #expect(recovery == .init(reason: .displayAwake, sleptSeconds: 120, rebuildsMainEndpoint: true))
        #expect(!policy.isDark)
    }
}
