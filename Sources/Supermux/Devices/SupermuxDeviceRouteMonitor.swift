import CmuxIrxTransport
import CmuxSurfaceCatalogModel
import Foundation
import SupermuxMobileCore

/// Samples the path each connected remote Mac's link uses and publishes it
/// to ``SupermuxDeviceRoutes``: every ``activeInterval`` while the app is in
/// use (``SupermuxAppInUse``), every ``idleInterval`` otherwise, and at once
/// when a link connects. Links that are not connected are never sampled.
///
/// Each sample is the outgoing session's selected path with iroh's RTT on
/// it (`IrxConnection.supermuxSelectedPathSample()`), classified by
/// `SupermuxLinkRouteClassifier`. A direct path it used is also learned by
/// the route-candidate store (an outgoing session only: an inbound one's
/// source port may not accept dials). The monitor also drives
/// ``SupermuxRouteCandidateSync``.
///
/// DEBUG builds can pin a link's route (`supermux.devices.route.override`):
/// the loopback device has no Iroh connection to sample.
@MainActor
final class SupermuxDeviceRouteMonitor {
    /// The sample interval while the app is in use.
    static let activeInterval: Duration = .seconds(2)
    /// The sample interval otherwise.
    static let idleInterval: Duration = .seconds(30)

    /// One outgoing session's selected path and the endpoint it reached.
    struct LinkPath {
        let sample: SupermuxIrxPathSample
        let endpointID: String
    }

    private let devices: SupermuxDevices
    private let routes: SupermuxDeviceRoutes
    private let store: SupermuxRouteCandidateStore
    private let sync: SupermuxRouteCandidateSync
    private let path: @MainActor (SurfaceDeviceInstanceID) async -> LinkPath?
    private var loop: Task<Void, Never>?
    private var events: Task<Void, Never>?
    private var overrides: [SurfaceDeviceInstanceID: SupermuxLinkRoute] = [:]

    init(
        devices: SupermuxDevices,
        routes: SupermuxDeviceRoutes,
        store: SupermuxRouteCandidateStore,
        sync: SupermuxRouteCandidateSync,
        path: @escaping @MainActor (SurfaceDeviceInstanceID) async -> LinkPath?
    ) {
        self.devices = devices
        self.routes = routes
        self.store = store
        self.sync = sync
        self.path = path
    }

    /// Starts sampling and following link edges. Idempotent.
    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let monitor = self else { return }
                await monitor.sampleNow()
                let interval = SupermuxAppInUse.now() ? Self.activeInterval : Self.idleInterval
                try? await Task.sleep(for: interval)
            }
        }
        let stream = devices.events()
        events = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                switch event {
                case let .linkConnected(machine):
                    guard let device = devices.device(for: machine) else { continue }
                    sync.linkConnected(device)
                    await sample(device)
                case let .linkLost(machine):
                    guard let instance = machine.deviceInstance else { continue }
                    routes.clear(instance)
                    sync.linkLost(instance)
                case .topic:
                    continue
                }
            }
        }
    }

    /// Samples every connected link once and asks for due candidates.
    func sampleNow() async {
        let connected = devices.devices.filter(\.isConnected)
        routes.keepOnly(Set(connected.map(\.instance)))
        for device in connected { await sample(device) }
        sync.tick(connected: connected)
    }

    private func sample(_ device: SupermuxDevice) async {
        let instance = device.instance
        if let pinned = overrides[instance] {
            routes.apply(pinned, for: instance)
            return
        }
        guard !device.isLoopback else { return }
        guard let current = await path(instance) else {
            routes.clear(instance)
            return
        }
        let sample = current.sample
        let route = SupermuxLinkRouteClassifier.classify(
            isRelay: sample.isRelay, remoteAddress: sample.remoteAddress, rttMs: sample.rttMs, now: Date())
        routes.apply(route, for: instance)
        guard !sample.isRelay else { return }
        let key = SupermuxRoutePeerKey(deviceID: instance.deviceID, tag: instance.tag, endpointID: current.endpointID)
        await store.learn(sample.remoteAddress, for: key)
    }

    // MARK: - DEBUG pins

    /// Pins a link's sampled route (DEBUG driver); nil unpins it. The pin
    /// goes through the same publish rule as a real sample.
    func pin(_ route: SupermuxLinkRoute?, for instance: SurfaceDeviceInstanceID) {
        overrides[instance] = route
        if let route { routes.apply(route, for: instance) } else { routes.clear(instance) }
    }
}

extension SupermuxDeviceRouteMonitor {
    /// The live, verified outgoing session to `instance`, through the Mac's
    /// Iroh device client; nil without one (no session, the legacy route).
    static func outgoingConnection(to instance: SurfaceDeviceInstanceID) async -> IrxConnection? {
        guard let client = MobileHostIrxRuntime.shared.outgoingDeviceClient else { return nil }
        return try? await client.supermuxTunnelConnection(instance: instance)
    }

    /// That session's selected path and the endpoint it reached.
    static func outgoingPath(to instance: SurfaceDeviceInstanceID) async -> LinkPath? {
        guard let connection = await outgoingConnection(to: instance),
              let sample = connection.supermuxSelectedPathSample() else { return nil }
        return LinkPath(sample: sample, endpointID: connection.remoteEndpointIDHex)
    }
}
