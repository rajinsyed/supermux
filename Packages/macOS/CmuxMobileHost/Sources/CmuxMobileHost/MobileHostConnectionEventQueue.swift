public import CMUXMobileCore
public import Foundation

/// Per-topic shedding policy for server-pushed mobile events.
///
/// "Droppable" topics are the refresh-class streams a client can always
/// recover without the host replaying the exact dropped payload:
/// - `terminal.render_grid`: the producer is asked to re-emit a full frame for
///   every surface whose queued frame was shed
///   (``MobileTerminalRenderObserver/requestRenderGridFullResync(surfaceIDStrings:)``),
///   and the per-connection queue refuses further deltas for that surface until
///   the full frame arrives. The iOS client has no delta-continuity check, so a
///   silently dropped delta would corrupt its grid invisibly; the
///   poison-until-full rule makes a shed unobservable beyond one stale paint.
/// - `simulator.frame`: video-style JPEG frames are absolute snapshots keyed by
///   panel id. When a phone cannot drain at the simulator's frame cadence, the
///   newest frame replaces older queued frames; simulator state and ownership
///   events stay lossless.
/// - `terminal.bytes`: chunks carry a byte-offset `seq`; the client detects the
///   gap and requests a replay on its own.
/// - `terminal.updated` / `workspace.updated`: level-triggered pings; the newer
///   occurrence that forced the shed supersedes the shed one.
///
/// Other topics retain their ordered payloads even beyond the shedding budget.
/// Congestion is not evidence that the connection has closed.
public struct MobileHostEventTopicPolicy: Sendable {
    public let renderGridTopic = "terminal.render_grid"
    public let simulatorFrameTopic = "simulator.frame"

    public init() {}

    public func isDroppable(topic: String, coalesceKey: String?) -> Bool {
        switch topic {
        case renderGridTopic:
            // A render-grid event without a surface key cannot be resynced
            // per-surface, so its ordered payload is retained.
            return coalesceKey != nil
        case simulatorFrameTopic:
            // Simulator frames are whole-screen snapshots; a later frame fully
            // supersedes an earlier one for the same panel.
            return coalesceKey != nil
        case "device.workspace.layout":
            // A different topic/workspace cannot replace this snapshot. The
            // viewer has no gap recovery signal, so layout changes stay lossless.
            return false
        case "terminal.bytes", "terminal.updated", "workspace.updated":
            return true
        default:
            return false
        }
    }
}

/// Delivery lane of one queued event. Every lane has its own drain, so a
/// stalled write on one lane never delays events queued on another.
///
/// `.shared` is the ordered events path (independent events stream or the
/// control stream). `.surface` carries one terminal's render-grid frames on
/// its own QUIC stream once the client negotiated surface event lanes.
public enum MobileHostEventLane: Hashable, Sendable {
    case shared
    case surface(String)
}

/// Outcome of one synchronous admission attempt on a connection's event queue.
public struct MobileHostEventEnqueueResult: Sendable {
    /// The event was appended to the queue.
    public let admitted: Bool
    /// The caller must start the drain task for ``drainLane``.
    public let startDrain: Bool
    /// The lane whose drain the caller must start when ``startDrain`` is set.
    public var drainLane: MobileHostEventLane = .shared
    /// Surfaces whose queued render-grid frames were shed; the caller must ask
    /// the producer for a full-frame resync of each.
    public let renderGridResyncSurfaceIDs: Set<String>
    /// Queue depth immediately after an admitted append.
    public let depthAfterEnqueue: Int?
    /// Count of queued droppable events removed to make room for this event.
    public let shedEventCount: Int
    /// Bytes released by shedding droppable events.
    public let shedByteCount: Int
    /// Simulator panel IDs whose queued frame snapshots were superseded.
    public let simulatorFrameShedPanelIDs: Set<String>
    /// A non-droppable event could not fit after eligible shedding. The
    /// owning connection must close rather than allowing the mailbox to grow.
    public let overflowed: Bool

    public static let rejected = MobileHostEventEnqueueResult(
        admitted: false,
        startDrain: false,
        renderGridResyncSurfaceIDs: [],
        depthAfterEnqueue: nil,
        shedEventCount: 0,
        shedByteCount: 0,
        simulatorFrameShedPanelIDs: [],
        overflowed: false
    )
}

private struct MobileHostEventShedSummary: Sendable {
    var eventCount = 0
    var byteCount = 0
    var simulatorFramePanelIDs: Set<String> = []

    mutating func record(_ event: MobileHostConnectionEventQueue.QueuedEvent) {
        eventCount += 1
        byteCount += event.frame.count
        if event.topic == MobileHostEventTopicPolicy().simulatorFrameTopic,
           let coalesceKey = event.coalesceKey {
            simulatorFramePanelIDs.insert(coalesceKey)
        }
    }
}

/// Arrival order of queued event IDs. Consuming or removing an event leaves
/// its ID behind; readers skip IDs that are no longer queued, and `compact`
/// drops them once they outnumber the live ones, so every operation stays
/// amortized O(1).
struct MobileHostQueuedEventOrder {
    private(set) var ids: [UUID] = []
    private(set) var head = 0

    mutating func append(_ id: UUID) {
        ids.append(id)
    }

    mutating func popFirst() -> UUID? {
        guard head < ids.count else { return nil }
        defer { head += 1 }
        return ids[head]
    }

    mutating func compact(liveCount: Int, isQueued: (UUID) -> Bool) {
        guard ids.count > 2 * liveCount + 64 else { return }
        ids = ids[head...].filter(isQueued)
        head = 0
    }
}

/// Synchronously admitted mailbox between event fan-out and one drain per
/// lane. Refresh events have a shedding budget; ordered events are retained
/// until delivery. Admission happens before task creation, so producers never
/// create a separate task retaining each event while the network is slow.
public final class MobileHostConnectionEventQueue: @unchecked Sendable {
    public struct QueuedEvent: Sendable {
        public let topic: String
        public let coalesceKey: String?
        public let frame: Data
        public let stateSeq: UInt64?
        public var lane: MobileHostEventLane = .shared
        /// Stream generation of a surface lane. A new generation means a new
        /// QUIC stream, so the render-grid chain must re-base on it.
        public var laneGeneration: UInt64 = 0
    }

