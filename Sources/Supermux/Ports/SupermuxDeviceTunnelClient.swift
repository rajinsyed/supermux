import CmuxIrxTransport
import CmuxSurfaceCatalogModel
import Foundation
import SupermuxMobileCore

/// Whether another Mac's loopback can be reached through a tunnel right now.
enum SupermuxDeviceTunnelAvailability: String, Equatable, Sendable {
    case available, offline, needsUpdate = "needs_update", noDirectLink = "no_direct_link"
}

/// The viewer side of port forwarding: one TCP connection to another of the
/// user's Macs' loopback, as one `tcp_connect` lane on the device link's live
/// connection (served there by `SupermuxDeviceTunnelHosts`). Forwards and a
/// mirror's browser proxy open one per accepted connection.
///
/// A lane lives only as long as the link's session; nothing here dials, so a
/// reconnect simply fails the next open until the link is back.
@MainActor
enum SupermuxDeviceTunnelClient {
    enum Failure: Error, Equatable { case unavailable(SupermuxDeviceTunnelAvailability), notListening, denied, busy, failed }

    static func availability(of machine: SurfaceMachineID) async -> SupermuxDeviceTunnelAvailability {
        let devices = SupermuxComposition.devices
        guard devices.device(for: machine)?.isConnected == true else { return .offline }
        guard await devices.supports(.portForwardV1, on: machine) else { return .needsUpdate }
        #if DEBUG
        if SupermuxDeviceLoopbackHarness.tunnelAcceptor(for: machine) != nil { return .available }
        #endif
        return (try? await connection(to: machine)) == nil ? .noDirectLink : .available
    }

    /// One TCP connection to `host:port` on `machine`'s loopback. `host` is "localhost"
    /// (the host tries 127.0.0.1 then ::1, so ::1-only servers such as Vite work), or a
    /// literal loopback address a browser asked for.
    static func open(machine: SurfaceMachineID, host: String = "localhost", port: Int) async throws -> any SupermuxByteStream {
        let devices = SupermuxComposition.devices
        guard devices.device(for: machine)?.isConnected == true else { throw Failure.unavailable(.offline) }
        guard await devices.supports(.portForwardV1, on: machine) else { throw Failure.unavailable(.needsUpdate) }
        #if DEBUG
        if let acceptor = SupermuxDeviceLoopbackHarness.tunnelAcceptor(for: machine) {
            do {
                return try await acceptor.openTunnel(host: host, port: port)
            } catch {
                throw failure(for: error)
            }
        }
        #endif
        let connection: IrxConnection
        do {
            connection = try await self.connection(to: machine)
        } catch {
            throw Failure.unavailable(.noDirectLink)
        }
        do {
            return try await IrxTunnelClient(connection: connection).connect(host: host, port: port)
        } catch {
            throw failure(for: error)
        }
    }

    /// The device link's live, verified connection. Throws without an Iroh
    /// session (a legacy Tailscale route has no lanes, or Devices is off).
    private static func connection(to machine: SurfaceMachineID) async throws -> IrxConnection {
        guard let instance = machine.deviceInstance,
              let client = MobileHostIrxRuntime.shared.outgoingDeviceClient else { throw DeviceLinkError.notConnected }
        return try await client.supermuxTunnelConnection(instance: instance)
    }

    /// A refused open as the host answered it; anything else (the connection
    /// closed under the open) means the Mac is gone.
    private static func failure(for error: any Error) -> Failure {
        guard let error = error as? IrxTunnelOpenError else { return .unavailable(.offline) }
        switch error.status {
        case .refused: return .notListening
        case .denied: return .denied
        case .busy: return .busy
        default: return .failed
        }
    }
}

#if DEBUG
/// The DEBUG loopback device's in-memory lane stands in for an `IrxLaneStream`.
extension SupermuxDeviceLoopbackTunnelLane.ClientHalf: SupermuxByteStream {}
#endif
