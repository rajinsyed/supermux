import Foundation
import SupermuxMobileCore
import SupermuxMobileKit
import Testing

/// The phone's route decisions per Mac, on the switch policy the Mac runs
/// (review findings I1, I2, I5, I6). Failure modes, listed before the code:
///
/// 1. A direct session that stops answering falls back, and the next dial
///    races the same dead direct path again: the session flaps between a
///    dead direct path and the relay with no hold-off.
/// 2. A second flap holds direct off no longer than the first.
/// 3. A foreground, or a path update that changed nothing, clears the
///    hold-off, so every app switch puts a flapping Mac back on direct.
/// 4. A real network change (other interfaces or addresses) keeps the old
///    network's hold-off, so direct is not retried where it may now work, or
///    a relayed session waits out its probe interval.
/// 5. A direct-lane session whose path iroh no longer reports is never
///    checked: its silence goes unnoticed until QUIC's idle timeout.
/// 6. A failed direct-lane admission lets the next dial race the lane again
///    (a lane whose handshakes work but whose sessions do not loops without
///    the relay), or keeps skipping it.
/// 7. On a network where direct keeps losing (cellular without Tailscale),
///    every dial still holds a ready relay for direct's 1.5 s deadline.
/// 8. A Mac whose session ended is still probed or checked.
/// 9. A session that starts right after a network change waits out its
///    probe interval on the relay.
/// 10. The phone dials addresses it cannot reach from its own interfaces: a
///     LAN on a subnet it is not on, Tailscale with no tunnel up, one of its
///     own addresses; or a duplicate twice.
/// 11. Sign-out keeps the signed-out account's Macs' route state.
@Suite struct SupermuxPhoneRoutePoliciesTests {
    private let mac = "aa11bb22"
    private let start = Date(timeIntervalSince1970: 1_000_000)
    private let direct = SupermuxPhoneRoutePolicies.Sample(isRelay: false, hasRelayPath: false)
    private let relay = SupermuxPhoneRoutePolicies.Sample(isRelay: true, hasRelayPath: true)

    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    private static func interface(_ name: String, _ address: String, _ prefix: Int, p2p: Bool = false) -> SupermuxLocalInterface {
        SupermuxLocalInterface(name: name, address: address, prefixLength: prefix, isPointToPoint: p2p)!
    }

    private let homeWiFi = [Self.interface("en0", "192.168.1.20", 24)]
    private let cellular = [Self.interface("pdp_ip0", "10.0.0.3", 8, p2p: true)]

    /// Admits a direct-lane session at `time` and lets two liveness checks miss.
    private func fallBack(_ policies: inout SupermuxPhoneRoutePolicies, session: String, at time: TimeInterval) -> SupermuxRouteSwitchPolicy.Action {
        policies.sessionAdmitted(for: mac, sessionID: session, lane: .direct, at: at(time), jitter: 0.5)
        var action = SupermuxRouteSwitchPolicy.Action.none
        for tick in 0..<2 {
            let now = at(time + Double(tick))
            guard case .checkLiveness(let number) = policies.observe(
                mac, sessionID: session, sample: direct, hasCandidates: true, at: now) else {
                Issue.record("a direct-lane session was not checked")
                return .none
            }
            action = policies.livenessChecked(for: mac, session: number, answered: false, at: now)
        }
        return action
    }

    @Test("1. a fall back holds direct off for the next dial")
    func fallBackHoldsDirectOff() {
        var policies = SupermuxPhoneRoutePolicies()
        let action = fallBack(&policies, session: "s1", at: 0)
        let redial = policies.dialPlan(for: mac, at: at(2))
        let beforeHoldEnds = policies.dialPlan(for: mac, at: at(30))
        let afterHoldEnds = policies.dialPlan(for: mac, at: at(32))
        #expect(action == .fallBack)
        #expect(!redial.racesDirect, "the redial raced the dead direct path")
        #expect(!beforeHoldEnds.racesDirect)
        #expect(afterHoldEnds.racesDirect)
    }

