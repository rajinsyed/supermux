// SUPERMUX:begin terminal-lane-retry
import CMUXMobileCore
import CmuxMobileRPC
import Foundation
import Testing
@testable import CmuxMobileShell

/// A phone's terminal lane outlives relay drops. Before, three lane ends in
/// one connection (each after a lane that had worked) or one failed send
/// parked the lane for the rest of the connection, and every keystroke fell
/// back to one RPC round trip per batch.
///
/// Failure modes for the retry itself (review findings I8 and I9), listed
/// before the fix:
/// 1. A lane open that fails with `CancellationError` because the engine
///    replaced the dial it joined (an explicit redial) ends the run with the
///    lane still "opening" and no task: no retry, and `ensure` never starts
///    it again, so the terminal stays on the RPC fallback.
/// 2. A lane that ends right after delivering its baseline (a host that
///    accepts and drops it) resets the backoff, so it reopens every 250 ms
///    forever.
@Suite struct SupermuxTerminalLaneRetryTests {
    @Test func laneThatEndsAfterItsBaselineReopensEveryTime() async throws {
        // Four relay drops, each after a lane that delivered its baseline.
        var lanes = (0..<4).map { _ in
            LaneRetryTestConnection(frames: [Self.baseline], waitsAfterFrames: false)
        }
        let survivor = LaneRetryTestConnection(frames: [Self.baseline], waitsAfterFrames: true)
        lanes.append(survivor)
        let provider = LaneRetryTestProvider(lanes: lanes)
        let coordinator = MobileTerminalLaneCoordinator { request, surfaceID, cursor in
            try await provider.open(request, surfaceID, cursor)
        }
        await coordinator.ensure(Self.configuration(try Self.request()))

        #expect(await Self.eventually { await provider.requestCount() == 5 })
        #expect(await Self.eventually { await coordinator.isOutputReady(surfaceID: Self.surfaceID) })
        #expect(await coordinator.sendInput("ls\n", surfaceID: Self.surfaceID) == .sent)
        #expect(await survivor.inputs() == ["ls\n"])
        await coordinator.deactivateAll()
    }

    @Test func failedSendReopensTheLaneInsteadOfParkingIt() async throws {
        let broken = LaneRetryTestConnection(
            frames: [Self.baseline], waitsAfterFrames: true, failsInput: true
        )
        let replacement = LaneRetryTestConnection(frames: [Self.baseline], waitsAfterFrames: true)
        let provider = LaneRetryTestProvider(lanes: [broken, replacement])
        let coordinator = MobileTerminalLaneCoordinator { request, surfaceID, cursor in
            try await provider.open(request, surfaceID, cursor)
        }
        await coordinator.ensure(Self.configuration(try Self.request()))
        #expect(await Self.eventually { await coordinator.isOutputReady(surfaceID: Self.surfaceID) })

        #expect(await coordinator.sendInput("lost\n", surfaceID: Self.surfaceID) == .failed)

        #expect(await Self.eventually { await provider.requestCount() == 2 })
        #expect(await Self.eventually { await coordinator.isOutputReady(surfaceID: Self.surfaceID) })
        #expect(await coordinator.sendInput("again\n", surfaceID: Self.surfaceID) == .sent)
        #expect(await replacement.inputs() == ["again\n"])
        await coordinator.deactivateAll()
    }

