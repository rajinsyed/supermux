// SUPERMUX:begin terminal-stream-fair-queue (whole-file fork test — see SUPERMUX-TOUCHPOINTS.md)
import Foundation
import Testing
@testable import CmuxMobileHost

/// A connection that watches terminals (`mobile.supermux.terminal.watch`)
/// must send a shown terminal's output promptly while other terminals flood.
///
/// The ways it could fail, written before the fix (2026-10-05, a 300 ms relay
/// at 300 KB/s: a keystroke's echo waited 11 s behind a hidden terminal):
/// - a shown terminal's bytes wait behind a hidden terminal's backlog;
/// - one shown terminal's backlog holds another shown terminal's bytes;
/// - a status event (`workspace.updated`) waits behind terminal bytes;
/// - reordering breaks one terminal's byte order (its viewer would draw the
///   stream out of order: corruption, not delay);
/// - a hidden terminal's backlog grows for as long as it prints, so showing
///   it later means draining seconds of stale output first;
/// - pausing a hidden terminal loses the signal that it skipped output: the
///   viewer must see the gap when the terminal is shown again, even when it
///   printed nothing since;
/// - a shown terminal, or a hidden one barely behind, gets paused;
/// - the drain stops while watched bytes are still queued;
/// - (2026-10-05, D3: replies and events on one stream, each event write
///   then a 1.7 MB replay reply) the echo of the terminal being typed in
///   waits for every other shown terminal's turn, one reply each;
/// - that terminal, printing a flood, starves the other shown ones.
/// - (2026-10-06, review S5) a paused hidden terminal stays frozen once its
///   pane is shown when the viewer's watch never reaches the host (its
///   retries ran out behind replays): input typed into a terminal proves
///   it is on screen there, so it must bring a paused terminal back (its
///   newest chunk first, the drain claimed) and take a background one out
///   of the batches, until the connection's next watch says otherwise;
/// - typing into a shown terminal queues a chunk of its own.
@Suite("Supermux watched terminal bytes: visible first, fair, hidden ones pause")
struct SupermuxWatchedByteQueueTests {
    private let shown = UUID().uuidString
    private let other = UUID().uuidString
    private let hidden = UUID().uuidString

    private func makeQueue(maximumAge: Duration = .seconds(60)) -> MobileHostConnectionEventQueue {
        let queue = MobileHostConnectionEventQueue()
        queue.supermuxBackgroundByteMaximumAge = maximumAge
        queue.updateSubscribedTopics(["terminal.bytes", "workspace.updated"])
        queue.supermuxWatchTerminalBytes(surfaceIDs: [shown, other, hidden], background: [hidden])
        return queue
    }

    @discardableResult
    private func bytes(_ queue: MobileHostConnectionEventQueue, _ surfaceID: String, _ value: UInt8) -> MobileHostEventEnqueueResult {
        queue.enqueue(topic: "terminal.bytes", coalesceKey: surfaceID, isFullRenderGridFrame: false, frame: Data([value]))
    }

    private func drain(_ queue: MobileHostConnectionEventQueue) -> [UInt8] {
        var frames: [UInt8] = []
        while let event = queue.dequeue() { frames.append(event.frame[0]) }
        return frames
    }