    @Test("2. each further flap doubles the hold-off")
    func secondFlapHoldsLonger() {
        var policies = SupermuxPhoneRoutePolicies()
        let first = fallBack(&policies, session: "s1", at: 0)
        let second = fallBack(&policies, session: "s2", at: 40)
        let beforeHoldEnds = policies.dialPlan(for: mac, at: at(41 + 58))
        let afterHoldEnds = policies.dialPlan(for: mac, at: at(41 + 61))
        #expect(first == .fallBack && second == .fallBack)
        #expect(!beforeHoldEnds.racesDirect, "the second flap held direct off only 30 s")
        #expect(afterHoldEnds.racesDirect)
    }

    @Test("3. a foreground on the same network keeps the hold-off")
    func foregroundKeepsTheHoldOff() {
        var policies = SupermuxPhoneRoutePolicies()
        let launched = policies.networkSettled(on: homeWiFi, at: at(-10))
        let action = fallBack(&policies, session: "s1", at: 0)
        policies.sessionAdmitted(for: mac, sessionID: "s2", lane: .automatic, at: at(2), jitter: 0.5)

        let foreground = policies.networkSettled(on: homeWiFi, at: at(5))
        let dial = policies.dialPlan(for: mac, at: at(6))
        let step = policies.observe(mac, sessionID: "s2", sample: relay, hasCandidates: true, at: at(6))
        #expect(!launched && action == .fallBack)
        #expect(!foreground, "an unchanged network counted as a change")
        #expect(!dial.racesDirect, "a foreground cleared the hold-off")
        #expect(step == .none, "a held-off Mac was probed")
    }

    @Test("4. a real network change clears the hold-off and probes at once")
    func networkChangeClearsTheHoldOff() {
        var policies = SupermuxPhoneRoutePolicies()
        policies.networkSettled(on: homeWiFi, at: at(-10))
        let action = fallBack(&policies, session: "s1", at: 0)
        policies.sessionAdmitted(for: mac, sessionID: "s2", lane: .automatic, at: at(2), jitter: 0.5)

        let changed = policies.networkSettled(on: cellular, at: at(5))
        let dial = policies.dialPlan(for: mac, at: at(6))
        let step = policies.observe(mac, sessionID: "s2", sample: relay, hasCandidates: true, at: at(6))
        #expect(action == .fallBack)
        #expect(changed)
        #expect(dial.racesDirect)
        #expect(step == .probe(session: 2))
        #expect(policies.isUrgent(at: at(6)))
        #expect(!policies.isUrgent(at: at(16)))
    }

    @Test("5. a direct-lane session is checked while iroh reports no path")
    func directLaneWithoutAPathIsChecked() {
        var policies = SupermuxPhoneRoutePolicies()
        policies.sessionAdmitted(for: mac, sessionID: "s1", lane: .direct, at: at(0), jitter: 0.5)
        let step = policies.observe(mac, sessionID: "s1", sample: nil, hasCandidates: true, at: at(1))
        guard case .checkLiveness(let number) = step else {
            Issue.record("a silent direct-lane session with no path sample went unchecked: \(step)")
            return
        }
        let firstMiss = policies.livenessChecked(for: mac, session: number, answered: false, at: at(1))
        let next = policies.observe(mac, sessionID: "s1", sample: nil, hasCandidates: true, at: at(3))
        guard case .checkLiveness(let again) = next else {
            Issue.record("the second check never came: \(next)")
            return
        }
        let secondMiss = policies.livenessChecked(for: mac, session: again, answered: false, at: at(3))
        // A relayed automatic session with no path yet has nothing to judge.
        policies.sessionAdmitted(for: mac, sessionID: "s2", lane: .automatic, at: at(4), jitter: 0.5)
        let unselected = policies.observe(mac, sessionID: "s2", sample: nil, hasCandidates: true, at: at(60))
        #expect(firstMiss == .none)
        #expect(secondMiss == .fallBack)
        #expect(unselected == .none)
    }

    @Test("6. a failed direct-lane admission skips the lane once")
    func directAdmissionFailureSkipsTheLaneOnce() {
        var policies = SupermuxPhoneRoutePolicies()
        policies.admissionFailed(for: mac, lane: .automatic)
        let afterRelayFailure = policies.dialPlan(for: mac, at: at(0))
        policies.admissionFailed(for: mac, lane: .direct)
        let skipped = policies.dialPlan(for: mac, at: at(1))
        let after = policies.dialPlan(for: mac, at: at(2))
        #expect(afterRelayFailure.racesDirect)
        #expect(!skipped.racesDirect)
        #expect(after.racesDirect)
    }

