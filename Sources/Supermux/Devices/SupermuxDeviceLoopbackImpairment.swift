#if DEBUG
import Foundation

/// DEBUG impairment of the loopback device's link, so E2E can run mirrors over
/// a link like a far relay: a capacity cap, a round trip and scheduled drops
/// (`supermux.devices.link_impairment`, ``SupermuxDeviceLinkImpairmentSocketCommands``).
///
/// Every ``SupermuxDeviceLoopbackPipe`` that carries a device-link direction
/// applies it, both directions alike (each direction is its own link, as on a
/// full-duplex path):
/// - **Capacity**: bytes leave at most ``Settings/bytesPerSecond``, in order,
///   in chunks of ``chunkBytes``, so a reader sees a large frame arrive
///   progressively, as it would over a network.
/// - **Send buffer**: past ``Settings/queueBytes`` not yet sent, a write waits
///   until the link catches up, as a socket write does. The writer above (the
///   host's reply writer, the viewer's request writer) then backs up too,
///   instead of handing the link everything at once. Keep it near the link's
///   bandwidth-delay product: a deep buffer only adds a first-in-first-out
///   delay no application change could avoid.
/// - **Delay**: the one-way delays of ``SupermuxDeviceLoopbackLatency``.
/// - **Drops**: nothing crosses during a drop; bytes on the wire when it
///   starts arrive once it ends (retransmitted). With ``Settings/dropCuts``
///   a drop also closes every live loopback connection when it starts, as a
///   lost path does, so the link redials; the new dial's bytes wait out the
///   rest of the drop like any others. Drops come every ``Settings/dropEvery``
///   for ``Settings/dropFor`` (the first one `dropEvery` after the settings
///   were made), or once now (``dropNow(for:)``).
///
/// Settings are read under a lock by the pipes (their own actors) and set from
/// the main actor by the socket driver.
enum SupermuxDeviceLoopbackImpairment {
    struct Settings: Equatable, Sendable {
        /// 0: no cap.
        var bytesPerSecond = 0
        var queueBytes = SupermuxDeviceLoopbackImpairment.defaultQueueBytes
        /// 0: no scheduled drops.
        var dropEvery: Duration = .zero
        var dropFor: Duration = .zero
        var dropCuts = true
    }

    /// What one pipe applies to its next bytes.
    struct Shaping: Sendable {
        let delay: Duration
        let bytesPerSecond: Int
        let queueBytes: Int
        /// Whether bytes must go through the link instead of straight to the reader.
        let impairs: Bool
    }

    /// Counters for one direction, since the last reset.
    struct DirectionStats: Sendable {
        var deliveredBytes = 0
        var queuedBytes = 0
        var peakQueuedBytes = 0
        var writesWaited = 0
    }

    /// About the bandwidth-delay product of a 300 KB/s, 200 ms link.
    static let defaultQueueBytes = 64 * 1024
    static let chunkBytes = 16 * 1024

    private final class WeakTransport {
        weak var transport: SupermuxDeviceLoopbackTransport?
        init(_ transport: SupermuxDeviceLoopbackTransport) { self.transport = transport }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var settings = Settings()
    /// When the current drop schedule started.
    nonisolated(unsafe) private static var scheduleStart = ContinuousClock.now
    nonisolated(unsafe) private static var oneShotDrop: Range<ContinuousClock.Instant>?
    nonisolated(unsafe) private static var toHost = DirectionStats()
    nonisolated(unsafe) private static var toViewer = DirectionStats()
    nonisolated(unsafe) private static var dropsStarted = 0
    nonisolated(unsafe) private static var connectionsCut = 0
    nonisolated(unsafe) private static var transports: [WeakTransport] = []
    @MainActor private static var dropTask: Task<Void, Never>?

    // MARK: - Pipes

    static func shaping(_ direction: SupermuxDeviceLoopbackLatency.Direction, at now: ContinuousClock.Instant = .now) -> Shaping {
        let delay = SupermuxDeviceLoopbackLatency.delay(direction)
        return lock.withLock {
            Shaping(
                delay: delay,
                bytesPerSecond: settings.bytesPerSecond,
                queueBytes: settings.queueBytes,
                impairs: delay > .zero || settings.bytesPerSecond > 0 || dropEndLocked(at: now) != nil
            )
        }
    }

    /// When the drop covering `instant` ends; nil when no drop covers it.
    static func dropEnd(at instant: ContinuousClock.Instant) -> ContinuousClock.Instant? {
        lock.withLock { dropEndLocked(at: instant) }
    }

    private static func dropEndLocked(at instant: ContinuousClock.Instant) -> ContinuousClock.Instant? {
        if let oneShotDrop, oneShotDrop.contains(instant) { return oneShotDrop.upperBound }
        guard settings.dropEvery > .zero, settings.dropFor > .zero, instant >= scheduleStart else { return nil }
        let period = Int((instant - scheduleStart) / settings.dropEvery)
        guard period >= 1 else { return nil }
        let start = scheduleStart + settings.dropEvery * period
        let end = start + settings.dropFor
        return instant < end ? end : nil
    }

