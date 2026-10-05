import CMUXMobileCore
import CmuxMobileRPC
import Foundation

/// Owns independent terminal lanes keyed by peer and mounted surface.
actor MobileTerminalLaneCoordinator {
    enum LaneMode: Equatable, Sendable {
        case output
        case inputOnly
    }

    enum FrameDisposition: Sendable {
        case accepted(outputReady: Bool)
        case suspendUntilAuthoritativeOutput
        case stop
    }

    enum InputResult: Equatable, Sendable {
        case unavailable
        case sent
        case failed
    }

    private enum CoordinatorError: Error {
        case missingReplayEnvelope
        case unexpectedReplayEnvelope
        case invalidEnvelope
        case replayCursorMismatch
    }

    struct Configuration: Sendable {
        let request: CmxByteTransportRequest
        let surfaceID: String
        let mode: LaneMode
        let cursor: @Sendable () async -> UInt64?
        let consume: @Sendable (MobileTerminalLaneOutputFrame) async -> FrameDisposition
        let readinessChanged: @Sendable (Bool) async -> Void
        /// The host's answers to identified input sent on this lane.
        let acknowledged: @Sendable (MobileTerminalInputAcknowledgement) async -> Void

        init(
            request: CmxByteTransportRequest,
            surfaceID: String,
            mode: LaneMode = .output,
            cursor: @escaping @Sendable () async -> UInt64?,
            consume: @escaping @Sendable (MobileTerminalLaneOutputFrame) async -> FrameDisposition,
            readinessChanged: @escaping @Sendable (Bool) async -> Void,
            acknowledged: @escaping @Sendable (MobileTerminalInputAcknowledgement) async -> Void = { _ in }
        ) {
            self.request = request
            self.surfaceID = surfaceID
            self.mode = mode
            self.cursor = cursor
            self.consume = consume
            self.readinessChanged = readinessChanged
            self.acknowledged = acknowledged
        }
    }

    private struct LaneKey: Hashable, Sendable {
        let peerIdentity: String
        let surfaceID: String

        init?(configuration: Configuration) {
            switch configuration.request.route.endpoint {
            case .peer(let identity, _):
                peerIdentity = identity.endpointID
            case .hostPort, .url:
                // LaneKey routes terminal input. Without a peer identity, two
                // peers sharing one route id would collapse into one lane and
                // cross-route input, so fail closed instead of defaulting.
                guard let expectedPeerDeviceID =
                        configuration.request.expectedPeerDeviceID,
                      !expectedPeerDeviceID.isEmpty else {
                    return nil
                }
                peerIdentity = [
                    expectedPeerDeviceID,
                    configuration.request.route.id,
                ].joined(separator: "|")
            }
            surfaceID = configuration.surfaceID
        }
    }

    private enum Phase {
        case opening
        case active
        case suspended
        case failed
    }

    private struct Entry {
        let id: UUID
        var configuration: Configuration
        var phase: Phase
        var lane: (any MobileTerminalLaneConnection)?
        var task: Task<Void, Never>?
        var outputReady: Bool
        // SUPERMUX:begin terminal-lane-retry
        /// The run is sleeping out a retry delay, so the next `ensure` (a
        /// reconnect, a route change, a remount) starts it again at once.
        var waitingToRetry = false
        // SUPERMUX:end terminal-lane-retry
    }

    // SUPERMUX:begin terminal-lane-retry (upstream: `private static let maximumOpenAttempts = 3`; a lane is now retried with backoff while its terminal stays mounted, see SupermuxTerminalLaneRetry.swift)
    private let retryDelay: @Sendable (Int) -> Duration
    private let retrySleep: @Sendable (Duration) async throws -> Void
    private let retryObserver: (@Sendable (SupermuxTerminalLaneRetryEvent) -> Void)?
    // SUPERMUX:end terminal-lane-retry

    private let provider: MobileTerminalLaneProvider?
    private let inputOnlyProvider: MobileTerminalLaneProvider?
    private var entriesByKey: [LaneKey: Entry] = [:]
    private var focusedKeyBySurfaceID: [String: LaneKey] = [:]

    init(
        provider: MobileTerminalLaneProvider?,
        inputOnlyProvider: MobileTerminalLaneProvider? = nil,
        // SUPERMUX:begin terminal-lane-retry
        retryDelay: @escaping @Sendable (Int) -> Duration = {
            SupermuxTerminalLaneRetryDelay().delay(forAttempt: $0)
        },
        retrySleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        },
        retryObserver: (@Sendable (SupermuxTerminalLaneRetryEvent) -> Void)? = nil
        // SUPERMUX:end terminal-lane-retry
    ) {
        self.provider = provider
        self.inputOnlyProvider = inputOnlyProvider
        // SUPERMUX:begin terminal-lane-retry
        self.retryDelay = retryDelay
        self.retrySleep = retrySleep
        self.retryObserver = retryObserver
        // SUPERMUX:end terminal-lane-retry
    }

    func ensure(_ configuration: Configuration) async {
        guard let key = LaneKey(configuration: configuration) else { return }
        focusedKeyBySurfaceID[configuration.surfaceID] = key
        if var entry = entriesByKey[key] {
            entry.configuration = configuration
            entriesByKey[key] = entry
            if entry.outputReady {
                await configuration.readinessChanged(true)
            } else if entry.phase == .failed {
                entry.phase = .opening
                entriesByKey[key] = entry
                launch(key: key, id: entry.id)
            // SUPERMUX:begin terminal-lane-retry
            } else if entry.waitingToRetry {
                retryNow(key: key, entry: entry)
            // SUPERMUX:end terminal-lane-retry
            }
            return
        }
        let id = UUID()
        entriesByKey[key] = Entry(
            id: id,
            configuration: configuration,
            phase: .opening,
            lane: nil,
            task: nil,
            outputReady: false
        )
        launch(key: key, id: id)
    }

    func resume(surfaceID: String) {
        guard let key = focusedKeyBySurfaceID[surfaceID],
              var entry = entriesByKey[key],
              entry.phase == .suspended else {
            return
        }
        entry.phase = .opening
        entriesByKey[key] = entry
        launch(key: key, id: entry.id)
    }

    func sendInput(
        _ input: String,
        surfaceID: String,
        sequence: UInt64? = nil,
        delivery: MobileTerminalInputDelivery? = nil
    ) async -> InputResult {
        guard let key = focusedKeyBySurfaceID[surfaceID],
              let entry = entriesByKey[key],
              entry.phase == .active,
              entry.outputReady,
              let lane = entry.lane else {
            return .unavailable
        }
        if let delivery, delivery.surfaceID.uuidString.caseInsensitiveCompare(surfaceID) != .orderedSame {
            // A unit only ever travels on its own terminal's lane.
            return .unavailable
        }
        do {
            if let delivery {
                try await lane.sendInput(input, sequence: sequence, delivery: delivery)
            } else {
                try await lane.sendInput(input, sequence: sequence)
            }
            guard let current = entriesByKey[key], current.id == entry.id else {
                return .failed
            }
            return .sent
        } catch is MobileTerminalLaneDeliveryUnsupported {
            return .unavailable
        } catch {
            // SUPERMUX:begin terminal-lane-retry (upstream: `await fail(key: key, id: entry.id, lane: lane)`, which parked the lane until a reconnect, route change or remount)
            // Closing the lane ends the run's read, which opens it again
            // after the retry delay.
            await prepareToReopen(key: key, id: entry.id, lane: lane)
            // SUPERMUX:end terminal-lane-retry
            return .failed
        }
    }

    /// Close every generation of one unmounted surface across all peers.
    func deactivate(surfaceID: String) async {
        focusedKeyBySurfaceID[surfaceID] = nil
        let keys = entriesByKey.keys.filter { $0.surfaceID == surfaceID }
        await deactivate(keys: keys)
    }

    /// Retire prior peers only after the currently focused peer has produced an
    /// authoritative replay frame.
    func retireUnfocusedLanes(surfaceID: String) async {
        guard let focusedKey = focusedKeyBySurfaceID[surfaceID],
              entriesByKey[focusedKey]?.outputReady == true else {
            return
        }
        let keys = entriesByKey.keys.filter {
            $0.surfaceID == surfaceID && $0 != focusedKey
        }
        await deactivate(keys: keys)
    }

    func deactivateAll() async {
        focusedKeyBySurfaceID.removeAll()
        await deactivate(keys: Array(entriesByKey.keys))
    }

    func isOutputReady(surfaceID: String) -> Bool {
        guard let key = focusedKeyBySurfaceID[surfaceID] else { return false }
        return entriesByKey[key]?.outputReady == true
    }

    private func deactivate(keys: [LaneKey]) async {
        let entries = keys.compactMap { key -> Entry? in
            entriesByKey.removeValue(forKey: key)
        }
        for entry in entries { entry.task?.cancel() }
        for entry in entries where entry.outputReady {
            await entry.configuration.readinessChanged(false)
        }
        for entry in entries { await entry.lane?.close() }
        for entry in entries { await entry.task?.value }
    }

    private func launch(key: LaneKey, id: UUID) {
        let task = Task { [weak self] in
            guard let self else { return }
            await self.run(key: key, id: id)
        }
        entriesByKey[key]?.task = task
    }

    private func run(key: LaneKey, id: UUID) async {
        var openAttempt = 0
        // SUPERMUX:begin terminal-lane-retry (upstream: `while openAttempt < Self.maximumOpenAttempts, !Task.isCancelled {`)
        var failure: DiagnosticFailureKind?
        while !Task.isCancelled {
            failure = nil
        // SUPERMUX:end terminal-lane-retry
            guard let entry = entriesByKey[key], entry.id == id else { return }
            let configuration = entry.configuration
            // Input-only lanes carry an empty replay baseline solely to gate
            // readiness. Their host baseline is sampled independently from
            // the output event stream, so validating it against the output
            // cursor would reject a healthy lane whenever output advanced
            // between those two operations.
            let requestedCursor = configuration.mode == .inputOnly
                ? nil
                : await configuration.cursor()
            do {
                let laneProvider: MobileTerminalLaneProvider?
                switch configuration.mode {
                case .output:
                    laneProvider = provider
                case .inputOnly:
                    laneProvider = inputOnlyProvider ?? provider
                }
                guard let laneProvider else {
                    await markFailed(key: key, id: id)
                    return
                }
                let lane = try await laneProvider(
                    configuration.request,
                    configuration.surfaceID,
                    requestedCursor
                )
                guard install(lane: lane, key: key, id: id) else {
                    await lane.close()
                    return
                }
                var isFirstFrame = true
                while !Task.isCancelled, let frame = try await lane.receiveOutput() {
                    if frame.kind == .inputAcknowledgement {
                        guard let acknowledgement = frame.inputAcknowledgement else {
                            throw CoordinatorError.invalidEnvelope
                        }
                        // Answers stay valid after the lane is retired; the
                        // sender matches them to units by stream identity.
                        await configuration.acknowledged(acknowledgement)
                        continue
                    }
                    try Self.validate(
                        frame,
                        isFirstFrame: isFirstFrame,
                        requestedCursor: requestedCursor
                    )
                    isFirstFrame = false
                    guard let currentConfiguration = entriesByKey[key]?
                            .configuration else {
                        await lane.close()
                        return
                    }
                    let disposition = await currentConfiguration.consume(frame)
                    guard let current = entriesByKey[key], current.id == id else {
                        await lane.close()
                        return
                    }
                    switch disposition {
                    case let .accepted(outputReady):
                        if outputReady {
                            // SUPERMUX:begin terminal-lane-retry
                            // A lane that delivered its baseline worked: a
                            // later end starts the backoff over.
                            openAttempt = 0
                            // SUPERMUX:end terminal-lane-retry
                            await setOutputReady(true, key: key, id: id)
                        } else {
                            // A consumer can reject a frame temporarily while
                            // an authoritative replay barrier owns the output
                            // sink. Stop reading immediately. Draining the
                            // next chunk would discard the replay baseline and
                            // turn backpressure into a false sequence gap.
                            await suspend(key: key, id: id, lane: lane)
                            return
                        }
                    case .suspendUntilAuthoritativeOutput:
                        await suspend(key: key, id: id, lane: lane)
                        return
                    case .stop:
                        await finishFromRun(key: key, id: id, lane: lane)
                        return
                    }
                }
                if isFirstFrame {
                    throw CoordinatorError.missingReplayEnvelope
                }
                await prepareToReopen(key: key, id: id, lane: lane)
            } catch is CancellationError {
                return
            } catch {
                // SUPERMUX:begin terminal-lane-retry
                failure = DiagnosticFailureKind.classify(error)
                // SUPERMUX:end terminal-lane-retry
                if let lane = entriesByKey[key]?.lane {
                    await prepareToReopen(key: key, id: id, lane: lane)
                } else {
                    await setOutputReady(false, key: key, id: id)
                }
            }
            // SUPERMUX:begin terminal-lane-retry (upstream: `openAttempt += 1` here and `await markFailed(key: key, id: id)` after the loop)
            guard await waitToRetry(key: key, id: id, attempt: openAttempt, failure: failure) else {
                return
            }
            openAttempt += 1
            // SUPERMUX:end terminal-lane-retry
        }
    }

    // SUPERMUX:begin terminal-lane-retry
    /// Sleeps out the delay before attempt `attempt + 1`. False when the
    /// lane was deactivated, replaced or retried early meanwhile.
    private func waitToRetry(
        key: LaneKey,
        id: UUID,
        attempt: Int,
        failure: DiagnosticFailureKind?
    ) async -> Bool {
        guard var entry = entriesByKey[key], entry.id == id, !Task.isCancelled else {
            return false
        }
        let delay = retryDelay(attempt)
        entry.waitingToRetry = true
        entriesByKey[key] = entry
        retryObserver?(SupermuxTerminalLaneRetryEvent(
            surfaceID: key.surfaceID,
            attempt: attempt + 1,
            delay: delay,
            failure: failure
        ))
        do {
            try await retrySleep(delay)
        } catch {
            return false
        }
        guard var current = entriesByKey[key], current.id == id, !Task.isCancelled else {
            return false
        }
        current.waitingToRetry = false
        entriesByKey[key] = current
        return true
    }

    /// Starts a lane that is waiting out its retry delay again right away,
    /// under a new id so the sleeping run can never touch it.
    private func retryNow(key: LaneKey, entry: Entry) {
        entry.task?.cancel()
        let id = UUID()
        entriesByKey[key] = Entry(
            id: id,
            configuration: entry.configuration,
            phase: .opening,
            lane: nil,
            task: nil,
            outputReady: false
        )
        launch(key: key, id: id)
    }
    // SUPERMUX:end terminal-lane-retry

    private func install(
        lane: any MobileTerminalLaneConnection,
        key: LaneKey,
        id: UUID
    ) -> Bool {
        guard var entry = entriesByKey[key], entry.id == id else {
            return false
        }
        entry.phase = .active
        entry.lane = lane
        entriesByKey[key] = entry
        return true
    }

    private func setOutputReady(_ ready: Bool, key: LaneKey, id: UUID) async {
        guard var entry = entriesByKey[key], entry.id == id else { return }
        let changed = entry.outputReady != ready
        entry.outputReady = ready
        entriesByKey[key] = entry
        if changed {
            await entry.configuration.readinessChanged(ready)
        }
    }

    private func prepareToReopen(
        key: LaneKey,
        id: UUID,
        lane: any MobileTerminalLaneConnection
    ) async {
        guard var entry = entriesByKey[key], entry.id == id else {
            await lane.close()
            return
        }
        let wasReady = entry.outputReady
        entry.phase = .opening
        entry.lane = nil
        entry.outputReady = false
        entriesByKey[key] = entry
        if wasReady {
            await entry.configuration.readinessChanged(false)
        }
        await lane.close()
    }

    private func suspend(
        key: LaneKey,
        id: UUID,
        lane: any MobileTerminalLaneConnection
    ) async {
        guard var entry = entriesByKey[key], entry.id == id else {
            await lane.close()
            return
        }
        let wasReady = entry.outputReady
        entry.phase = .suspended
        entry.lane = nil
        entry.task = nil
        entry.outputReady = false
        entriesByKey[key] = entry
        if wasReady {
            await entry.configuration.readinessChanged(false)
        }
        await lane.close()
    }

    private func finishFromRun(
        key: LaneKey,
        id: UUID,
        lane: any MobileTerminalLaneConnection
    ) async {
        guard let entry = entriesByKey[key], entry.id == id else {
            await lane.close()
            return
        }
        entriesByKey[key] = nil
        if focusedKeyBySurfaceID[key.surfaceID] == key {
            focusedKeyBySurfaceID[key.surfaceID] = nil
        }
        if entry.outputReady {
            await entry.configuration.readinessChanged(false)
        }
        await lane.close()
    }

    private func fail(
        key: LaneKey,
        id: UUID,
        lane: any MobileTerminalLaneConnection
    ) async {
        guard var entry = entriesByKey[key], entry.id == id else {
            await lane.close()
            return
        }
        let wasReady = entry.outputReady
        entry.phase = .failed
        entry.lane = nil
        entry.task?.cancel()
        entry.task = nil
        entry.outputReady = false
        entriesByKey[key] = entry
        if wasReady {
            await entry.configuration.readinessChanged(false)
        }
        await lane.close()
    }

    private func markFailed(key: LaneKey, id: UUID) async {
        guard var entry = entriesByKey[key], entry.id == id else { return }
        let wasReady = entry.outputReady
        entry.phase = .failed
        entry.lane = nil
        entry.task = nil
        entry.outputReady = false
        entriesByKey[key] = entry
        if wasReady {
            await entry.configuration.readinessChanged(false)
        }
    }

    private static func validate(
        _ frame: MobileTerminalLaneOutputFrame,
        isFirstFrame: Bool,
        requestedCursor: UInt64?
    ) throws {
        if isFirstFrame {
            guard frame.kind == .replay else {
                throw CoordinatorError.missingReplayEnvelope
            }
            if let requestedCursor, frame.sequence != requestedCursor {
                throw CoordinatorError.replayCursorMismatch
            }
        } else if frame.kind == .replay {
            throw CoordinatorError.unexpectedReplayEnvelope
        }
        guard frame.retainedBaseSequence <= frame.sequence,
              frame.sequence <= frame.currentSequence,
              frame.currentSequence - frame.sequence
                == UInt64(frame.bytes.count) else {
            throw CoordinatorError.invalidEnvelope
        }
    }
}
