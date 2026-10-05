import Foundation

/// When a device asks one Mac for its direct addresses
/// (`mobile.supermux.route.candidates`): at once on each new connection,
/// again ``refreshInterval`` after an answer that settled it, and
/// ``retryInterval`` after one that did not. Shared by the Mac and the phone.
///
/// Pure state, one per Mac connection; the owner asks when ``isDue(at:)``
/// says so and reports what came back.
public struct SupermuxRouteCandidateFetchSchedule: Equatable, Sendable {
    /// What one ask came back with.
    public enum Answer: Equatable, Sendable {
        /// Addresses, now in the store.
        case stored
        /// An empty list (an older host before its first network report): kept the old ones.
        case empty
        /// The host has no addresses yet (``SupermuxRouteCandidates/notReadyErrorCode``).
        case notReady
        /// The host turned direct paths off (``SupermuxRouteCandidates/directOffErrorCode``): forget the peer.
        case directOff
        /// The ask failed.
        case failed
        /// The host does not serve the method.
        case unsupported

        /// The answer for a reply that listed `addresses`.
        public init(addresses: [String]) {
            self = addresses.isEmpty ? .empty : .stored
        }

        /// The answer for a reply that failed with `errorCode`.
        public init(errorCode: String?) {
            switch errorCode {
            case SupermuxRouteCandidates.notReadyErrorCode: self = .notReady
            case SupermuxRouteCandidates.directOffErrorCode: self = .directOff
            default: self = .failed
            }
        }

        /// Whether it settles the question for ``refreshInterval``.
        var settles: Bool {
            switch self {
            case .stored, .directOff, .unsupported: true
            case .empty, .notReady, .failed: false
            }
        }
    }

    /// How long a settled answer stands.
    public static let refreshInterval: TimeInterval = 600
    /// The least time between asks.
    public static let retryInterval: TimeInterval = 60

    /// Whether an ask is out.
    public private(set) var inFlight = false
    private var attemptedAt: Date?
    private var settledAt: Date?

    public init() {}

    /// Whether to ask now.
    public func isDue(at now: Date) -> Bool {
        guard !inFlight else { return false }
        if let settledAt, now.timeIntervalSince(settledAt) < Self.refreshInterval { return false }
        if let attemptedAt, now.timeIntervalSince(attemptedAt) < Self.retryInterval { return false }
        return true
    }

    /// An ask went out.
    public mutating func started(at now: Date) {
        inFlight = true
        attemptedAt = now
    }

    /// The ask came back with `answer`.
    public mutating func finished(_ answer: Answer, at now: Date) {
        inFlight = false
        if answer.settles { settledAt = now }
    }

    /// A new connection to the Mac: ask at once (an ask still out stays out).
    public mutating func connected() {
        attemptedAt = nil
        settledAt = nil
    }
}

extension SupermuxRouteCandidates {
    /// The host's error code while it has no direct address yet (iroh fills
    /// them after its first network report, 1–3 s after binding).
    public static let notReadyErrorCode = "not_ready"
    /// The host's error code when its direct paths are off (relay-only).
    public static let directOffErrorCode = "direct_off"
}