    /// The stream a surface's render-grid chain was last admitted on. Frames
    /// on two different streams can arrive in either order, so a delta may
    /// only follow a frame that travelled the same route.
    private enum RenderGridRoute: Equatable {
        case shared
        case surface(generation: UInt64)
    }

    /// Consecutive failures after which a surface stops using its own lane
    /// and rides the shared lane until surface lanes are renegotiated.
    public static let maximumSurfaceLaneFailureCount = 3

    public static let defaultMaximumEventCount = 256
    public static let defaultMaximumByteCount =
        MobileSyncFrameCodec.defaultMaximumFrameByteCount
        + MobileSyncFrameCodec.headerByteCount

    private let lock = NSLock()
    private let maximumEventCount: Int
    private let maximumByteCount: Int
    private var subscribedTopics: Set<String> = []
    private var queuedEvents: [UUID: QueuedEvent] = [:]
    /// Arrival order across every lane; shedding walks it oldest first.
    private(set) var arrivalOrder = MobileHostQueuedEventOrder()
    /// Arrival order within each lane with queued events; a lane's drain
    /// dequeues from its own order.
    private(set) var laneOrders: [MobileHostEventLane: MobileHostQueuedEventOrder] = [:]
    /// The queued Mac grid snapshot for each surface, so a newer snapshot
    /// replaces it without scanning the queue.
    private var gridEventIDs: [String: UUID] = [:]
    private var queuedByteCount = 0
    /// Lanes with a running drain. At most one drain per lane.
    private var drainingLanes: Set<MobileHostEventLane> = []
    private var overflowed = false
    private var isClosed = false
    /// Maximum concurrently assigned surface lanes; 0 disables surface lanes.
    private var surfaceLaneLimit = 0
    /// Assigned surface lanes and their last-use tick (for LRU reassignment).
    private var surfaceLaneLastUse: [String: UInt64] = [:]
    private var surfaceLaneUseTick: UInt64 = 0
    private var surfaceLaneGenerations: [String: UInt64] = [:]
    private var surfaceLaneFailureCounts: [String: Int] = [:]
    private var sharedLanePinnedSurfaceIDs: Set<String> = []
    private var queuedCountByLane: [MobileHostEventLane: Int] = [:]
    private var lastRenderGridRouteBySurfaceID: [String: RenderGridRoute] = [:]
    /// Surfaces whose delta chain was broken by a shed frame. Only a
    /// full-frame render-grid event readmits the surface; deltas are refused so
    /// the client can never apply a delta whose predecessor was dropped.
    private var poisonedRenderGridSurfaceIDs: Set<String> = []
    /// Poisoned surfaces whose replacement full frame ALSO had to be dropped
    /// (queue full of non-droppable events). Re-requested once the drain frees
    /// room, so a fully stalled connection cannot spin the producer.
    private var resyncAfterDrainSurfaceIDs: Set<String> = []
    /// Panels whose absolute snapshot was shed after the producer considered
    /// it sent. Drain progress requests one exact-session replay for each.
    private var simulatorFrameReplayAfterDrainPanelIDs: Set<String> = []
    // SUPERMUX:begin terminal-stream-watch
    /// The terminals whose `terminal.bytes` this connection asked for
    /// (`mobile.supermux.terminal.watch`); nil keeps upstream's topic-wide
    /// delivery. Their bytes ride a budget of their own, never shed.
    private var supermuxWatchedByteSurfaceIDs: Set<String>?
    /// Queued watched-byte events: their surface, frame size and admission time.
    private var supermuxWatchedEvents: [UUID: (surfaceID: String, byteCount: Int, queuedAt: ContinuousClock.Instant)] = [:]
    private var supermuxWatchedBytesBySurfaceID: [String: Int] = [:]
    private var supermuxWatchedQueuedByteCount = 0
    /// Times one watched terminal outran its budget and its queued bytes
    /// were dropped (the viewer resumes it from its byte position).
    public private(set) var supermuxWatchedByteResyncCount = 0
    // SUPERMUX:end terminal-stream-watch
    // SUPERMUX:begin terminal-stream-fair-queue
    /// How long a hidden terminal's oldest queued bytes may wait before it
    /// pauses (``supermuxPausesLocked``).
    var supermuxBackgroundByteMaximumAge: Duration = .seconds(8)
    /// Times a hidden terminal fell that far behind and paused.
    public private(set) var supermuxWatchedBytePauseCount = 0
    /// Each watched terminal's queued byte events, oldest first.
    private var supermuxWatchedTerminals: [String: SupermuxWatchedTerminal] = [:]
    /// Watched terminals with queued bytes, in the order the drain serves them.
    private var supermuxServeOrder: [String] = []
    /// Paused hidden terminals and the newest chunk each was refused since.
    private var supermuxPausedNewest: [String: SupermuxHeldChunk] = [:]
    /// The terminal this connection last typed into, and whether the last
    /// chunk served was its (it gets every other turn).
    private var supermuxInteractiveSurfaceID: String?
    private var supermuxServedInteractive = false
    // SUPERMUX:end terminal-stream-fair-queue
    // SUPERMUX:begin render-grid-watch
    /// The terminals whose render-grid frames this connection's phone shows;
    /// nil sends every terminal's (upstream).
    private var supermuxRenderGridSurfaceIDs: Set<String>?
    // SUPERMUX:end render-grid-watch
    // SUPERMUX:begin terminal-stream-byte-demand
    /// The watched terminals this connection has off screen
    /// (`background_surface_ids`), reported with the rest of its ask to
    /// ``SupermuxTerminalByteDemand``.
    private var supermuxBackgroundByteSurfaceIDs: Set<String> = []
    // SUPERMUX:end terminal-stream-byte-demand

    public init(
        maximumEventCount: Int = MobileHostConnectionEventQueue.defaultMaximumEventCount,
        maximumByteCount: Int = MobileHostConnectionEventQueue.defaultMaximumByteCount
    ) {
        self.maximumEventCount = maximumEventCount
        self.maximumByteCount = maximumByteCount
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return queuedEvents.count
    }

