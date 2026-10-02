#if DEBUG
import CmuxIrohTransport
import CmuxMobileRPC
import Foundation

/// The DEBUG loopback device's simulator-stream lane: an in-process stand-in
/// for one QUIC `.simulatorStream` lane to this app's own mobile host.
///
/// Two ``SupermuxDeviceLoopbackPipe``s carry the bytes. The far end runs the
/// host's real v2 entry point, `MobileSimulatorStreamV2Coordinator.handleLane`,
/// the same call the irx lane loop makes for a Mac or phone peer, so the real
/// session, pump, VideoToolbox encoder and worker ring run end to end; only
/// QUIC is replaced. The viewer owns the lane's life: ``close()`` closes both
/// pipes, and the host session ends `lane_closed`.
actor SupermuxRemoteSimulatorLoopbackLane: MobileSimulatorStreamLaneConnection {
    private let toHost: SupermuxDeviceLoopbackPipe
    private let fromHost: SupermuxDeviceLoopbackPipe
    private var closed = false

    private init(toHost: SupermuxDeviceLoopbackPipe, fromHost: SupermuxDeviceLoopbackPipe) {
        self.toHost = toHost
        self.fromHost = fromHost
    }

    /// Opens a lane to the host `SimulatorPanel` `panelID` (resource
    /// `simstream:<lowercased uuid>`, as iOS and the Mac viewer send it).
    static func open(panelID: UUID) throws -> SupermuxRemoteSimulatorLoopbackLane {
        let resource = try CmxIrohResourceID("simstream:\(panelID.uuidString.lowercased())")
        let peer = try SupermuxDeviceLoopbackIdentity().admittedPeer()
        let toHost = SupermuxDeviceLoopbackPipe()
        let fromHost = SupermuxDeviceLoopbackPipe()
        let hostEnd = CmxIrohBidirectionalStream(
            receiveStream: LoopbackReceiveHalf(pipe: toHost),
            sendStream: LoopbackSendHalf(pipe: fromHost)
        )
        Task {
            _ = await MobileSimulatorStreamV2Coordinator.shared.handleLane(
                resourceID: resource,
                stream: hostEnd,
                peer: peer
            )
        }
        return SupermuxRemoteSimulatorLoopbackLane(toHost: toHost, fromHost: fromHost)
    }

    func receive() async throws -> Data? {
        guard !closed else { return nil }
        return try await fromHost.read()
    }

    func send(_ data: Data) async throws {
        guard !closed else { throw SupermuxDeviceLoopbackPipeError.closed }
        try await toHost.write(data)
    }

    func close() async {
        guard !closed else { return }
        closed = true
        await toHost.close()
        await fromHost.close()
    }
}

/// The host's readable half: what the viewer wrote. The size cap is ignored;
/// the host's frame accumulator accepts any chunking.
private struct LoopbackReceiveHalf: CmxIrohReceiveStream {
    let pipe: SupermuxDeviceLoopbackPipe

    func receive(maximumByteCount: Int) async throws -> Data? {
        try await pipe.read()
    }

    func stop(errorCode: UInt64) async {
        await pipe.close()
    }
}

/// The host's writable half: what the viewer reads.
private struct LoopbackSendHalf: CmxIrohSendStream {
    let pipe: SupermuxDeviceLoopbackPipe

    func send(_ data: Data) async throws {
        try await pipe.write(data)
    }

    func finish() async throws {
        await pipe.close()
    }

    func reset(errorCode: UInt64) async {
        await pipe.close()
    }

    func setPriority(_ priority: Int32) async throws {}
}
#endif