    @Test func openFailuresKeepRetryingPastThreeAttempts() async throws {
        let survivor = LaneRetryTestConnection(frames: [Self.baseline], waitsAfterFrames: true)
        // Three refused opens (a relay outage), then the lane opens.
        let provider = LaneRetryTestProvider(lanes: [survivor], failuresFirst: 3)
        let coordinator = MobileTerminalLaneCoordinator { request, surfaceID, cursor in
            try await provider.open(request, surfaceID, cursor)
        }
        await coordinator.ensure(Self.configuration(try Self.request()))

        #expect(await Self.eventually(seconds: 6) {
            await coordinator.isOutputReady(surfaceID: Self.surfaceID)
        })
        #expect(await provider.requestCount() == 4)
        await coordinator.deactivateAll()
    }

    @Test func consecutiveFailuresBackOffAndAWorkingLaneResetsIt() async throws {
        let survivor = LaneRetryTestConnection(frames: [Self.baseline], waitsAfterFrames: true)
        // Three refused opens, a lane that works and then drops, one more
        // refused open, then a lane that stays.
        let provider = LaneRetryTestProvider(
            script: [.refuse, .refuse, .refuse,
                     .lane(LaneRetryTestConnection(frames: [Self.baseline], waitsAfterFrames: false)),
                     .refuse, .lane(survivor)]
        )
        let sleeps = LaneRetryRecorder<Duration>()
        let events = LaneRetryRecorder<SupermuxTerminalLaneRetryEvent>()
        let coordinator = MobileTerminalLaneCoordinator(
            provider: { request, surfaceID, cursor in
                try await provider.open(request, surfaceID, cursor)
            },
            retryDelay: { .milliseconds($0) },
            retrySleep: { sleeps.append($0) },
            retryObserver: { events.append($0) }
        )
        await coordinator.ensure(Self.configuration(try Self.request()))

        #expect(await Self.eventually { await coordinator.isOutputReady(surfaceID: Self.surfaceID) })
        #expect(sleeps.values == [0, 1, 2, 0, 1].map { .milliseconds($0) })
        #expect(events.values.map(\.attempt) == [1, 2, 3, 1, 2])
        #expect(events.values.map { $0.failure == nil } == [false, false, false, true, false])
        await coordinator.deactivateAll()
    }

    @Test func aLaneOpenCancelledUnderneathIsRetried() async throws {
        let survivor = LaneRetryTestConnection(frames: [Self.baseline], waitsAfterFrames: true)
        let provider = LaneRetryTestProvider(script: [.cancel, .lane(survivor)])
        let coordinator = MobileTerminalLaneCoordinator(
            provider: { request, surfaceID, cursor in
                try await provider.open(request, surfaceID, cursor)
            },
            retrySleep: { _ in }
        )
        await coordinator.ensure(Self.configuration(try Self.request()))

        #expect(
            await Self.eventually { await coordinator.isOutputReady(surfaceID: Self.surfaceID) },
            "a dial the engine cancelled stranded the lane"
        )
        #expect(await provider.requestCount() == 2)
        await coordinator.deactivateAll()
    }

    @Test func aLaneThatEndsRightAfterItsBaselineBacksOff() async throws {
        let quickEnds = (0..<4).map { _ in
            LaneRetryTestConnection(frames: [Self.baseline], waitsAfterFrames: false)
        }
        let survivor = LaneRetryTestConnection(frames: [Self.baseline], waitsAfterFrames: true)
        let provider = LaneRetryTestProvider(lanes: quickEnds + [survivor])
        let sleeps = LaneRetryRecorder<Duration>()
        let coordinator = MobileTerminalLaneCoordinator(
            provider: { request, surfaceID, cursor in
                try await provider.open(request, surfaceID, cursor)
            },
            retryDelay: { .milliseconds($0) },
            retrySleep: { sleeps.append($0) }
        )
        await coordinator.ensure(Self.configuration(try Self.request()))

        #expect(await Self.eventually { await provider.requestCount() == 5 })
        #expect(await Self.eventually { await coordinator.isOutputReady(surfaceID: Self.surfaceID) })
        #expect(sleeps.values == [0, 1, 2, 3].map { .milliseconds($0) }, "a lane that never stayed up reset the backoff")
        await coordinator.deactivateAll()
    }

    @Test func retryDelayDoublesFrom250MillisecondsUpTo5Seconds() {
        let policy = SupermuxTerminalLaneRetryDelay()
        let delays = (0..<8).map { policy.delay(forAttempt: $0, jitter: 1) }
        #expect(delays == [250, 500, 1000, 2000, 4000, 5000, 5000, 5000].map { .milliseconds($0) })
        #expect(policy.delay(forAttempt: 2, jitter: 0.8) == .milliseconds(800))
    }

    @Test func ensureDuringARetryDelayRetriesAtOnce() async throws {
        let survivor = LaneRetryTestConnection(frames: [Self.baseline], waitsAfterFrames: true)
        let provider = LaneRetryTestProvider(lanes: [survivor], failuresFirst: 1)
        let events = LaneRetryRecorder<SupermuxTerminalLaneRetryEvent>()
        let coordinator = MobileTerminalLaneCoordinator(
            provider: { request, surfaceID, cursor in
                try await provider.open(request, surfaceID, cursor)
            },
            retrySleep: { _ in try await Task.sleep(for: .seconds(3600)) },
            retryObserver: { events.append($0) }
        )
        await coordinator.ensure(Self.configuration(try Self.request()))
        #expect(await Self.eventually { events.values.count == 1 })
        #expect(await coordinator.isOutputReady(surfaceID: Self.surfaceID) == false)

        // A reconnect re-ensures every mounted terminal's lane.
        await coordinator.ensure(Self.configuration(try Self.request()))

        #expect(await Self.eventually { await coordinator.isOutputReady(surfaceID: Self.surfaceID) })
        #expect(await provider.requestCount() == 2)
        await coordinator.deactivateAll()
    }

    // MARK: - Helpers

    static let surfaceID = "123e4567-e89b-42d3-a456-426614174000"

    static let baseline = MobileTerminalLaneOutputFrame(
        kind: .replay,
        retainedBaseSequence: 0,
        sequence: 0,
        currentSequence: 0,
        bytes: Data()
    )

    static func request() throws -> CmxByteTransportRequest {
        CmxByteTransportRequest(
            route: try CmxAttachRoute(
                id: "iroh",
                kind: .iroh,
                endpoint: .peer(
                    identity: try CmxIrohPeerIdentity(endpointID: String(repeating: "a", count: 64)),
                    pathHints: []
                )
            ),
            expectedPeerDeviceID: "mac",
            authorizationMode: .transportAdmission
        )
    }

    static func configuration(
        _ request: CmxByteTransportRequest
    ) -> MobileTerminalLaneCoordinator.Configuration {
        MobileTerminalLaneCoordinator.Configuration(
            request: request,
            surfaceID: surfaceID,
            mode: .inputOnly,
            cursor: { nil },
            consume: { _ in .accepted(outputReady: true) },
            readinessChanged: { _ in }
        )
    }

    /// Polls `condition` until it holds or `seconds` pass.
    static func eventually(
        seconds: Double = 3,
        _ condition: @Sendable () async -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(Int(seconds * 1000)))
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }
}