    static func noteDelivered(_ direction: SupermuxDeviceLoopbackLatency.Direction, bytes: Int) {
        update(direction) { $0.deliveredBytes += bytes }
    }

    static func noteQueued(_ direction: SupermuxDeviceLoopbackLatency.Direction, delta: Int) {
        update(direction) {
            $0.queuedBytes = max(0, $0.queuedBytes + delta)
            $0.peakQueuedBytes = max($0.peakQueuedBytes, $0.queuedBytes)
        }
    }

    static func noteWriteWaited(_ direction: SupermuxDeviceLoopbackLatency.Direction) {
        update(direction) { $0.writesWaited += 1 }
    }

    private static func update(_ direction: SupermuxDeviceLoopbackLatency.Direction, _ change: (inout DirectionStats) -> Void) {
        lock.withLock {
            switch direction {
            case .toHost: change(&toHost)
            case .toViewer: change(&toViewer)
            }
        }
    }

    /// A device-link connection a drop may cut (its client end; closing it
    /// ends both directions for both ends).
    static func register(_ transport: SupermuxDeviceLoopbackTransport) {
        lock.withLock {
            transports.removeAll { $0.transport == nil }
            transports.append(WeakTransport(transport))
        }
    }

    // MARK: - Driver

    static var current: Settings { lock.withLock { settings } }

    /// Applies `next`; a changed drop schedule starts over from now.
    @MainActor
    static func configure(_ next: Settings) {
        let scheduleChanged = lock.withLock { () -> Bool in
            let changed = next.dropEvery != settings.dropEvery || next.dropFor != settings.dropFor
                || next.dropCuts != settings.dropCuts
            settings = next
            if changed { scheduleStart = .now }
            return changed
        }
        if scheduleChanged { restartDropSchedule() }
    }

    /// One drop of `duration` starting now.
    @MainActor
    static func dropNow(for duration: Duration) {
        let cuts = lock.withLock { () -> Bool in
            let now = ContinuousClock.now
            oneShotDrop = now..<(now + duration)
            return settings.dropCuts
        }
        dropStarted(cutting: cuts)
    }

    /// Everything off, counters zeroed.
    @MainActor
    static func reset() {
        lock.withLock { oneShotDrop = nil }
        configure(Settings())
        resetStats()
        SupermuxDeviceLoopbackLatency.toHost = .zero
        SupermuxDeviceLoopbackLatency.toViewer = .zero
    }

    static func resetStats() {
        lock.withLock {
            let queuedToHost = toHost.queuedBytes
            let queuedToViewer = toViewer.queuedBytes
            toHost = DirectionStats(queuedBytes: queuedToHost, peakQueuedBytes: queuedToHost)
            toViewer = DirectionStats(queuedBytes: queuedToViewer, peakQueuedBytes: queuedToViewer)
            dropsStarted = 0
            connectionsCut = 0
        }
    }

    struct Status {
        let settings: Settings
        let toHost: DirectionStats
        let toViewer: DirectionStats
        let dropEndsIn: Duration?
        let dropsStarted: Int
        let connectionsCut: Int
        let liveConnections: Int
    }

    static func status() -> Status {
        lock.withLock {
            let now = ContinuousClock.now
            return Status(
                settings: settings,
                toHost: toHost,
                toViewer: toViewer,
                dropEndsIn: dropEndLocked(at: now).map { $0 - now },
                dropsStarted: dropsStarted,
                connectionsCut: connectionsCut,
                liveConnections: transports.filter { $0.transport != nil }.count
            )
        }
    }

    @MainActor
    private static func restartDropSchedule() {
        dropTask?.cancel()
        dropTask = nil
        let (schedule, start) = lock.withLock { (settings, scheduleStart) }
        guard schedule.dropEvery > .zero, schedule.dropFor > .zero else { return }
        dropTask = Task { @MainActor in
            var period = 1
            while !Task.isCancelled {
                guard (try? await Task.sleep(until: start + schedule.dropEvery * period, clock: .continuous)) != nil,
                      !Task.isCancelled else { return }
                dropStarted(cutting: schedule.dropCuts)
                period += 1
            }
        }
    }

    @MainActor
    private static func dropStarted(cutting: Bool) {
        let live = lock.withLock { () -> [SupermuxDeviceLoopbackTransport] in
            dropsStarted += 1
            guard cutting else { return [] }
            let live = transports.compactMap(\.transport)
            transports.removeAll()
            connectionsCut += live.count
            return live
        }
        cmuxDebugLog("supermux.loopback link drop started cut=\(live.count)")
        for transport in live {
            Task { await transport.close() }
        }
    }
}
#endif
