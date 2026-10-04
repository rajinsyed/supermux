// SUPERMUX:begin irx-accept-loop-concurrent-handshakes (one stalled inbound handshake must not hold up the next — see SUPERMUX-TOUCHPOINTS.md)
import Foundation

/// Drains an endpoint's inbound queue and hands each established connection
/// to the caller.
///
/// `next` yields the next connection attempt before its handshake, and
/// returns `nil` once the endpoint is closed. `establish` completes one
/// handshake and returns `nil` when it fails.
public struct IrxInboundAcceptLoop<Incoming: Sendable, Inbound: Sendable>: Sendable {
    private let maximumPendingHandshakes: Int
    private let next: @Sendable () async -> Incoming?
    private let establish: @Sendable (Incoming) async -> Inbound?
    private let refuse: @Sendable (Incoming) async -> Void

    /// Creates an accept loop.
    /// - Parameters:
    ///   - maximumPendingHandshakes: Attempts allowed to handshake at once;
    ///     later ones are refused until one finishes.
    ///   - next: The endpoint's next connection attempt, `nil` once closed.
    ///   - establish: Completes one handshake; `nil` when it fails.
    ///   - refuse: Turns away an attempt over the pending limit.
    public init(
        maximumPendingHandshakes: Int = 10,
        next: @escaping @Sendable () async -> Incoming?,
        establish: @escaping @Sendable (Incoming) async -> Inbound?,
        refuse: @escaping @Sendable (Incoming) async -> Void
    ) {
        self.maximumPendingHandshakes = maximumPendingHandshakes
        self.next = next
        self.establish = establish
        self.refuse = refuse
    }

    /// Accepts until the endpoint closes or the task is cancelled.
    /// - Parameter deliver: Receives each established connection.
    public func run(deliver: @escaping @Sendable (Inbound) async -> Void) async {
        while !Task.isCancelled, let incoming = await next() {
            guard let inbound = await establish(incoming) else { continue }
            await deliver(inbound)
        }
    }
}
// SUPERMUX:end irx-accept-loop-concurrent-handshakes