    @Test("A shown terminal's bytes leave before a hidden terminal's backlog")
    func shownBeforeHidden() {
        let queue = makeQueue()
        for value in UInt8(1)...5 { #expect(bytes(queue, hidden, value).admitted) }
        #expect(bytes(queue, shown, 100).admitted)
        #expect(queue.dequeue()?.frame == Data([100]))
        #expect(drain(queue) == [1, 2, 3, 4, 5])
    }

    @Test("Shown terminals take turns, each in its own order")
    func shownTerminalsTakeTurns() {
        let queue = makeQueue()
        for value in UInt8(1)...4 { bytes(queue, shown, value) }
        for value in UInt8(11)...12 { bytes(queue, other, value) }
        #expect(drain(queue) == [1, 11, 2, 12, 3, 4])
    }

    @Test("The terminal being typed in gets every other turn among shown terminals")
    func typedTerminalEveryOtherTurn() {
        let queue = makeQueue()
        for value in UInt8(1)...3 { bytes(queue, other, value) }
        for value in UInt8(100)...103 { bytes(queue, shown, value) }
        queue.supermuxNoteInteractiveSurface(shown)
        #expect(drain(queue) == [100, 1, 101, 2, 102, 3, 103])
    }

    @Test("Other events do not wait behind terminal bytes")
    func otherEventsFirst() {
        let queue = makeQueue()
        for value in UInt8(1)...3 { bytes(queue, shown, value) }
        #expect(queue.enqueue(topic: "workspace.updated", coalesceKey: nil, isFullRenderGridFrame: false, frame: Data([50])).admitted)
        #expect(drain(queue) == [50, 1, 2, 3])
    }

    @Test("A terminal shown mid-backlog keeps its byte order")
    func shownMidBacklogKeepsOrder() {
        let queue = makeQueue()
        for value in UInt8(1)...3 { bytes(queue, hidden, value) }
        bytes(queue, shown, 100)
        queue.supermuxWatchTerminalBytes(surfaceIDs: [shown, other, hidden], background: [])
        for value in UInt8(4)...5 { bytes(queue, hidden, value) }
        let frames = drain(queue)
        #expect(frames.filter { $0 < 100 } == [1, 2, 3, 4, 5])
        #expect(frames.count == 6)
    }

    @Test("The drain keeps running while watched bytes are queued")
    func drainSeesWatchedBytes() {
        let queue = makeQueue()
        #expect(bytes(queue, hidden, 1).startDrain)
        #expect(queue.finishDrain())
        #expect(queue.dequeue() != nil)
        #expect(!queue.finishDrain())
    }

    @Test("A hidden terminal too far behind pauses: its backlog goes, its bytes stop")
    func hiddenTooFarBehindPauses() {
        let queue = makeQueue(maximumAge: .zero)
        #expect(bytes(queue, hidden, 1).admitted)
        #expect(!bytes(queue, hidden, 2).admitted)
        #expect(!bytes(queue, hidden, 3).admitted)
        #expect(bytes(queue, shown, 100).admitted)
        #expect(drain(queue) == [100])
        #expect(queue.byteCount == 0)
        #expect(queue.supermuxWatchedBytePauseCount == 1)
    }

    @Test("Showing a paused terminal sends its newest chunk first, so the viewer sees the gap")
    func showingPausedSendsNewest() {
        let queue = makeQueue(maximumAge: .zero)
        bytes(queue, hidden, 1)
        bytes(queue, hidden, 2)
        bytes(queue, hidden, 3)
        #expect(drain(queue) == [])
        #expect(!queue.finishDrain())
        queue.supermuxWatchTerminalBytes(surfaceIDs: [shown, other, hidden], background: [])
        #expect(queue.claimDrains() == [.shared])
        #expect(bytes(queue, hidden, 4).admitted)
        #expect(drain(queue) == [3, 4])
    }

    @Test("A paused terminal that is no longer watched forgets its newest chunk")
    func unwatchedPausedForgets() {
        let queue = makeQueue(maximumAge: .zero)
        bytes(queue, hidden, 1)
        bytes(queue, hidden, 2)
        _ = drain(queue)
        queue.supermuxWatchTerminalBytes(surfaceIDs: [shown], background: [])
        queue.supermuxWatchTerminalBytes(surfaceIDs: [shown, hidden], background: [])
        #expect(drain(queue) == [])
        #expect(bytes(queue, hidden, 5).admitted)
        #expect(drain(queue) == [5])
    }

    @Test("Shown terminals and hidden ones barely behind never pause")
    func noPauseWhenShownOrYoung() {
        let pausing = makeQueue(maximumAge: .zero)
        for value in UInt8(1)...3 { #expect(bytes(pausing, shown, value).admitted) }
        #expect(drain(pausing) == [1, 2, 3])
        let patient = makeQueue(maximumAge: .seconds(60))
        for value in UInt8(1)...3 { #expect(bytes(patient, hidden, value).admitted) }
        #expect(drain(patient) == [1, 2, 3])
    }

    @Test("Typing into a paused hidden terminal brings it back: its newest chunk first, then its bytes")
    func typingResumesPaused() {
        let queue = makeQueue(maximumAge: .zero)
        bytes(queue, hidden, 1)
        bytes(queue, hidden, 2)
        #expect(drain(queue) == [])
        #expect(!queue.finishDrain())
        queue.supermuxNoteInteractiveSurface(hidden)
        #expect(queue.claimDrains() == [.shared])
        #expect(bytes(queue, hidden, 3).admitted)
        #expect(drain(queue) == [2, 3])
    }

    @Test("Typing into a background terminal shows it for this connection until its next watch")
    func typingShowsBackground() {
        let queue = makeQueue()
        for value in UInt8(1)...2 { bytes(queue, hidden, value) }
        for value in UInt8(100)...102 { bytes(queue, shown, value) }
        queue.supermuxNoteInteractiveSurface(hidden)
        #expect(drain(queue) == [1, 100, 2, 101, 102])
        queue.supermuxWatchTerminalBytes(surfaceIDs: [shown, other, hidden], background: [hidden])
        for value in UInt8(3)...4 { bytes(queue, hidden, value) }
        for value in UInt8(103)...104 { bytes(queue, shown, value) }
        #expect(drain(queue) == [103, 104, 3, 4])
    }

    @Test("Typing into a shown terminal queues nothing")
    func typingShownQueuesNothing() {
        let queue = makeQueue(maximumAge: .zero)
        queue.supermuxNoteInteractiveSurface(shown)
        #expect(queue.claimDrains().isEmpty)
        #expect(drain(queue) == [])
    }

    @Test("Closing forgets paused terminals")
    func closeForgetsPaused() {
        let queue = makeQueue(maximumAge: .zero)
        bytes(queue, hidden, 1)
        bytes(queue, hidden, 2)
        queue.close()
        #expect(queue.claimDrains().isEmpty)
        #expect(queue.byteCount == 0)
    }
}
// SUPERMUX:end terminal-stream-fair-queue
