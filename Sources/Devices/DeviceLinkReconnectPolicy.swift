import Foundation
// SUPERMUX:begin device-link-unproven-session-backoff
import SupermuxKit
// SUPERMUX:end device-link-unproven-session-backoff

/// The reconnect state machine for one device link, as a pure reducer so the
/// recovery contract (network blip, remote app restart, presence flip, sign-out,
/// a host's refusal, an outdated Devices service) is unit-testable without a
/// transport.
///
/// Signals, not timers, drive it: presence edges from the directory, the
/// transport closing, an RPC failing, a new directory revision, and an explicit
/// refresh. The only timer is the bounded backoff `waiting` names, which the
/// owner sleeps on and then feeds back as `.waitElapsed`.
struct DeviceLinkReconnectPolicy: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        /// Nothing to do: the device is offline, undialable, or the link is stopped.
        case idle
        case connecting(attempt: Int)
        case connected
        /// Backing off after `attempt` failures; reconnect once `delay` elapses.
        case waiting(attempt: Int, delay: Duration)
        /// A non-retryable failure. Only a signal that can change the answer
        /// leaves it: a refresh, a route or pairing change, and for a host's
        /// refusal a new directory revision.
        case blocked(DeviceLinkFailure)
    }

    enum Event: Equatable, Sendable {
        /// The directory's view of the device changed. `dialable` folds online,
        /// routes, and account trust; `precondition` is a failure the directory
        /// itself proves (the Devices service cannot have told the host to
        /// admit this Mac), so no dial is attempted while it holds.
        case directory(dialable: Bool, precondition: DeviceLinkFailure? = nil)
        case connectSucceeded
        case connectFailed(DeviceLinkFailure)
        /// The dial was canceled below the link owner, so it must be retried.
        case connectInterrupted
        /// The live transport closed or an RPC on it failed.
        case transportLost
        case waitElapsed
        case refreshRequested
        /// The control plane issued a new directory revision: the one authority
        /// that can change another Mac's admission decision.
        case directoryRevisionAdvanced
        case stopped
        // SUPERMUX:begin device-link-unproven-session-backoff
        /// The live session answered a request beyond the dial's handshake.
        case supermuxExchanged
        /// The other Mac stopped answering: a reply missed its deadline and the
        /// liveness check after it found no sign of life. Never redials at once.
        case supermuxUnresponsive
        // SUPERMUX:end device-link-unproven-session-backoff
        // SUPERMUX:begin route-switch
        /// Move a live link onto a better path (the direct lane answered): not
        /// a failure, so one short settle and the next dial is attempt 1.
        case supermuxPlannedRedial
        // SUPERMUX:end route-switch
    }

    static let delays: [Duration] = [.seconds(1), .seconds(2), .seconds(5), .seconds(10), .seconds(30)]

    static func delay(afterFailures failures: Int) -> Duration {
        // SUPERMUX:begin device-link-unproven-session-backoff
        // Doubling from 1 s to a 2 min cap; upstream's `delays` table (capped at
        // 30 s) is no longer read. DeviceLink spreads each wait by ±20 %.
        SupermuxDeviceLinkBackoff.delay(afterFailures: failures)
        // SUPERMUX:end device-link-unproven-session-backoff
    }

    private(set) var phase: Phase = .idle
    /// The directory's latest verdict, remembered so a wait can re-check it.
    private(set) var isDialable = false
    /// The directory's latest precondition. It outranks every other retry
    /// signal: only a later directory event can clear it.
    private(set) var directoryPrecondition: DeviceLinkFailure?
    private var connectedSince: Date?
    private var shortLivedLosses = 0
    static let stableConnectionInterval: TimeInterval = 30
    // SUPERMUX:begin device-link-unproven-session-backoff
    /// The live session: when it connected, from which dial attempt, and
    /// whether it answered anything beyond the handshake. Its end decides the
    /// redial (``SupermuxDeviceLinkSession/redial(endedAt:unresponsive:)``).
    private var supermuxSession: SupermuxDeviceLinkSession?
    // SUPERMUX:end device-link-unproven-session-backoff

    mutating func apply(_ event: Event, now: Date = .distantPast) -> Phase {
        switch event {
        case .stopped:
            phase = .idle
            connectedSince = nil
            shortLivedLosses = 0
        case .directory(let dialable, let precondition):
            isDialable = dialable
            directoryPrecondition = precondition
            if !dialable {
                phase = .idle
                connectedSince = nil
                shortLivedLosses = 0
            } else if let precondition {
                // A live link is proof the precondition is stale; anything
                // short of that parks on it, including a dial in flight.
                if phase != .connected { phase = .blocked(precondition) }
            } else {
                switch phase {
                case .idle:
                    phase = .connecting(attempt: 1)
                case .blocked(let failure) where failure.kind == .controlPlaneOutdated:
                    // The directory now satisfies the precondition it failed.
                    shortLivedLosses = 0
                    phase = .connecting(attempt: 1)
                case .connecting, .connected, .waiting, .blocked:
                    break
                }
            }
        case .connectSucceeded:
            if case .connecting = phase {
                // SUPERMUX:begin device-link-unproven-session-backoff
                if case .connecting(let attempt) = phase {
                    supermuxSession = SupermuxDeviceLinkSession(connectedAt: now, attempt: attempt)
                }
                // SUPERMUX:end device-link-unproven-session-backoff
                phase = .connected
                connectedSince = now
            }
        // SUPERMUX:begin device-link-unproven-session-backoff
        case .supermuxExchanged:
            if phase == .connected { supermuxSession?.noteExchange() }
        // SUPERMUX:end device-link-unproven-session-backoff
        case .connectFailed(let failure):
            guard case .connecting(let attempt) = phase else { return phase }
            guard isDialable else { phase = .idle; return phase }
            phase = failure.isRetryable
                ? .waiting(attempt: attempt, delay: Self.delay(afterFailures: attempt))
                : .blocked(failure)
        case .connectInterrupted:
            guard case .connecting(let attempt) = phase else { return phase }
            guard isDialable else { phase = .idle; return phase }
            phase = .waiting(attempt: attempt, delay: Self.delay(afterFailures: attempt))
        // SUPERMUX:begin device-link-unproven-session-backoff
        case .transportLost, .supermuxUnresponsive:
        // SUPERMUX:end device-link-unproven-session-backoff
            guard phase == .connected else { return phase }
            guard isDialable else { phase = .idle; return phase }
            if let directoryPrecondition {
                // The precondition arrived while the link was live; now that
                // the link is gone it governs, and no redial is attempted.
                connectedSince = nil
                shortLivedLosses = 0
                phase = .blocked(directoryPrecondition)
                return phase
            }
            // SUPERMUX:begin device-link-unproven-session-backoff
            // Upstream counted a loss after 30 s up as stable and redialed the
            // first loss at once. A session must now prove the other Mac healthy
            // (an answered request and 2 min up) to be redialed at once; any
            // other loss continues the backoff of the dial that opened it.
            let session = supermuxSession ?? SupermuxDeviceLinkSession(connectedAt: now, attempt: 1)
            supermuxSession = nil
            connectedSince = nil
            switch session.redial(endedAt: now, unresponsive: event == .supermuxUnresponsive) {
            case .now:
                phase = .connecting(attempt: 1)
            case .after(let attempt, let delay):
                phase = .waiting(attempt: attempt, delay: delay)
            }
            // SUPERMUX:end device-link-unproven-session-backoff
        // SUPERMUX:begin route-switch
        case .supermuxPlannedRedial:
            guard phase == .connected, isDialable, directoryPrecondition == nil else { return phase }
            supermuxSession = nil
            connectedSince = nil
            // The settle lets the old session release its slot; `waitElapsed` dials attempt 1.
            phase = .waiting(attempt: 0, delay: SupermuxRouteSwitchPolicy.plannedRedialSettle)
        // SUPERMUX:end route-switch
        case .waitElapsed:
            guard case .waiting(let attempt, _) = phase else { return phase }
            phase = isDialable ? .connecting(attempt: attempt + 1) : .idle
        case .refreshRequested:
            guard isDialable else { phase = .idle; return phase }
            if let directoryPrecondition {
                // A refresh re-reads the directory; it cannot override what
                // the directory already proved. A live link stays live.
                if phase != .connected { phase = .blocked(directoryPrecondition) }
                return phase
            }
            switch phase {
            case .idle, .waiting, .blocked:
                shortLivedLosses = 0
                phase = .connecting(attempt: 1)
            case .connecting, .connected:
                break
            }
        case .directoryRevisionAdvanced:
            // A host's refusal was its reading of the previous revision. Identity
            // and route blocks are not the control plane's to change.
            guard case .blocked(let failure) = phase, failure.kind == .hostDenied, isDialable else { return phase }
            shortLivedLosses = 0
            phase = .connecting(attempt: 1)
        }
        return phase
    }
}
