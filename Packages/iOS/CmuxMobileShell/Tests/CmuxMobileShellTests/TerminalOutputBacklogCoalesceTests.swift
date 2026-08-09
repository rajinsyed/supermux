import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileShell

/// Regression for the post-touch-up "phantom momentum" backlog: a surface that
/// applies frames slower than they arrive must not accumulate an unbounded
/// FIFO of nonreplaceable render-grid deltas that keeps painting for seconds
/// after the gesture ends. Past the cap, the whole backlog is replaced by one
/// authoritative replay.
@MainActor
@Test func renderGridBacklogPastCapCoalescesIntoOneReplay() async throws {
    let router = LivenessHostRouter()
    await router.setCapabilities(["events.v1", "terminal.render_grid.v1", "terminal.replay.v1"])
    await router.enqueueReplayTexts(["cold-replay"])
    let box = TransportBox()
    let clock = TestClock()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    let surfaceID = "live-terminal"

    var iterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 1)
    let coldReplayChunk = try #require(await iterator.next())
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: coldReplayChunk.streamToken)
    let barrierCleared = try await pollUntil {
        store.terminalReplayBarrierTokensBySurfaceID[surfaceID] == nil
    }
    #expect(barrierCleared)

    // This frame becomes the in-flight chunk. The surface never acknowledges
    // it (no terminalOutputDidProcess): the verified apply is "slow", exactly
    // the physical-device condition under which the backlog builds.
    #expect(deliverFullFrame(store: store, surfaceID: surfaceID, seq: 100))

    // Everything after the in-flight chunk queues FIFO; cross the cap.
    var seq: UInt64 = 101
    var coalesced = false
    for _ in 0..<(MobileShellComposite.maxTerminalOutputPendingBeforeReplayCoalesce + 8) {
        _ = deliverFullFrame(store: store, surfaceID: surfaceID, seq: seq)
        seq += 1
        if store.terminalReplayBarrierTokensBySurfaceID[surfaceID] != nil {
            coalesced = true
            break
        }
    }

    #expect(
        coalesced,
        "a render-grid backlog past the cap must collapse into a replay barrier instead of queuing unbounded deferred paints"
    )
    let queueDrained = store.terminalOutputQueuesBySurfaceID[surfaceID]?.pendingCount ?? 0
    #expect(
        queueDrained <= 1,
        "the coalesce must clear the pending backlog, got depth \(queueDrained)"
    )
}

@MainActor
private func deliverFullFrame(
    store: MobileShellComposite,
    surfaceID: String,
    seq: UInt64
) -> Bool {
    guard let frame = try? MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: surfaceID,
        stateSeq: seq,
        columns: 16,
        rows: 4,
        text: "frame-\(seq)",
        full: true
    ) else { return false }
    return store.deliverTerminalRenderGrid(frame, surfaceID: surfaceID)
}