    @Test("7. lost races stop holding the relay until the network changes")
    func lostRacesStopHoldingTheRelay() {
        var policies = SupermuxPhoneRoutePolicies()
        policies.networkSettled(on: homeWiFi, at: at(0))
        let first = policies.dialPlan(for: mac, at: at(0))
        policies.raceFinished(for: mac, directWon: false)
        policies.raceFinished(for: mac, directWon: false)
        let afterLosses = policies.dialPlan(for: mac, at: at(1))
        policies.networkSettled(on: cellular, at: at(2))
        let afterChange = policies.dialPlan(for: mac, at: at(3))
        #expect(first.holdsRelay)
        #expect(!afterLosses.holdsRelay, "every dial still waits 1.5 s for a direct path that never answers")
        #expect(afterChange.holdsRelay)
    }

    @Test("8. a session the engine no longer has is not followed")
    func endedSessionIsNotFollowed() {
        var policies = SupermuxPhoneRoutePolicies()
        policies.sessionAdmitted(for: mac, sessionID: "s1", lane: .direct, at: at(0), jitter: 0.5)
        let followed = policies.followedMacs
        let ended = policies.observe(mac, sessionID: nil, sample: nil, hasCandidates: true, at: at(1))
        let stale = policies.observe(mac, sessionID: "s1", sample: direct, hasCandidates: true, at: at(2))
        #expect(followed == [mac])
        #expect(ended == .none && stale == .none)
        #expect(policies.followedMacs.isEmpty)
        #expect(policies.lanes[mac] == nil)
        // A session the Direct or Tailscale method made is never followed.
        policies.sessionAdmitted(for: mac, sessionID: "s2", lane: nil, at: at(3), jitter: 0.5)
        #expect(policies.followedMacs.isEmpty)
    }

    @Test("9. a session that starts right after a network change probes at once")
    func sessionAfterANetworkChangeProbesAtOnce() {
        var policies = SupermuxPhoneRoutePolicies()
        policies.sessionAdmitted(for: mac, sessionID: "s1", lane: .automatic, at: at(0), jitter: 0.5)
        _ = policies.observe(mac, sessionID: nil, sample: nil, hasCandidates: true, at: at(1))
        policies.networkSettled(on: homeWiFi, at: at(1))
        policies.networkSettled(on: cellular, at: at(2))
        policies.sessionAdmitted(for: mac, sessionID: "s2", lane: .automatic, at: at(10), jitter: 0.5)
        let step = policies.observe(mac, sessionID: "s2", sample: relay, hasCandidates: true, at: at(10))
        #expect(step == .probe(session: 2))
    }

    @Test("10. only addresses the phone can reach are dialed")
    func onlyReachableAddressesAreDialed() {
        let stored = ["192.168.1.5:58465", "10.9.9.9:58465", "100.101.1.2:58465", "192.168.1.20:58465"]
        let privateAddresses = ["192.168.1.5:58465", "192.168.1.6:58465"]
        #expect(SupermuxPhoneRoutePolicies.directAddresses(
            stored: stored, privateAddresses: privateAddresses, interfaces: homeWiFi)
            == ["192.168.1.5:58465", "192.168.1.6:58465"])
        #expect(SupermuxPhoneRoutePolicies.directAddresses(
            stored: stored, privateAddresses: privateAddresses, interfaces: cellular).isEmpty)
        let tailscale = homeWiFi + [Self.interface("utun4", "100.70.0.9", 32, p2p: true)]
        #expect(SupermuxPhoneRoutePolicies.directAddresses(
            stored: stored, privateAddresses: [], interfaces: tailscale)
            == ["192.168.1.5:58465", "100.101.1.2:58465"])
    }

    @Test("11. sign-out forgets every Mac")
    func resetForgetsEveryMac() {
        var policies = SupermuxPhoneRoutePolicies()
        let action = fallBack(&policies, session: "s1", at: 0)
        policies.reset()
        let dial = policies.dialPlan(for: mac, at: at(1))
        #expect(action == .fallBack)
        #expect(policies.followedMacs.isEmpty)
        #expect(policies.lanes.isEmpty)
        #expect(dial.racesDirect, "the signed-out account's hold-off survived")
    }
}
