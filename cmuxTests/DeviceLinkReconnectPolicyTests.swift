import Foundation
import Testing
// SUPERMUX:begin device-link-unproven-session-backoff
import SupermuxKit
// SUPERMUX:end device-link-unproven-session-backoff

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The recovery contract of one device link, as the pure reducer states it: a
/// network blip or remote relaunch redials at once, repeated failures back off
/// to a bounded ceiling, presence drops park the link, and a non-retryable
/// failure blocks until something about the device changes.
@Suite("Devices: link reconnect policy")
struct DeviceLinkReconnectPolicyTests {
    private func failure(_ kind: DeviceLinkFailure.Kind, _ message: String) -> DeviceLinkFailure {
        DeviceLinkFailure(kind: kind, code: kind.rawValue, message: message)
    }

    // SUPERMUX:begin device-link-unproven-session-backoff
    // Upstream: a loss after 30 s up redialed at once, as did the first of a
    // run of short-lived losses, and the backoff table stopped at 30 s. A
    // session now has to prove the other Mac healthy (an answered request and
    // two minutes up); any other loss backs off (SupermuxDeviceLinkBackoffTests
    // in SupermuxKit holds the full matrix).
    private let connectedAt = Date(timeIntervalSince1970: 1_000)

    private var provenAt: Date {
        connectedAt.addingTimeInterval(SupermuxDeviceLinkSession.provenLifetime)
    }

