// SUPERMUX:begin render-grid-watch (whole-file fork test — see SUPERMUX-TOUCHPOINTS.md)
import Foundation
import Testing
@testable import CmuxMobileHost

/// A phone connection is sent `terminal.render_grid` only for the terminals
/// it shows (STREAM.md H4: the host sent every terminal's frames, and a
/// phone's flood of hidden terminals shed the focused one's).
///
/// The ways it could fail, written before the fix:
/// - an older phone, or one that never reported a viewport, loses frames;
/// - frames of a terminal the phone does not show still go out;
/// - a refused terminal asks the producer for a full frame (it would spin);
/// - a terminal shown again gets a delta whose base the phone never saw
///   (it would draw a corrupt grid, or replay to repair it);
/// - a terminal that never left keeps a broken chain or a forced full frame;
/// - a replayed terminal (a mount starts with a replay) gets no frames until
///   its dedicated report arrives;
/// - an unmounted terminal (its report cleared) keeps getting frames because
///   it was replayed once;
/// - a phone whose app went inactive (every report cleared) gets everything
///   again, or the one that comes back gets nothing;
/// - two phones affect each other; a closed connection's state lingers;
/// - an unchanged set re-requests full frames on every report.
@Suite("Supermux render-grid watch: frames only for terminals the phone shows")
struct SupermuxRenderGridWatchTests {
    private let renderGrid = MobileHostEventTopicPolicy().renderGridTopic
    private let shownID = UUID()
    private let hiddenID = UUID()

    private func frame(_ queue: MobileHostConnectionEventQueue, _ surfaceID: UUID, full: Bool, _ value: UInt8) -> MobileHostEventEnqueueResult {
        queue.enqueue(topic: renderGrid, coalesceKey: surfaceID.uuidString, isFullRenderGridFrame: full, frame: Data([value]))
    }

    private func makeQueue() -> MobileHostConnectionEventQueue {
        let queue = MobileHostConnectionEventQueue()
        queue.updateSubscribedTopics([renderGrid])
        return queue
    }

    // MARK: Queue

    @Test("A connection never told what it shows gets every terminal's frames")
    func untoldGetsEverything() {
        let queue = makeQueue()
        #expect(frame(queue, shownID, full: true, 1).admitted)
        #expect(frame(queue, hiddenID, full: false, 2).admitted)
    }

    @Test("Frames of terminals the phone does not show are refused without a resync")
    func hiddenRefusedWithoutResync() {
        let queue = makeQueue()
        queue.supermuxShowRenderGrid(surfaceIDs: [shownID.uuidString])
        let refused = frame(queue, hiddenID, full: true, 1)
        #expect(!refused.admitted)
        #expect(refused.renderGridResyncSurfaceIDs.isEmpty)
        #expect(frame(queue, shownID, full: false, 2).admitted)
    }

    @Test("A refused terminal shown again waits for a full frame")
    func shownAgainWaitsForFullFrame() {
        let queue = makeQueue()
        queue.supermuxShowRenderGrid(surfaceIDs: [shownID.uuidString])
        #expect(!frame(queue, hiddenID, full: false, 1).admitted)
        queue.supermuxShowRenderGrid(surfaceIDs: [shownID.uuidString, hiddenID.uuidString])
        #expect(!frame(queue, hiddenID, full: false, 2).admitted)
        #expect(frame(queue, hiddenID, full: true, 3).admitted)
        #expect(frame(queue, hiddenID, full: false, 4).admitted)
    }

    @Test("A terminal that was never refused keeps its delta chain")
    func neverRefusedKeepsChain() {
        let queue = makeQueue()
        #expect(frame(queue, shownID, full: true, 1).admitted)
        queue.supermuxShowRenderGrid(surfaceIDs: [shownID.uuidString])
        #expect(frame(queue, shownID, full: false, 2).admitted)
    }

    @Test("Told nil again, the connection gets every terminal's frames")
    func nilRestoresEverything() {
        let queue = makeQueue()
        queue.supermuxShowRenderGrid(surfaceIDs: [])
        #expect(!frame(queue, hiddenID, full: true, 1).admitted)
        queue.supermuxShowRenderGrid(surfaceIDs: nil)
        #expect(frame(queue, hiddenID, full: true, 2).admitted)
    }

