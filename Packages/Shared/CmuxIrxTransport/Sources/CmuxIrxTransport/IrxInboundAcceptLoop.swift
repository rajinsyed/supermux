// SUPERMUX:begin irx-accept-loop-concurrent-handshakes (one stalled inbound handshake must not hold up the next — see SUPERMUX-TOUCHPOINTS.md)
import Foundation
import IrohLib

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

    /// Accepts until the endpoint closes or the task is cancelled. Each
    /// handshake completes on its own task, so a peer that stalls mid-handshake
    /// never holds up the next one; this returns without waiting for them.
    /// - Parameter deliver: Receives each established connection.
    public func run(deliver: @escaping @Sendable (Inbound) async -> Void) async {
        let pending = IrxPendingHandshakes(limit: maximumPendingHandshakes)
        while !Task.isCancelled, let incoming = await next() {
            guard pending.begin() else {
                await refuse(incoming)
                continue
            }
            Task {
                defer { pending.end() }
                guard let inbound = await establish(incoming) else { return }
                await deliver(inbound)
            }
        }
    }
}

/// Counts handshakes in flight against a limit.
private final class IrxPendingHandshakes: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var count = 0

    init(limit: Int) { self.limit = limit }

    /// Claims a slot; false when the limit is reached.
    func begin() -> Bool {
        lock.withLock {
            guard count < limit else { return false }
            count += 1
            return true
        }
    }

    func end() {
        lock.withLock { count -= 1 }
    }
}
/// One completed inbound handshake, before ALPN routing.
struct IrxEstablishedInbound: Sendable {
    let alpn: Data
    let connection: Connection
}

/// Set once a handshake's deadline has passed, so a handshake that completes
/// later closes its connection instead of leaking it.
final class IrxAbandonedHandshake: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool { lock.withLock { value } }

    func set() { lock.withLock { value = true } }
}
// SUPERMUX:end irx-accept-loop-concurrent-handshakes
