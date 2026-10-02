import CmuxIrxTransport
import CmuxSurfaceCatalogModel
import Foundation
import SupermuxMobileCore

/// Whether another Mac's loopback can be reached through a tunnel right now.
///
/// `unreachable` is the answer that changes by itself: the Mac is connected,
/// but its capabilities are not known yet (its `mobile.host.status` request
/// failed, timed out or met a busy Mac; nothing is cached, so the next check
/// asks again) or its Iroh session is between dials. `needsUpdate` comes only
/// from capabilities the Mac did send, without `supermux.port_forward.v1`.
enum SupermuxDeviceTunnelAvailability: String, Equatable, Sendable {
    case available, offline, unreachable, needsUpdate = "needs_update", noDirectLink = "no_direct_link"
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
        if let blocked = await blocker(on: machine) { return blocked }
        #if DEBUG
        if SupermuxDeviceLoopbackHarness.tunnelAcceptor(for: machine) != nil { return .available }
        #endif
        do {
            _ = try await connection(to: machine)
            return .available
        } catch Failure.unavailable(let reason) {
            return reason
        } catch {
            return .unreachable
        }
    }

    /// One TCP connection to `host:port` on `machine`'s loopback. `host` is "localhost"
    /// (the host tries 127.0.0.1 then ::1, so ::1-only servers such as Vite work), or a
    /// literal loopback address a browser asked for.
    static func open(machine: SurfaceMachineID, host: String = "localhost", port: Int) async throws -> any SupermuxByteStream {
        if let blocked = await blocker(on: machine) { throw Failure.unavailable(blocked) }
        #if DEBUG
        if let acceptor = SupermuxDeviceLoopbackHarness.tunnelAcceptor(for: machine) {
            do {
                return try await acceptor.openTunnel(host: host, port: port)
            } catch {
                throw failure(for: error)
            }
        }
        #endif
        let connection = try await self.connection(to: machine)
        do {
            return try await IrxTunnelClient(connection: connection).connect(host: host, port: port)
        } catch {
            throw failure(for: error)
        }
    }

    /// Why `machine` cannot take a tunnel before any lane is tried, or nil.
    /// Unknown capabilities (`nil`: the status request failed) are
    /// `unreachable`, never `needsUpdate`, which needs a capability set that
    /// lacks port forwarding.
    private static func blocker(on machine: SurfaceMachineID) async -> SupermuxDeviceTunnelAvailability? {
        let devices = SupermuxComposition.devices
        guard devices.device(for: machine)?.isConnected == true else { return .offline }
        guard let capabilities = await devices.hostCapabilities(on: machine) else { return .unreachable }
        return capabilities.contains(SupermuxMobileCapability.portForwardV1.rawValue) ? nil : .needsUpdate
    }

    /// The device link's live, verified connection. Without the Iroh device
    /// client this Mac's links run over the legacy Tailscale route, which has
    /// no lanes (`noDirectLink`). With it, a missing session is the link
    /// between dials or re-checking its access (`unreachable`, asked again).
    private static func connection(to machine: SurfaceMachineID) async throws -> IrxConnection {
        guard let client = MobileHostIrxRuntime.shared.outgoingDeviceClient else {
            throw Failure.unavailable(.noDirectLink)
        }
        guard let instance = machine.deviceInstance else { throw Failure.unavailable(.offline) }
        do {
            return try await client.supermuxTunnelConnection(instance: instance)
        } catch {
            throw Failure.unavailable(.unreachable)
        }
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