actor LaneRetryTestConnection: MobileTerminalLaneConnection {
    struct InputFailed: Error {}

    private var pendingFrames: [MobileTerminalLaneOutputFrame]
    private let waitsAfterFrames: Bool
    private let failsInput: Bool
    private var waiter: CheckedContinuation<MobileTerminalLaneOutputFrame?, Never>?
    private var sentInputs: [String] = []
    private var closed = false

    init(frames: [MobileTerminalLaneOutputFrame], waitsAfterFrames: Bool, failsInput: Bool = false) {
        self.pendingFrames = frames
        self.waitsAfterFrames = waitsAfterFrames
        self.failsInput = failsInput
    }

    func receiveOutput() async -> MobileTerminalLaneOutputFrame? {
        if !pendingFrames.isEmpty { return pendingFrames.removeFirst() }
        guard waitsAfterFrames, !closed else { return nil }
        return await withCheckedContinuation { waiter = $0 }
    }

    func sendInput(_ input: String) throws {
        if failsInput { throw InputFailed() }
        sentInputs.append(input)
    }

    func close() {
        closed = true
        waiter?.resume(returning: nil)
        waiter = nil
    }

    func inputs() -> [String] { sentInputs }
}

actor LaneRetryTestProvider {
    struct Refused: Error {}

    enum Step {
        case refuse
        /// The engine replaced the dial the open joined.
        case cancel
        case lane(LaneRetryTestConnection)
    }

    private var script: [Step]
    private var requests = 0

    init(script: [Step]) {
        self.script = script
    }

    init(lanes: [LaneRetryTestConnection], failuresFirst: Int = 0) {
        self.script = Array(repeating: .refuse, count: failuresFirst) + lanes.map { .lane($0) }
    }

    func open(
        _: CmxByteTransportRequest,
        _: String,
        _: UInt64?
    ) throws -> any MobileTerminalLaneConnection {
        requests += 1
        guard !script.isEmpty else { throw Refused() }
        switch script.removeFirst() {
        case .refuse: throw Refused()
        case .cancel: throw CancellationError()
        case .lane(let lane): return lane
        }
    }

    func requestCount() -> Int { requests }
}

/// Collects values from synchronous `@Sendable` callbacks.
final class LaneRetryRecorder<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Value] = []

    func append(_ value: Value) {
        lock.lock()
        recorded.append(value)
        lock.unlock()
    }

    var values: [Value] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}
// SUPERMUX:end terminal-lane-retry
