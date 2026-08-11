import Foundation
import Testing
@testable import SupermuxClaudeHarness

/// Queue delivery-state transitions and pause/resume semantics.
struct InputQueueTests {
    @Test func fifoDispatchOneAtATime() {
        var queue = ClaudeInputQueue()
        let a = ClaudeQueuedInput(text: "a")
        let b = ClaudeQueuedInput(text: "b")
        queue.enqueue(a)
        queue.enqueue(b)

        #expect(queue.nextForDispatch()?.id == a.id)
        #expect({ queue.markDispatching(id: a.id) }())
        // Nothing else dispatches while one item is in flight.
        #expect(queue.nextForDispatch() == nil)

        #expect({ queue.markAcknowledged(id: a.id) }())
        #expect(queue.nextForDispatch()?.id == b.id)
    }

    @Test func invalidTransitionsAreRejected() {
        var queue = ClaudeInputQueue()
        let input = ClaudeQueuedInput(text: "x")
        queue.enqueue(input)
        // queued → acknowledged skips dispatching: invalid.
        #expect(!{ queue.markAcknowledged(id: input.id) }())
        // queued → uncertain: invalid.
        #expect(!{ queue.markUncertain(id: input.id) }())
        #expect({ queue.markDispatching(id: input.id) }())
        // dispatching → dispatching: invalid.
        #expect(!{ queue.markDispatching(id: input.id) }())
        #expect({ queue.markUncertain(id: input.id) }())
        // uncertain is terminal for automatic transitions.
        #expect(!{ queue.markAcknowledged(id: input.id) }())
        #expect(!{ queue.cancel(id: input.id) }())
    }

    @Test func processEndPausesAndMarksInflightUncertain() {
        var queue = ClaudeInputQueue()
        let inflight = ClaudeQueuedInput(text: "inflight")
        let waiting = ClaudeQueuedInput(text: "waiting")
        queue.enqueue(inflight)
        queue.enqueue(waiting)
        queue.markDispatching(id: inflight.id)

        queue.pauseForProcessEnd()
        #expect(queue.isPaused)
        #expect(queue.entries.first { $0.id == inflight.id }?.state == .uncertain)
        // Queued items are preserved but not dispatched while paused.
        #expect(queue.entries.first { $0.id == waiting.id }?.state == .queued)
        #expect(queue.nextForDispatch() == nil)

        queue.resume()
        #expect(queue.nextForDispatch()?.id == waiting.id)
        // The uncertain entry is never auto-resent.
        #expect(queue.entries.first { $0.id == inflight.id }?.state == .uncertain)
    }

    @Test func cancelRemovesFromDispatchOrder() {
        var queue = ClaudeInputQueue()
        let a = ClaudeQueuedInput(text: "a")
        let b = ClaudeQueuedInput(text: "b")
        queue.enqueue(a)
        queue.enqueue(b)
        #expect({ queue.cancel(id: a.id) }())
        #expect(queue.nextForDispatch()?.id == b.id)
    }

    @Test func compactRemovesTerminalEntries() {
        var queue = ClaudeInputQueue()
        let done = ClaudeQueuedInput(text: "done")
        let cancelled = ClaudeQueuedInput(text: "cancelled")
        let uncertain = ClaudeQueuedInput(text: "uncertain")
        let waiting = ClaudeQueuedInput(text: "waiting")
        queue.enqueue(done)
        queue.enqueue(cancelled)
        queue.enqueue(uncertain)
        queue.enqueue(waiting)
        queue.markDispatching(id: done.id)
        queue.markAcknowledged(id: done.id)
        queue.cancel(id: cancelled.id)
        queue.markDispatching(id: uncertain.id)
        queue.markUncertain(id: uncertain.id)

        queue.compact()
        #expect(queue.entries.map(\.id) == [uncertain.id, waiting.id])
    }

    @Test func queuedInputRoundTripsThroughCodable() throws {
        let input = ClaudeQueuedInput(text: "persisted", state: .uncertain)
        let data = try JSONEncoder().encode(input)
        let decoded = try JSONDecoder().decode(ClaudeQueuedInput.self, from: data)
        #expect(decoded == input)
    }
}