    public var byteCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return queuedByteCount
    }

    /// Replaces the subscribed-topic snapshot used for synchronous admission.
    /// The owning connection calls this on subscribe/unsubscribe/close.
    public func updateSubscribedTopics(_ topics: Set<String>) {
        lock.lock()
        subscribedTopics = topics
        // SUPERMUX:begin terminal-stream-byte-demand
        supermuxReportByteDemandLocked()
        // SUPERMUX:end terminal-stream-byte-demand
        lock.unlock()
    }

    public func isSubscribed(topic: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return subscribedTopics.contains(topic)
    }

    /// Synchronous admission with refresh-event shedding. Safe on any thread; never
    /// blocks on the network, the connection actor, or the runtime.
    public func enqueue(
        topic: String,
        coalesceKey: String?,
        isFullRenderGridFrame: Bool,
        stateSeq: UInt64? = nil,
        frame: Data
    ) -> MobileHostEventEnqueueResult {
        lock.lock()
        guard !isClosed, subscribedTopics.contains(topic) else {
            lock.unlock()
            return .rejected
        }
        // SUPERMUX:begin terminal-stream-watch
        if let watched = supermuxEnqueueWatchedBytesLocked(topic: topic, coalesceKey: coalesceKey, stateSeq: stateSeq, frame: frame) {
            lock.unlock()
            return watched
        }
        // SUPERMUX:end terminal-stream-watch
        // SUPERMUX:begin render-grid-watch (frames of terminals the phone does not show)
        if topic == MobileHostEventTopicPolicy().renderGridTopic, supermuxRefusesRenderGridLocked(coalesceKey: coalesceKey) {
            lock.unlock()
            return .rejected
        }
        // SUPERMUX:end render-grid-watch
        // A Mac grid is an absolute snapshot, so the new frame supersedes the
        // queued one and may use its room. The old entry leaves only once the
        // new frame is admitted at the back like any other grid frame, so a
        // replacement that overflows still leaves the last admitted grid.
        var replacedGridID: UUID?
        var replacedGrid: QueuedEvent?
        if topic == DeviceTerminalGridPublisher.eventTopic, let coalesceKey,
           let eventID = gridEventIDs[coalesceKey] {
            replacedGridID = eventID
            replacedGrid = queuedEvents[eventID]
        }
        let policy = MobileHostEventTopicPolicy()
        let isRenderGrid = topic == policy.renderGridTopic
        if isRenderGrid,
           let coalesceKey,
           !isFullRenderGridFrame,
           poisonedRenderGridSurfaceIDs.contains(coalesceKey) {
            // The surface's delta chain is already broken; only the pending
            // full frame may readmit it.
            lock.unlock()
            return .rejected
        }
        let (lane, laneGeneration) = laneLocked(topic: topic, coalesceKey: coalesceKey)
        var resyncSurfaceIDs = Set<String>()
        if isRenderGrid, let coalesceKey, !isFullRenderGridFrame {
            let route: RenderGridRoute = lane == .shared
                ? .shared
                : .surface(generation: laneGeneration)
            if let previousRoute = lastRenderGridRouteBySurfaceID[coalesceKey],
               previousRoute != route {
                // This delta builds on a frame that travelled another stream,
                // which may still be in flight behind it. Re-base the chain
                // with a full frame on the new route instead.
                poisonedRenderGridSurfaceIDs.insert(coalesceKey)
                lock.unlock()
                return MobileHostEventEnqueueResult(
                    admitted: false,
                    startDrain: false,
                    renderGridResyncSurfaceIDs: [coalesceKey],
                    depthAfterEnqueue: nil,
                    shedEventCount: 0,
                    shedByteCount: 0,
                    simulatorFrameShedPanelIDs: [],
                    overflowed: false
                )
            }
        }
        var shedSummary = MobileHostEventShedSummary()
        if !hasRoomLocked(for: frame, reclaiming: replacedGrid) {
            shedSummary = shedDroppableEventsLocked(
                for: frame,
                reclaiming: replacedGrid,
                resyncSurfaceIDs: &resyncSurfaceIDs
            )
            simulatorFrameReplayAfterDrainPanelIDs.formUnion(shedSummary.simulatorFramePanelIDs)
        }
        if isRenderGrid,
           let coalesceKey,
           !isFullRenderGridFrame,
           poisonedRenderGridSurfaceIDs.contains(coalesceKey) {
            // The shed pass just broke this surface's chain; this delta builds
            // on the shed frames, so it must not slip into the freed room.
            lock.unlock()
            return MobileHostEventEnqueueResult(
                admitted: false,
                startDrain: false,
                renderGridResyncSurfaceIDs: resyncSurfaceIDs,
                depthAfterEnqueue: nil,
                shedEventCount: shedSummary.eventCount,
                shedByteCount: shedSummary.byteCount,
                simulatorFrameShedPanelIDs: shedSummary.simulatorFramePanelIDs,
                overflowed: false
            )
        }
        if !hasRoomLocked(for: frame, reclaiming: replacedGrid),
           policy.isDroppable(topic: topic, coalesceKey: coalesceKey) {
            if isRenderGrid, let coalesceKey {
                if poisonedRenderGridSurfaceIDs.insert(coalesceKey).inserted {
                    resyncSurfaceIDs.insert(coalesceKey)
                } else if isFullRenderGridFrame {
                    // The replacement full frame itself could not be admitted;
                    // ask again once the drain makes room.
                    resyncAfterDrainSurfaceIDs.insert(coalesceKey)
                }
            }
            lock.unlock()
            return MobileHostEventEnqueueResult(
                admitted: false,
                startDrain: false,
                renderGridResyncSurfaceIDs: resyncSurfaceIDs,
                depthAfterEnqueue: nil,
                shedEventCount: shedSummary.eventCount,
                shedByteCount: shedSummary.byteCount,
                simulatorFrameShedPanelIDs: shedSummary.simulatorFramePanelIDs,
                overflowed: false
            )
        }
        if !hasRoomLocked(for: frame, reclaiming: replacedGrid), topic == DeviceTerminalGridPublisher.eventTopic {
            let result = recordOverflowLocked(shedSummary: shedSummary, resyncSurfaceIDs: resyncSurfaceIDs)
            lock.unlock()
            return result
        }
        if let replacedGridID { _ = removeQueuedEventLocked(replacedGridID) }
        let eventID = UUID()
        queuedEvents[eventID] = QueuedEvent(
            topic: topic,
            coalesceKey: coalesceKey,
            frame: frame,
            stateSeq: stateSeq,
            lane: lane,
            laneGeneration: laneGeneration
        )
        arrivalOrder.append(eventID)
        laneOrders[lane, default: MobileHostQueuedEventOrder()].append(eventID)
        if topic == DeviceTerminalGridPublisher.eventTopic, let coalesceKey {
            gridEventIDs[coalesceKey] = eventID
        }
        queuedByteCount += frame.count
        queuedCountByLane[lane, default: 0] += 1
        let depthAfterEnqueue = queuedEvents.count
        if isRenderGrid, let coalesceKey {
            lastRenderGridRouteBySurfaceID[coalesceKey] = lane == .shared
                ? .shared
                : .surface(generation: laneGeneration)
        }
        if isRenderGrid, isFullRenderGridFrame, let coalesceKey {
            poisonedRenderGridSurfaceIDs.remove(coalesceKey)
            resyncAfterDrainSurfaceIDs.remove(coalesceKey)
        }
        let startDrain = drainingLanes.insert(lane).inserted
        lock.unlock()
        return MobileHostEventEnqueueResult(
            admitted: true,
            startDrain: startDrain,
            drainLane: lane,
            renderGridResyncSurfaceIDs: resyncSurfaceIDs,
            depthAfterEnqueue: depthAfterEnqueue,
            shedEventCount: shedSummary.eventCount,
            shedByteCount: shedSummary.byteCount,
            simulatorFrameShedPanelIDs: shedSummary.simulatorFramePanelIDs,
            overflowed: false
        )
    }

    /// Removes the oldest event queued on `lane`. Events on other lanes keep
    /// their global order for shedding.
    public func dequeue(lane: MobileHostEventLane = .shared) -> QueuedEvent? {
        lock.lock()
        defer { lock.unlock() }
        while let eventID = laneOrders[lane]?.popFirst() {
            guard let event = removeQueuedEventLocked(eventID) else { continue }
            return event
        }
        // SUPERMUX:begin terminal-stream-fair-queue (watched terminals' bytes after every other shared event)
        if lane == .shared { return supermuxDequeueWatchedLocked() }
        // SUPERMUX:end terminal-stream-fair-queue
        return nil
    }

    /// Called by a lane's drain loop after `dequeue` returned nil. Returns
    /// true when events raced in and the loop must keep draining; otherwise
    /// the drain is marked finished so the next enqueue can claim a fresh one.
    public func finishDrain(lane: MobileHostEventLane = .shared) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        // A pending overflow keeps the shared drain alive until it consumes
        // the flag and closes the connection; otherwise no later drain would
        // observe it.
        let overflowPending = lane == .shared && overflowed
        if (queuedCountByLane[lane, default: 0] == 0 && !overflowPending) || isClosed {
            drainingLanes.remove(lane)
            return false
        }
        return true
    }

    /// Marks the lane's drain inactive after an abnormal exit (close, lane
    /// negotiation, failed delivery) so a later enqueue can claim a fresh one.
    public func abandonDrain(lane: MobileHostEventLane = .shared) {
        lock.lock()
        drainingLanes.remove(lane)
        lock.unlock()
    }

    /// Claims every lane with pending events (or the shared lane with a
    /// pending overflow) and no running drain. The caller must start one
    /// drain per returned lane.
    public func claimDrains() -> [MobileHostEventLane] {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return [] }
        var claimed: [MobileHostEventLane] = []
        for (lane, count) in queuedCountByLane where count > 0 {
            if drainingLanes.insert(lane).inserted {
                claimed.append(lane)
            }
        }
        if overflowed, drainingLanes.insert(.shared).inserted {
            claimed.append(.shared)
        }
        return claimed
    }

    // MARK: Surface lanes

    /// Routes future render-grid frames onto per-surface lanes, at most
    /// `limit` at once. Surfaces beyond the limit ride the shared lane.
    public func enableSurfaceLanes(limit: Int) {
        lock.lock()
        surfaceLaneLimit = max(0, limit)
        sharedLanePinnedSurfaceIDs.removeAll()
        surfaceLaneFailureCounts.removeAll()
        lock.unlock()
    }

    public var surfaceLanesEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return surfaceLaneLimit > 0
    }

    /// Returns every future event to the shared lane. Frames still queued for
    /// a surface lane are dropped (that lane is no longer drained) and their
    /// surfaces are poisoned; the caller must request a full resync for each
    /// returned surface.
    public func disableSurfaceLanes() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        guard surfaceLaneLimit > 0 else { return [] }
        surfaceLaneLimit = 0
        surfaceLaneLastUse.removeAll()
        var resync = Set<String>()
        let surfaceEventIDs = queuedEvents.compactMap { entry -> UUID? in
            guard case .surface(let surfaceID) = entry.value.lane else { return nil }
            resync.insert(surfaceID)
            return entry.key
        }
        for eventID in surfaceEventIDs {
            _ = removeQueuedEventLocked(eventID)
        }
        poisonedRenderGridSurfaceIDs.formUnion(resync)
        return resync
    }

    /// Records that a surface lane stream failed or stalled. Frames written
    /// to it may be lost, so the surface's queued frames are dropped, its
    /// chain is poisoned, and the next stream gets a new generation. Returns
    /// the surfaces that need a full-frame resync. A stale `generation`
    /// (already retired) changes nothing.
    public func retireSurfaceLane(surfaceID: String, generation: UInt64) -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed, surfaceLaneGenerations[surfaceID, default: 0] == generation else {
            return []
        }
        surfaceLaneGenerations[surfaceID] = generation &+ 1
        surfaceLaneLastUse.removeValue(forKey: surfaceID)
        let failures = surfaceLaneFailureCounts[surfaceID, default: 0] + 1
        surfaceLaneFailureCounts[surfaceID] = failures
        if failures >= Self.maximumSurfaceLaneFailureCount {
            sharedLanePinnedSurfaceIDs.insert(surfaceID)
        }
        var droppedSummary = MobileHostEventShedSummary()
        removeRenderGridEventsLocked(surfaceIDs: [surfaceID], summary: &droppedSummary)
        poisonedRenderGridSurfaceIDs.insert(surfaceID)
        return [surfaceID]
    }

    /// Clears a surface's consecutive-failure count after a delivered frame.
    public func noteSurfaceLaneDelivered(surfaceID: String) {
        lock.lock()
        if surfaceLaneFailureCounts[surfaceID] != nil {
            surfaceLaneFailureCounts.removeValue(forKey: surfaceID)
        }
        lock.unlock()
    }

    /// Current generation of a surface's lane stream.
    public func surfaceLaneGeneration(surfaceID: String) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return surfaceLaneGenerations[surfaceID, default: 0]
    }

    private func laneLocked(
        topic: String,
        coalesceKey: String?
    ) -> (MobileHostEventLane, UInt64) {
        guard surfaceLaneLimit > 0,
              topic == MobileHostEventTopicPolicy().renderGridTopic,
              let surfaceID = coalesceKey,
              !sharedLanePinnedSurfaceIDs.contains(surfaceID) else {
            return (.shared, 0)
        }
        surfaceLaneUseTick &+= 1
        if surfaceLaneLastUse[surfaceID] == nil {
            if surfaceLaneLastUse.count >= surfaceLaneLimit {
                // Reassign the least recently used idle lane; a lane with
                // queued or in-flight frames keeps its surface.
                let idle = surfaceLaneLastUse.filter { entry in
                    let lane = MobileHostEventLane.surface(entry.key)
                    return queuedCountByLane[lane, default: 0] == 0
                        && !drainingLanes.contains(lane)
                }
                guard let victim = idle.min(by: { $0.value < $1.value })?.key else {
                    return (.shared, 0)
                }
                surfaceLaneLastUse.removeValue(forKey: victim)
                // The victim's next frame opens a new stream.
                surfaceLaneGenerations[victim, default: 0] &+= 1
            }
        }
        surfaceLaneLastUse[surfaceID] = surfaceLaneUseTick
        return (.surface(surfaceID), surfaceLaneGenerations[surfaceID, default: 0])
    }

    /// Poisoned surfaces whose full-frame resync should be re-requested now
    /// that the drain has made progress.
    public func takeResyncAfterDrainRequests() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        guard !resyncAfterDrainSurfaceIDs.isEmpty else { return [] }
        let requests = resyncAfterDrainSurfaceIDs
        resyncAfterDrainSurfaceIDs.removeAll()
        return requests
    }

    /// Simulator panels whose latest absolute frame must be replayed now that
    /// this exact connection's queue has made write progress.
    public func takeSimulatorFrameReplayAfterDrainRequests() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        guard !simulatorFrameReplayAfterDrainPanelIDs.isEmpty else { return [] }
        let requests = simulatorFrameReplayAfterDrainPanelIDs
        simulatorFrameReplayAfterDrainPanelIDs.removeAll()
        return requests
    }

    /// Restores replay debt when subscription ownership changes while the
    /// connection actor is awaiting the producer callback.
    public func requeueSimulatorFrameReplayAfterDrainRequests(_ panelIDs: Set<String>) {
        guard !panelIDs.isEmpty else { return }
        lock.lock()
        if !isClosed {
            simulatorFrameReplayAfterDrainPanelIDs.formUnion(panelIDs)
        }
        lock.unlock()
    }

    /// Rejects all future admissions and releases every queued payload.
    public func close() {
        lock.lock()
        isClosed = true
        queuedEvents.removeAll(keepingCapacity: false)
        arrivalOrder = MobileHostQueuedEventOrder()
        laneOrders.removeAll(keepingCapacity: false)
        gridEventIDs.removeAll(keepingCapacity: false)
        overflowed = false
        queuedByteCount = 0
        poisonedRenderGridSurfaceIDs.removeAll()
        resyncAfterDrainSurfaceIDs.removeAll()
        simulatorFrameReplayAfterDrainPanelIDs.removeAll()
        // SUPERMUX:begin terminal-stream-watch
        supermuxWatchedByteSurfaceIDs = nil
        supermuxWatchedEvents.removeAll()
        supermuxWatchedBytesBySurfaceID.removeAll()
        supermuxWatchedQueuedByteCount = 0
        // SUPERMUX:end terminal-stream-watch
        // SUPERMUX:begin terminal-stream-fair-queue
        supermuxWatchedTerminals.removeAll()
        supermuxServeOrder.removeAll()
        supermuxPausedNewest.removeAll()
        supermuxInteractiveSurfaceID = nil
        // SUPERMUX:end terminal-stream-fair-queue
        // SUPERMUX:begin render-grid-watch
        supermuxRenderGridSurfaceIDs = nil
        // SUPERMUX:end render-grid-watch
        // SUPERMUX:begin terminal-stream-byte-demand
        supermuxBackgroundByteSurfaceIDs.removeAll()
        supermuxReportByteDemandLocked()
        // SUPERMUX:end terminal-stream-byte-demand
        subscribedTopics.removeAll()
        queuedCountByLane.removeAll()
        surfaceLaneLimit = 0
        surfaceLaneLastUse.removeAll()
        lastRenderGridRouteBySurfaceID.removeAll()
        lock.unlock()
    }

    /// Consumed by the connection's existing drain lifecycle so overflow closes
    /// without spawning an untracked task from synchronous fan-out.
    public func consumeOverflow() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard overflowed else { return false }
        overflowed = false
        return true
    }

    /// Every overflow result goes through here: the pending flag is the only
    /// signal the drain uses to close the connection, and the result claims
    /// the shared drain (where Mac grid snapshots travel) when none is
    /// running so fan-out callers start one.
    private func recordOverflowLocked(
        shedSummary: MobileHostEventShedSummary,
        resyncSurfaceIDs: Set<String>
    ) -> MobileHostEventEnqueueResult {
        overflowed = true
        let startDrain = drainingLanes.insert(.shared).inserted
        return MobileHostEventEnqueueResult(
            admitted: false, startDrain: startDrain, drainLane: .shared,
            renderGridResyncSurfaceIDs: resyncSurfaceIDs,
            depthAfterEnqueue: nil, shedEventCount: shedSummary.eventCount,
            shedByteCount: shedSummary.byteCount,
            simulatorFrameShedPanelIDs: shedSummary.simulatorFramePanelIDs,
            overflowed: true
        )
    }

    /// Removes one queued event and every index that points at it. The
    /// arrival orders keep its ID until they skip or compact it.
    private func removeQueuedEventLocked(_ eventID: UUID) -> QueuedEvent? {
        guard let event = queuedEvents.removeValue(forKey: eventID) else { return nil }
        queuedByteCount -= event.frame.count
        // SUPERMUX:begin terminal-stream-watch
        supermuxForgetWatchedEventLocked(eventID)
        // SUPERMUX:end terminal-stream-watch
        if event.topic == DeviceTerminalGridPublisher.eventTopic, let key = event.coalesceKey,
           gridEventIDs[key] == eventID {
            gridEventIDs.removeValue(forKey: key)
        }
        let remaining = queuedCountByLane[event.lane, default: 0] - 1
        if remaining > 0 {
            queuedCountByLane[event.lane] = remaining
            laneOrders[event.lane]?.compact(liveCount: remaining) { queuedEvents[$0] != nil }
        } else {
            queuedCountByLane.removeValue(forKey: event.lane)
            laneOrders.removeValue(forKey: event.lane)
        }
        arrivalOrder.compact(liveCount: queuedEvents.count) { queuedEvents[$0] != nil }
        return event
    }

    /// Drops every queued render-grid frame for `surfaceIDs`, on any lane.
    private func removeRenderGridEventsLocked(
        surfaceIDs: Set<String>,
        summary: inout MobileHostEventShedSummary
    ) {
        let renderGridTopic = MobileHostEventTopicPolicy().renderGridTopic
        let eventIDs = queuedEvents.compactMap { entry -> UUID? in
            guard entry.value.topic == renderGridTopic,
                  let surfaceID = entry.value.coalesceKey,
                  surfaceIDs.contains(surfaceID) else { return nil }
            return entry.key
        }
        for eventID in eventIDs {
            if let event = removeQueuedEventLocked(eventID) {
                summary.record(event)
            }
        }
    }

    /// `reclaimed` is a queued event the new frame replaces on admission, so
    /// its room counts as free.
    private func hasRoomLocked(for frame: Data, reclaiming reclaimed: QueuedEvent? = nil) -> Bool {
        // SUPERMUX:begin terminal-stream-watch (watched bytes have their own budget; upstream's lets)
        let reclaimedCount = (reclaimed == nil ? 0 : 1) + supermuxWatchedEvents.count
        let reclaimedBytes = (reclaimed?.frame.count ?? 0) + supermuxWatchedQueuedByteCount
        // SUPERMUX:end terminal-stream-watch
        return queuedEvents.count - reclaimedCount < maximumEventCount
            && queuedByteCount - reclaimedBytes + frame.count <= maximumByteCount
    }

    private func shedDroppableEventsLocked(
        for frame: Data,
        reclaiming reclaimed: QueuedEvent? = nil,
        resyncSurfaceIDs: inout Set<String>
    ) -> MobileHostEventShedSummary {
        let policy = MobileHostEventTopicPolicy()
        var summary = MobileHostEventShedSummary()
        var sheddable: [UUID] = []
        // The replaced event is not droppable, so the walk never counts it twice.
        var releasedCount = reclaimed == nil ? 0 : 1
        var releasedBytes = reclaimed?.frame.count ?? 0
        // SUPERMUX:begin terminal-stream-watch (watched bytes sit outside the shared budget)
        releasedCount += supermuxWatchedEvents.count
        releasedBytes += supermuxWatchedQueuedByteCount
        // SUPERMUX:end terminal-stream-watch
        // Pick the oldest droppable events first, then remove them, so the
        // walk never sees the order compact under it.
        for eventID in arrivalOrder.ids[arrivalOrder.head...] {
            if queuedEvents.count - releasedCount < maximumEventCount,
               queuedByteCount - releasedBytes + frame.count <= maximumByteCount {
                break
            }
            // SUPERMUX:begin terminal-stream-watch (a watched terminal's bytes are never shed)
            guard let event = queuedEvents[eventID], supermuxWatchedEvents[eventID] == nil,
                  policy.isDroppable(topic: event.topic, coalesceKey: event.coalesceKey) else {
                continue
            }
            // SUPERMUX:end terminal-stream-watch
            sheddable.append(eventID)
            releasedCount += 1
            releasedBytes += event.frame.count
        }
        for eventID in sheddable {
            guard let event = removeQueuedEventLocked(eventID) else { continue }
            summary.record(event)
            if event.topic == policy.renderGridTopic,
               let surfaceID = event.coalesceKey,
               poisonedRenderGridSurfaceIDs.insert(surfaceID).inserted {
                resyncSurfaceIDs.insert(surfaceID)
            }
        }
        // A shed frame breaks its surface's delta chain, so every remaining
        // queued render-grid frame for that surface — each builds on the shed
        // one — must go with it. The pending full-frame resync re-bases the
        // chain for the whole connection.
        guard !resyncSurfaceIDs.isEmpty else { return summary }
        removeRenderGridEventsLocked(surfaceIDs: resyncSurfaceIDs, summary: &summary)
        return summary
    }
    // SUPERMUX:begin terminal-stream-watch

    /// The most one watched terminal may have queued. Past it the terminal's
    /// queued bytes are dropped and only its newest chunk stays, so the viewer
    /// sees the gap at once and resumes it from its byte position (or, when
    /// the host's byte tail no longer reaches back that far, re-anchors on a
    /// replay). Superset disconnects a client 8 MB behind the same way.
    public static let supermuxWatchedSurfaceByteBudget = 8 * 1024 * 1024

    /// Limits this connection's `terminal.bytes` to `surfaceIDs` (nil: every
    /// terminal again, upstream's delivery); `background` names the watched
    /// ones it has off screen (``SupermuxTerminalByteDemand``). Bytes already
    /// queued stay. A paused terminal shown again gets its newest chunk back
    /// in the queue (the caller claims its drain, ``claimDrains()``).
    public func supermuxWatchTerminalBytes(surfaceIDs: Set<String>?, background: Set<String> = []) {
        lock.lock()
        let watched = surfaceIDs.map { Set($0.map { $0.uppercased() }) }
        supermuxWatchedByteSurfaceIDs = watched
        supermuxBackgroundByteSurfaceIDs = Set(background.map { $0.uppercased() }).intersection(watched ?? [])
        supermuxResumePausedLocked()
        supermuxReportByteDemandLocked()
        lock.unlock()
    }

    /// The terminals this connection watches, or nil when it gets them all.
    public var supermuxWatchedTerminalBytes: Set<String>? {
        lock.lock()
        defer { lock.unlock() }
        return supermuxWatchedByteSurfaceIDs
    }

    /// Admits a `terminal.bytes` event of a connection that names its
    /// terminals: refused for the others, queued in order per watched
    /// terminal on the shared lane, outside the shared budget. Nil for every
    /// other event (upstream's admission runs).
    private func supermuxEnqueueWatchedBytesLocked(
        topic: String,
        coalesceKey: String?,
        stateSeq: UInt64?,
        frame: Data
    ) -> MobileHostEventEnqueueResult? {
        guard topic == "terminal.bytes", let watched = supermuxWatchedByteSurfaceIDs else { return nil }
        guard let surfaceID = coalesceKey?.uppercased(), watched.contains(surfaceID) else { return .rejected }
        let chunk = SupermuxHeldChunk(coalesceKey: coalesceKey, stateSeq: stateSeq, frame: frame)
        if supermuxPausesLocked(surfaceID: surfaceID, chunk) { return .rejected }
        if supermuxWatchedBytesBySurfaceID[surfaceID, default: 0] + frame.count > Self.supermuxWatchedSurfaceByteBudget {
            supermuxDropWatchedBacklogLocked(surfaceID: surfaceID)
            supermuxWatchedByteResyncCount += 1
        }
        supermuxQueueWatchedLocked(surfaceID: surfaceID, chunk)
        let startDrain = drainingLanes.insert(.shared).inserted
        return MobileHostEventEnqueueResult(
            admitted: true, startDrain: startDrain, drainLane: .shared,
            renderGridResyncSurfaceIDs: [], depthAfterEnqueue: queuedEvents.count,
            shedEventCount: 0, shedByteCount: 0, simulatorFrameShedPanelIDs: [], overflowed: false
        )
    }

    private func supermuxForgetWatchedEventLocked(_ eventID: UUID) {
        guard let watched = supermuxWatchedEvents.removeValue(forKey: eventID) else { return }
        supermuxWatchedQueuedByteCount -= watched.byteCount
        let remaining = supermuxWatchedBytesBySurfaceID[watched.surfaceID, default: 0] - watched.byteCount
        supermuxWatchedBytesBySurfaceID[watched.surfaceID] = remaining > 0 ? remaining : nil
        supermuxForgetQueuedLocked(surfaceID: watched.surfaceID)
    }
    // SUPERMUX:end terminal-stream-watch
    // SUPERMUX:begin terminal-stream-byte-demand

    /// Reports this connection's ask for terminal bytes to
    /// ``SupermuxTerminalByteDemand``, while it is open and subscribed to
    /// `terminal.bytes` (the only time its queue admits them).
    private func supermuxReportByteDemandLocked() {
        let connection = ObjectIdentifier(self)
        guard !isClosed, subscribedTopics.contains("terminal.bytes") else {
            SupermuxTerminalByteDemand.shared.remove(connection: connection)
            return
        }
        SupermuxTerminalByteDemand.shared.update(
            connection: connection,
            watched: supermuxWatchedByteSurfaceIDs,
            background: supermuxBackgroundByteSurfaceIDs
        )
    }
    // SUPERMUX:end terminal-stream-byte-demand
    // SUPERMUX:begin terminal-stream-fair-queue

    // A watching connection's terminal bytes, fair and shown terminals first.
    //
    // Each watched terminal queues its own bytes in order. The shared lane's
    // drain sends every other event first (status, grids, layouts: small, and
    // never overtaken by later bytes), then one chunk per terminal in turn,
    // shown terminals before hidden ones (`background_surface_ids`). So a
    // keystroke's echo waits for at most one chunk of each other shown
    // terminal plus the frame already on the wire, never for a backlog.
    // (Until 2026-10-05 one queue in arrival order held every terminal: on a
    // 300 KB/s relay the echo waited 11 s behind a hidden terminal's output.)
    //
    // A hidden terminal whose oldest queued chunk has waited
    // ``supermuxBackgroundByteMaximumAge`` pauses: its backlog goes and its
    // bytes stop, keeping only the newest chunk refused since. Shown again
    // (the connection's next watch), that chunk is queued first: its position
    // is past what the viewer has, so the viewer sees the gap and resumes or
    // replays the terminal, as for any gap; when the viewer already holds
    // that position (a replay since), it ignores the chunk. A hidden mirror
    // stays at its last screen meanwhile, and the link carries what is shown.

    /// One watched terminal's queued byte events.
    private struct SupermuxWatchedTerminal {
        var order = MobileHostQueuedEventOrder()
        var count = 0
    }

    /// A `terminal.bytes` event as `enqueue` received it.
    private struct SupermuxHeldChunk {
        let coalesceKey: String?
        let stateSeq: UInt64?
        let frame: Data
    }

    private func supermuxQueueWatchedLocked(surfaceID: String, _ chunk: SupermuxHeldChunk) {
        let eventID = UUID()
        queuedEvents[eventID] = QueuedEvent(
            topic: "terminal.bytes", coalesceKey: chunk.coalesceKey, frame: chunk.frame, stateSeq: chunk.stateSeq
        )
        arrivalOrder.append(eventID)
        if supermuxWatchedTerminals[surfaceID] == nil { supermuxServeOrder.append(surfaceID) }
        supermuxWatchedTerminals[surfaceID, default: SupermuxWatchedTerminal()].order.append(eventID)
        supermuxWatchedTerminals[surfaceID]?.count += 1
        queuedByteCount += chunk.frame.count
        queuedCountByLane[.shared, default: 0] += 1
        supermuxWatchedEvents[eventID] = (surfaceID, chunk.frame.count, .now)
        supermuxWatchedBytesBySurfaceID[surfaceID, default: 0] += chunk.frame.count
        supermuxWatchedQueuedByteCount += chunk.frame.count
    }

    /// A queued event of `surfaceID` left the queue.
    private func supermuxForgetQueuedLocked(surfaceID: String) {
        guard var terminal = supermuxWatchedTerminals[surfaceID] else { return }
        terminal.count -= 1
        guard terminal.count > 0 else {
            supermuxWatchedTerminals[surfaceID] = nil
            supermuxServeOrder.removeAll { $0 == surfaceID }
            return
        }
        terminal.order.compact(liveCount: terminal.count) { queuedEvents[$0] != nil }
        supermuxWatchedTerminals[surfaceID] = terminal
    }

    /// The next watched chunk: every other turn the terminal being typed in,
    /// else the oldest of the first shown terminal in turn, else of the first
    /// hidden one; that terminal goes to the back.
    private func supermuxDequeueWatchedLocked() -> QueuedEvent? {
        let background = supermuxBackgroundByteSurfaceIDs
        let typedIn = supermuxInteractiveSurfaceID.flatMap { surfaceID in
            !supermuxServedInteractive && supermuxWatchedTerminals[surfaceID] != nil
                && !background.contains(surfaceID) ? surfaceID : nil
        }
        guard let surfaceID = typedIn
            ?? supermuxServeOrder.first(where: { !background.contains($0) && $0 != supermuxInteractiveSurfaceID })
            ?? supermuxServeOrder.first(where: { !background.contains($0) })
            ?? supermuxServeOrder.first else { return nil }
        supermuxServedInteractive = surfaceID == supermuxInteractiveSurfaceID
        while let eventID = supermuxWatchedTerminals[surfaceID]?.order.popFirst() {
            guard let event = removeQueuedEventLocked(eventID) else { continue }
            if let index = supermuxServeOrder.firstIndex(of: surfaceID) {
                supermuxServeOrder.remove(at: index)
                supermuxServeOrder.append(surfaceID)
            }
            return event
        }
        return nil
    }

    /// The terminal this connection last typed into: its echo goes out
    /// every other turn among shown terminals, so it waits for at most one
    /// other terminal's chunk, and a flood in it still leaves half the turns.
    public func supermuxNoteInteractiveSurface(_ surfaceID: String) {
        lock.lock()
        supermuxInteractiveSurfaceID = surfaceID.uppercased()
        lock.unlock()
    }

    private func supermuxDropWatchedBacklogLocked(surfaceID: String) {
        guard let terminal = supermuxWatchedTerminals[surfaceID] else { return }
        for eventID in terminal.order.ids[terminal.order.head...] { _ = removeQueuedEventLocked(eventID) }
    }

    /// Whether `chunk` is refused because its hidden terminal is paused, or
    /// pauses now (its oldest queued chunk waited too long).
    private func supermuxPausesLocked(surfaceID: String, _ chunk: SupermuxHeldChunk) -> Bool {
        guard supermuxBackgroundByteSurfaceIDs.contains(surfaceID) else { return false }
        if supermuxPausedNewest[surfaceID] != nil {
            supermuxPausedNewest[surfaceID] = chunk
            return true
        }
        guard let terminal = supermuxWatchedTerminals[surfaceID],
              let oldest = terminal.order.ids[terminal.order.head...].lazy
                  .compactMap({ self.supermuxWatchedEvents[$0]?.queuedAt }).first,
              ContinuousClock.now - oldest >= supermuxBackgroundByteMaximumAge else { return false }
        supermuxDropWatchedBacklogLocked(surfaceID: surfaceID)
        supermuxPausedNewest[surfaceID] = chunk
        supermuxWatchedBytePauseCount += 1
        return true
    }

    /// After a watch: a paused terminal shown again queues its newest chunk;
    /// one no longer watched is forgotten.
    private func supermuxResumePausedLocked() {
        for (surfaceID, chunk) in supermuxPausedNewest {
            if supermuxWatchedByteSurfaceIDs?.contains(surfaceID) != true {
                supermuxPausedNewest[surfaceID] = nil
            } else if !supermuxBackgroundByteSurfaceIDs.contains(surfaceID) {
                supermuxPausedNewest[surfaceID] = nil
                supermuxQueueWatchedLocked(surfaceID: surfaceID, chunk)
            }
        }
    }
    // SUPERMUX:end terminal-stream-fair-queue
    // SUPERMUX:begin render-grid-watch

    /// Limits this connection's `terminal.render_grid` to `surfaceIDs` (nil:
    /// every terminal, upstream's delivery), the terminals its phone shows
    /// (``SupermuxRenderGridWatchState``).
    public func supermuxShowRenderGrid(surfaceIDs: Set<String>?) {
        lock.lock()
        supermuxRenderGridSurfaceIDs = surfaceIDs.map { Set($0.map { $0.uppercased() }) }
        lock.unlock()
    }

    /// Whether a render-grid frame of `coalesceKey` is refused because the
    /// phone does not show that terminal. Its chain is broken from here, so
    /// only a full frame readmits it once shown (the caller asks for one);
    /// no resync is asked now, which would only make frames to refuse.
    private func supermuxRefusesRenderGridLocked(coalesceKey: String?) -> Bool {
        guard let shown = supermuxRenderGridSurfaceIDs, let coalesceKey,
              !shown.contains(coalesceKey.uppercased()) else { return false }
        poisonedRenderGridSurfaceIDs.insert(coalesceKey)
        return true
    }
    // SUPERMUX:end render-grid-watch
}
