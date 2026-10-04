// SUPERMUX:begin irx-accept-loop-concurrent-handshakes (regression coverage — see SUPERMUX-TOUCHPOINTS.md)
import Foundation
import Testing
@testable import CmuxIrxTransport

/// The Mac host accepted one phone at a time: a phone whose handshake stalled
/// (it was killed mid-dial, or its packets stopped) held every later phone
/// until QUIC's 30 s idle timeout. Field log: a phone waited 22.7 s behind one.
@Suite(.timeLimit(.minutes(1)))
struct IrxInboundAcceptLoopTests {
    @Test("a handshake that never completes does not hold up the next connection")
    func stalledHandshakeDoesNotBlockTheNext() async throws {
        let queue = ScriptedIncomingQueue(["stalled", "phone"])
        let stall = IrxAsyncLatch()
        let delivered = DeliveredConnections()
        let loop = IrxInboundAcceptLoop<String, String>(
            next: { await queue.next() },
            establish: { attempt in
                if attempt == "stalled" { await stall.wait(); return nil }
                return attempt
            },
            refuse: { _ in }
        )
        let running = Task { await loop.run { await delivered.append($0) } }
        defer { running.cancel() }

        #expect(await delivered.waitFor("phone"))
        await queue.close()
        await stall.signal()
    }

    @Test("attempts over the pending limit are refused instead of queued")
    func attemptsOverTheLimitAreRefused() async throws {
        let queue = ScriptedIncomingQueue(["first", "second", "third"])
        let stall = IrxAsyncLatch()
        let refused = DeliveredConnections()
        let loop = IrxInboundAcceptLoop<String, String>(
            maximumPendingHandshakes: 2,
            next: { await queue.next() },
            establish: { _ in await stall.wait(); return nil },
            refuse: { await refused.append($0) }
        )
        let running = Task { await loop.run { _ in } }
        defer { running.cancel() }

        #expect(await refused.waitFor("third"))
        #expect(await refused.all() == ["third"])
        await queue.close()
        await stall.signal()
    }

    @Test("the loop ends when the endpoint closes, without waiting for pending handshakes")
    func loopEndsWhenTheEndpointCloses() async throws {
        let queue = ScriptedIncomingQueue(["stalled"])
        let stall = IrxAsyncLatch()
        let loop = IrxInboundAcceptLoop<String, String>(
            next: { await queue.next() },
            establish: { _ in await stall.wait(); return nil },
            refuse: { _ in }
        )
        let finished = IrxAsyncLatch()
        Task {
            await loop.run { _ in }
            await finished.signal()
        }
        await queue.close()

        let ended = try await withIrxDeadline(.seconds(2), onTimeout: {}) {
            await finished.wait()
            return true
        }
        #expect(ended == true)
        await stall.signal()
    }
}

/// An endpoint queue: yields its scripted attempts, then waits for more
/// until closed, when it reports `nil`.
private actor ScriptedIncomingQueue {
    private var attempts: [String]
    private var isClosed = false
    private var waiter: CheckedContinuation<String?, Never>?

    init(_ attempts: [String]) { self.attempts = attempts }

    func next() async -> String? {
        if !attempts.isEmpty { return attempts.removeFirst() }
        if isClosed { return nil }
        return await withCheckedContinuation { waiter = $0 }
    }

    func close() {
        isClosed = true
        waiter?.resume(returning: nil)
        waiter = nil
    }
}

private actor DeliveredConnections {
    private var values: [String] = []

    func append(_ value: String) { values.append(value) }

    func all() -> [String] { values }

    func waitFor(_ value: String) async -> Bool {
        let reached = try? await withIrxDeadline(.seconds(2), onTimeout: {}) {
            while !Task.isCancelled {
                if await self.all().contains(value) { return true }
                try await Task.sleep(for: .milliseconds(5))
            }
            return false
        }
        return reached == true
    }
}
// SUPERMUX:end irx-accept-loop-concurrent-handshakes