    // MARK: Which terminals a connection shows

    private let phone = UUID()
    private let otherPhone = UUID()
    private func open(_: UUID) -> Bool { true }

    @Test("A connection with no dedicated report is not filtered")
    func noReportNoFilter() {
        var state = SupermuxRenderGridWatchState()
        #expect(state.reportsChanged([], isOpen: open).isEmpty)
        #expect(state.replayServed(surfaceID: shownID, connectionID: phone, isOpen: open).isEmpty)
    }

    @Test("The first dedicated report filters the connection to the terminals it reports and replayed")
    func firstReportFilters() {
        var state = SupermuxRenderGridWatchState()
        _ = state.replayServed(surfaceID: hiddenID, connectionID: phone, isOpen: open)
        let changes = state.reportsChanged([.init(surfaceID: shownID, connectionID: phone)], isOpen: open)
        #expect(changes == [.init(connectionID: phone, surfaceIDs: [shownID, hiddenID], joined: [shownID, hiddenID])])
    }

    @Test("A replay adds its terminal; clearing that terminal's report removes it")
    func replayThenClear() {
        var state = SupermuxRenderGridWatchState()
        _ = state.reportsChanged([.init(surfaceID: shownID, connectionID: phone)], isOpen: open)
        #expect(state.replayServed(surfaceID: hiddenID, connectionID: phone, isOpen: open)
            == [.init(connectionID: phone, surfaceIDs: [shownID, hiddenID], joined: [hiddenID])])
        _ = state.reportsChanged([
            .init(surfaceID: shownID, connectionID: phone), .init(surfaceID: hiddenID, connectionID: phone),
        ], isOpen: open)
        #expect(state.reportsChanged([.init(surfaceID: shownID, connectionID: phone)], isOpen: open)
            == [.init(connectionID: phone, surfaceIDs: [shownID], joined: [])])
    }

    @Test("Every report cleared leaves the connection filtered to nothing; a new report brings frames back")
    func inactiveThenBack() {
        var state = SupermuxRenderGridWatchState()
        _ = state.reportsChanged([.init(surfaceID: shownID, connectionID: phone)], isOpen: open)
        #expect(state.reportsChanged([], isOpen: open) == [.init(connectionID: phone, surfaceIDs: [], joined: [])])
        #expect(state.reportsChanged([.init(surfaceID: shownID, connectionID: phone)], isOpen: open)
            == [.init(connectionID: phone, surfaceIDs: [shownID], joined: [shownID])])
    }

    @Test("Two phones are independent, and an unchanged set sends nothing")
    func phonesIndependentAndQuiet() {
        var state = SupermuxRenderGridWatchState()
        let reports: Set<SupermuxRenderGridWatchState.Report> = [
            .init(surfaceID: shownID, connectionID: phone), .init(surfaceID: hiddenID, connectionID: otherPhone),
        ]
        let changes = state.reportsChanged(reports, isOpen: open)
        #expect(Set(changes) == [
            .init(connectionID: phone, surfaceIDs: [shownID], joined: [shownID]),
            .init(connectionID: otherPhone, surfaceIDs: [hiddenID], joined: [hiddenID]),
        ])
        #expect(state.reportsChanged(reports, isOpen: open).isEmpty)
        #expect(state.replayServed(surfaceID: shownID, connectionID: phone, isOpen: open).isEmpty)
    }

    @Test("A closed connection is forgotten")
    func closedForgotten() {
        var state = SupermuxRenderGridWatchState()
        _ = state.reportsChanged([.init(surfaceID: shownID, connectionID: phone)], isOpen: open)
        #expect(state.reportsChanged([], isOpen: { _ in false }).isEmpty)
        // Reopened under the same id (it never is), it starts unfiltered.
        #expect(state.replayServed(surfaceID: hiddenID, connectionID: phone, isOpen: open).isEmpty)
    }
}
// SUPERMUX:end render-grid-watch
