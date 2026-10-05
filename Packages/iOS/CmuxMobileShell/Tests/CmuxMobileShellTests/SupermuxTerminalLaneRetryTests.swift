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

    private var lanes: [LaneRetryTestConnection]
    private var failuresLeft: Int
    private var requests = 0

    init(lanes: [LaneRetryTestConnection], failuresFirst: Int = 0) {
        self.lanes = lanes
        self.failuresLeft = failuresFirst
    }

    func open(
        _: CmxByteTransportRequest,
        _: String,
        _: UInt64?
    ) throws -> any MobileTerminalLaneConnection {
        requests += 1
        if failuresLeft > 0 {
            failuresLeft -= 1
            throw Refused()
        }
        guard !lanes.isEmpty else { throw Refused() }
        return lanes.removeFirst()
    }

    func requestCount() -> Int { requests }
}
// SUPERMUX:end terminal-lane-retry
