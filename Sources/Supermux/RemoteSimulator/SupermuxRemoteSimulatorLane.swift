import CmuxIrohTransport
import CmuxIrxTransport
import CmuxMobileRPC
import CmuxSurfaceCatalogModel
import Foundation

/// One simulator-stream v2 lane to a `SimulatorPanel` on another Mac: raw
/// framed bytes both ways (the viewer package frames and decodes them). A
/// port of the iPhone's `MobileIrohSimulatorStreamLane`, opened with the same
/// descriptor (`simulator_stream`, resource `simstream:<lowercased uuid>`) on
/// the device link's own irx connection. That Mac serves these lanes to every
/// admitted peer, Macs included, so it needs no change.
actor SupermuxRemoteSimulatorLane: MobileSimulatorStreamLaneConnection {
    enum OpenError: Error, Equatable {
        /// The Mac's device link is down.
        case offline
        /// No irx connection to open lanes on (Devices off, or a legacy
        /// Tailscale route that carries only the control stream).
        case noDirectLink
    }

    private let stream: CmxIrohBidirectionalStream
    private var closed = false

    private init(stream: CmxIrohBidirectionalStream) {
        self.stream = stream
    }

    /// Opens a lane to the host panel `panelID` on `machine`. Never dials: a
    /// lane lives on the link's current session, and a reconnect simply
    /// fails it so the viewer opens a new one. The DEBUG loopback device
    /// gets its in-process lane instead.
    @MainActor
    static func open(machine: SurfaceMachineID, panelID: UUID) async throws -> any MobileSimulatorStreamLaneConnection {
        let device = SupermuxComposition.devices.device(for: machine)
        guard device?.isConnected == true else { throw OpenError.offline }
        #if DEBUG
        if device?.isLoopback == true {
            return try SupermuxRemoteSimulatorLoopbackLane.open(panelID: panelID)
        }
        #endif
        guard let instance = machine.deviceInstance,
              let client = MobileHostIrxRuntime.shared.outgoingDeviceClient else { throw OpenError.noDirectLink }
        let connection = try await client.supermuxTunnelConnection(instance: instance)
        let lane = try await connection.openLane(IrxLaneDescriptor(
            lane: .simulatorStream,
            resource: "simstream:\(panelID.uuidString.lowercased())"
        ))
        return SupermuxRemoteSimulatorLane(stream: lane.bidirectional())
    }

    func receive() async throws -> Data? {
        guard !closed else { return nil }
        return try await stream.receiveStream.receive(maximumByteCount: 256 * 1_024)
    }

    func send(_ data: Data) async throws {
        guard !closed else { throw OpenError.offline }
        try await stream.sendStream.send(data)
    }

    func close() async {
        guard !closed else { return }
        closed = true
        await stream.sendStream.reset(errorCode: 0)
        await stream.receiveStream.stop(errorCode: 0)
    }
}