    @Test("Repeated connect-and-close cycles back off from the first loss, doubling")
    func flappingTransportBacksOff() {
        var policy = DeviceLinkReconnectPolicy()
        _ = policy.apply(.directory(dialable: true))
        for failure in 1...8 {
            _ = policy.apply(.connectSucceeded, now: connectedAt)
            _ = policy.apply(.supermuxExchanged, now: connectedAt)
            // About 31 s up, as on the congested relay: past upstream's bar, not proven.
            #expect(policy.apply(.transportLost, now: connectedAt.addingTimeInterval(31)) == .waiting(
                attempt: failure, delay: DeviceLinkReconnectPolicy.delay(afterFailures: failure)
            ))
            #expect(policy.apply(.waitElapsed) == .connecting(attempt: failure + 1))
        }
    }

    @Test("A proven link that drops redials at once, then backs off; a proven recovery resets the count")
    func connectLoseRetry() {
        var policy = DeviceLinkReconnectPolicy()
        #expect(policy.phase == .idle)
        #expect(policy.apply(.directory(dialable: true)) == .connecting(attempt: 1))
        #expect(policy.apply(.connectSucceeded, now: connectedAt) == .connected)
        _ = policy.apply(.supermuxExchanged, now: connectedAt)
        #expect(policy.apply(.transportLost, now: provenAt) == .connecting(attempt: 1), "a blip or remote restart redials immediately")
        #expect(policy.apply(.connectFailed(failure(.transient, "refused"))) == .waiting(attempt: 1, delay: .seconds(1)))
        #expect(policy.apply(.waitElapsed) == .connecting(attempt: 2))
        #expect(policy.apply(.connectFailed(failure(.transient, "refused"))) == .waiting(attempt: 2, delay: .seconds(2)))
        #expect(policy.apply(.waitElapsed) == .connecting(attempt: 3))
        #expect(policy.apply(.connectFailed(failure(.transient, "refused"))) == .waiting(attempt: 3, delay: .seconds(4)))
        #expect(policy.apply(.waitElapsed) == .connecting(attempt: 4))
        #expect(policy.apply(.connectSucceeded, now: connectedAt) == .connected)
        _ = policy.apply(.supermuxExchanged, now: connectedAt)
        #expect(policy.apply(.transportLost, now: provenAt) == .connecting(attempt: 1), "a proven recovered link resets the attempt count")
    }

    @Test("A session that proved nothing, or went silent, never redials at once")
    func unprovenOrSilentSessionBacksOff() {
        var policy = DeviceLinkReconnectPolicy()
        _ = policy.apply(.directory(dialable: true))
        _ = policy.apply(.connectSucceeded, now: connectedAt)
        #expect(
            policy.apply(.transportLost, now: connectedAt.addingTimeInterval(600)) == .waiting(attempt: 1, delay: .seconds(1)),
            "ten minutes up without an answer beyond the handshake proves nothing"
        )
        _ = policy.apply(.waitElapsed)
        _ = policy.apply(.connectSucceeded, now: connectedAt)
        _ = policy.apply(.supermuxExchanged, now: connectedAt)
        #expect(
            policy.apply(.supermuxUnresponsive, now: provenAt) == .waiting(attempt: 1, delay: .seconds(1)),
            "a proven session that stopped answering backs off from the first step"
        )
        #expect(policy.apply(.supermuxExchanged, now: provenAt) == .waiting(attempt: 1, delay: .seconds(1)), "an exchange changes no phase")
        #expect(policy.apply(.supermuxUnresponsive, now: provenAt) == .waiting(attempt: 1, delay: .seconds(1)), "only a live link can be lost")
    }
    // SUPERMUX:end device-link-unproven-session-backoff

    // SUPERMUX:begin route-switch
    @Test("A planned redial leaves a live link after a short settle and dials attempt 1; nothing else moves")
    func plannedRedialSettlesThenDialsAfresh() {
        var policy = DeviceLinkReconnectPolicy()
        _ = policy.apply(.directory(dialable: true))
        _ = policy.apply(.connectFailed(failure(.transient, "x")))
        _ = policy.apply(.waitElapsed)
        #expect(policy.apply(.connectSucceeded, now: connectedAt) == .connected)
        #expect(policy.apply(.supermuxPlannedRedial, now: connectedAt) == .waiting(
            attempt: 0, delay: SupermuxDeviceLinkBackoff.plannedRedialSettle))
        #expect(policy.apply(.waitElapsed) == .connecting(attempt: 1), "a move is not a failure: the streak starts over")
        #expect(policy.apply(.supermuxPlannedRedial) == .connecting(attempt: 1), "only a live link moves")
        _ = policy.apply(.connectSucceeded, now: connectedAt)
        let outdated = DeviceLinkFailure.controlPlaneOutdated()
        _ = policy.apply(.directory(dialable: true, precondition: outdated))
        #expect(policy.apply(.supermuxPlannedRedial) == .connected, "a precondition would block the redial, so the link stays")
    }
    // SUPERMUX:end route-switch

    @Test("A below-link cancellation during a dial enters the reconnect policy")
    func interruptedConnectRetries() {
        var policy = DeviceLinkReconnectPolicy()
        #expect(policy.apply(.directory(dialable: true)) == .connecting(attempt: 1))
        #expect(
            policy.apply(.connectInterrupted) == .waiting(
                attempt: 1, delay: DeviceLinkReconnectPolicy.delay(afterFailures: 1)
            ),
            "a cancellation from the engine is a failed dial, not a completed teardown"
        )
        #expect(policy.apply(.waitElapsed) == .connecting(attempt: 2))
    }

    // SUPERMUX:begin device-link-unproven-session-backoff
    @Test("Backoff doubles to a two-minute ceiling")
    func backoffTable() {
        #expect(DeviceLinkReconnectPolicy.delay(afterFailures: 0) == .seconds(1))
        #expect(DeviceLinkReconnectPolicy.delay(afterFailures: 1) == .seconds(1))
        #expect(DeviceLinkReconnectPolicy.delay(afterFailures: 2) == .seconds(2))
        #expect(DeviceLinkReconnectPolicy.delay(afterFailures: 4) == .seconds(8))
        #expect(DeviceLinkReconnectPolicy.delay(afterFailures: 6) == .seconds(32))
        #expect(DeviceLinkReconnectPolicy.delay(afterFailures: 8) == .seconds(120))
        #expect(DeviceLinkReconnectPolicy.delay(afterFailures: 50) == .seconds(120))
    }
    // SUPERMUX:end device-link-unproven-session-backoff

    @Test("A presence drop parks the link; coming back online redials from the first attempt")
    func presenceEdges() {
        var policy = DeviceLinkReconnectPolicy()
        _ = policy.apply(.directory(dialable: true))
        _ = policy.apply(.connectFailed(failure(.transient, "x")))
        #expect(policy.apply(.directory(dialable: false)) == .idle)
        #expect(policy.isDialable == false)
        #expect(policy.apply(.waitElapsed) == .idle, "a stale wait never redials an offline device")
        #expect(policy.apply(.transportLost) == .idle)
        #expect(policy.apply(.refreshRequested) == .idle, "refresh cannot dial an offline device")
        #expect(policy.apply(.directory(dialable: true)) == .connecting(attempt: 1))
        #expect(policy.apply(.directory(dialable: true)) == .connecting(attempt: 1), "repeat presence ticks do not restart a dial")
        _ = policy.apply(.connectSucceeded)
        #expect(policy.apply(.directory(dialable: true)) == .connected, "a presence tick never tears down a live link")
    }

    @Test("Non-retryable failures block until a refresh or presence change; stop always idles")
    func blockedAndStopped() {
        var policy = DeviceLinkReconnectPolicy()
        let otherAccount = failure(.identity, "other account")
        _ = policy.apply(.directory(dialable: true))
        #expect(policy.apply(.connectFailed(otherAccount)) == .blocked(otherAccount))
        #expect(policy.apply(.waitElapsed) == .blocked(otherAccount))
        #expect(policy.apply(.transportLost) == .blocked(otherAccount))
        #expect(policy.apply(.directoryRevisionAdvanced) == .blocked(otherAccount), "a new directory revision cannot change an identity verdict")
        #expect(policy.apply(.refreshRequested) == .connecting(attempt: 1))
        _ = policy.apply(.connectSucceeded)
        #expect(policy.apply(.refreshRequested) == .connected, "refresh does not tear down a healthy link")
        #expect(policy.apply(.stopped) == .idle)
        #expect(policy.apply(.connectSucceeded) == .idle, "a late success after stop is ignored")
        #expect(policy.apply(.refreshRequested) == .connecting(attempt: 1), "the directory verdict survives a stop")
        let blocked = failure(.unsupported, "blocked")
        _ = policy.apply(.connectFailed(blocked))
        #expect(policy.apply(.directory(dialable: true)) == .blocked(blocked), "ordinary directory updates cannot retry an identity rejection")
        #expect(policy.apply(.directory(dialable: false)) == .idle)
        #expect(policy.apply(.directory(dialable: true)) == .connecting(attempt: 1), "a real dialability change permits a new attempt")
    }

    @Test("A failure that lands after the device went offline idles instead of waiting")
    func failureAfterOffline() {
        var policy = DeviceLinkReconnectPolicy()
        _ = policy.apply(.directory(dialable: true))
        #expect(policy.apply(.directory(dialable: false)) == .idle)
        #expect(policy.apply(.connectFailed(failure(.transient, "x"))) == .idle)
        #expect(policy.apply(.connectSucceeded) == .idle)
    }

    @Test("The other Mac's refusal parks the link; only a new directory revision, a refresh, or a dialability change retries it")
    func hostRefusalRetriesOnDirectoryRevision() {
        var policy = DeviceLinkReconnectPolicy()
        let refusal = failure(.hostDenied, "Studio has not authorized this Mac.")
        _ = policy.apply(.directory(dialable: true))
        #expect(policy.apply(.connectFailed(refusal)) == .blocked(refusal))
        #expect(policy.apply(.waitElapsed) == .blocked(refusal), "no timer redials a refusal")
        #expect(policy.apply(.directory(dialable: true)) == .blocked(refusal), "presence ticks do not redial a refusal")
        #expect(policy.apply(.directoryRevisionAdvanced) == .connecting(attempt: 1), "the control plane re-issued permissions")
        #expect(policy.apply(.connectFailed(refusal)) == .blocked(refusal))
        #expect(policy.apply(.refreshRequested) == .connecting(attempt: 1))
        _ = policy.apply(.connectFailed(refusal))
        #expect(policy.apply(.directory(dialable: false)) == .idle)
        #expect(policy.apply(.directoryRevisionAdvanced) == .idle, "an undialable device never redials")
    }

    @Test("A directory precondition parks the link without a dial and releases it when the directory satisfies it")
    func controlPlanePrecondition() {
        var policy = DeviceLinkReconnectPolicy()
        let outdated = DeviceLinkFailure.controlPlaneOutdated()
        #expect(policy.apply(.directory(dialable: true, precondition: outdated)) == .blocked(outdated))
        #expect(policy.apply(.waitElapsed) == .blocked(outdated))
        #expect(policy.apply(.directoryRevisionAdvanced) == .blocked(outdated), "a revision that still lacks the rule changes nothing")
        #expect(policy.apply(.refreshRequested) == .blocked(outdated), "an explicit refresh cannot override what the directory proved")
        #expect(policy.apply(.directory(dialable: true)) == .connecting(attempt: 1), "the directory now names the rule")
        _ = policy.apply(.connectFailed(failure(.transient, "blip")))
        #expect(policy.apply(.refreshRequested) == .connecting(attempt: 1), "with the precondition cleared, refresh retries as before")
        #expect(policy.apply(.directory(dialable: true, precondition: outdated)) == .blocked(outdated), "a dial in flight is abandoned")
        _ = policy.apply(.directory(dialable: true))
        _ = policy.apply(.connectSucceeded)
        #expect(policy.apply(.directory(dialable: true, precondition: outdated)) == .connected, "a live link is proof the precondition is stale")
        #expect(policy.apply(.transportLost) == .blocked(outdated), "once that link is gone the precondition governs; no redial")
        #expect(policy.apply(.refreshRequested) == .blocked(outdated))
        #expect(policy.apply(.directory(dialable: false, precondition: outdated)) == .idle)
    }
}
