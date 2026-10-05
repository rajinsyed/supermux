// SUPERMUX:begin terminal-lane-retry
import CMUXMobileCore
import Foundation
internal import OSLog

private let terminalLaneLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "dev.cmux.ios",
    category: "mobile-terminal-lane"
)

/// When a phone's terminal lane is opened again after it ended or failed.
///
/// A lane that delivered its baseline and then stayed up for
/// ``stableLaneLifetime`` resets the attempt count, so relay drops never add
/// up to giving the lane up; one that ends sooner (a host that accepts the
/// lane and drops it) counts as a failure. Consecutive failures wait
/// 250 ms × 2ⁿ (±20 %), at most 5 s. The lane is retried for as long as its
/// terminal stays mounted on a live connection.
struct SupermuxTerminalLaneRetryDelay: Sendable {
    /// How long a lane must stay up after its baseline to reset the backoff:
    /// the longest delay, so a lane that resets has outlived any wait.
    static let stableLaneLifetime: Duration = .seconds(5)

    var base: Duration = .milliseconds(250)
    var cap: Duration = .seconds(5)

    func delay(forAttempt attempt: Int, jitter: Double = Double.random(in: 0.8...1.2)) -> Duration {
        let exponent = min(max(attempt, 0), 5)
        return min(base * (1 << exponent), cap) * jitter
    }
}

/// One scheduled lane reopen, reported so a lane that keeps failing is
/// visible in the phone's diagnostics instead of silently falling back to RPC.
struct SupermuxTerminalLaneRetryEvent: Sendable {
    let surfaceID: String
    /// Consecutive failures so far, counting this one.
    let attempt: Int
    let delay: Duration
    /// Why the lane is reopened; `nil` when it ended cleanly (the peer or the
    /// relay closed it, or a send failed and closed it).
    let failure: DiagnosticFailureKind?
}

extension MobileShellComposite {
    /// Records each lane reopen in the diagnostic ring and the unified log.
    nonisolated static func terminalLaneRetryObserver(
        diagnosticLog: DiagnosticLog?
    ) -> @Sendable (SupermuxTerminalLaneRetryEvent) -> Void {
        { event in
            let delayMilliseconds = event.delay.components.seconds * 1000
                + event.delay.components.attoseconds / 1_000_000_000_000_000
            diagnosticLog?.record(DiagnosticEvent(
                .retryScheduled,
                surface: DiagnosticCorrelation().handle(for: event.surfaceID),
                ms: UInt32(clamping: delayMilliseconds),
                a: event.attempt,
                b: event.failure?.rawValue
            ))
            terminalLaneLog.notice(
                "terminal lane reopening surface=\(event.surfaceID.prefix(8), privacy: .public) attempt=\(event.attempt, privacy: .public) delay_ms=\(delayMilliseconds, privacy: .public) failure=\(event.failure.map { String($0.rawValue) } ?? "ended", privacy: .public)"
            )
        }
    }
}
// SUPERMUX:end terminal-lane-retry
